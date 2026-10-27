-- The PK:GB launcher's Carts page: choose which custom cart a game plays as,
-- install or remove carts, save the current mod setup as a new cart, export
-- one to share, fetch the mods a cart pins, and break a save's seal.
--
-- Written from scratch for this project over src/carts/CartStore.lua,
-- CartManifest.lua, src/mods/Loader.lua (planCart) and src/core/SaveData.lua.
-- Downloads go through the Mods page's queue (src/launcher/ModsPage.lua),
-- which checks each pinned archive against the cart's sha256 before it
-- installs anything.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local GameVersion = require("src.core.GameVersion")
local ModsPage = require("src.launcher.ModsPage")

local PAL = Theme.PAL

local CartsPage = {}
CartsPage.__index = CartsPage

CartsPage.PAGES = { carts = true, cartnew = true }
CartsPage.PARENT = { cartnew = "carts" }

local CART_KIND = { label = "Custom cart", exts = { "g1rcart" } }

function CartsPage.new(launcher)
  return setmetatable({ launcher = launcher, form = nil }, CartsPage)
end

local function gameName(version)
  local info = version and GameVersion.info(version)
  return info and info.displayName or tostring(version or "this game")
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function btnH(s) return math.max(Kit.tapMin(), math.floor(34 * s)) end

-- ------------------------------------------------------------------ model

function CartsPage:installCart(data, name)
  local l = self.launcher
  local CartStore = require("src.carts.CartStore")
  local ok, cart, err = pcall(CartStore.install, data)
  if not ok then cart, err = nil, cart end
  l.cartRows, l.cartPlans = nil, nil
  if not cart then
    return l:say("Could not install " .. tostring(name or "that cart") .. ": "
      .. tostring(err), "error")
  end
  if cart.base and l.ready[cart.base] ~= nil then
    l:selectGame(cart.base)
    l:selectCart(cart.base, cart.id)
  end
  local info = cart.base and GameVersion.info(cart.base)
  l:say(("Installed %s%s."):format(tostring(cart.title or cart.id),
    info and (" for " .. info.displayName) or ""), "info")
  return true
end

function CartsPage:removeCart(version, row)
  local l = self.launcher
  local key = "cart:" .. tostring(row.id)
  if l.armedDelete ~= key then
    l.armedDelete = key
    return l:say("Press Remove again to uninstall " .. tostring(row.title)
      .. ". Its saves are kept.", "info")
  end
  l.armedDelete = nil
  local ok, done, err = pcall(require("src.carts.CartStore").uninstall, row.id)
  if l.cart[version] == row.id then l.cart[version] = nil end
  l.cartRows, l.cartPlans = nil, nil
  if not (ok and done) then
    return l:say("Could not remove " .. tostring(row.title) .. ": "
      .. tostring(ok and err or done), "error")
  end
  l:say(tostring(row.title) .. " was removed.", "info")
end

function CartsPage:pickCart()
  local l = self.launcher
  if l:requestHostPick("cart") then return end
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  if not (ok and FilePicker.available()) then
    return l:say("Drop a .g1rcart file onto this window to install it.", "info")
  end
  local path = FilePicker.open("Choose a custom cart", CART_KIND)
  if not path then return end
  local data, err = FilePicker.read(path)
  if not data then return l:say("Could not read that file: " .. tostring(err), "error") end
  self:installCart(data, FilePicker.basename(path))
end

-- The save the active cart would start on, and whether its seal is broken.
function CartsPage:cartSave(version)
  local l = self.launcher
  local ok, slot = pcall(l.currentSave, l, version)
  slot = ok and slot or nil
  local broken = false
  local cart = l:activeCart(version)
  if cart and slot then
    local okS, SaveData = pcall(require, "src.core.SaveData")
    if okS and SaveData.slotSealBroken then
      local okB, b = pcall(SaveData.slotSealBroken, cart, slot.id)
      broken = okB and b == true
    end
  end
  return slot, broken
end

-- What the installed mods are, in the shape Loader.planCart reads.
function CartsPage:installedMods(version)
  local installed = {}
  for _, row in ipairs(self.launcher:modsFor(version)) do
    if row.manifest then
      installed[row.id] = { id = row.id, version = row.manifest.version }
    end
  end
  return installed
end

-- nil when the active cart can start, else why the mod loader would refuse
-- it.  A save whose seal is broken no longer enforces the cart's pins.
function CartsPage:cartProblem(version)
  local l = self.launcher
  local cart = l:activeCart(version)
  if not cart then return nil end
  local _, broken = self:cartSave(version)
  local key = cart .. (broken and "#broken" or "")
  l.cartPlans = l.cartPlans or {}
  local plan = l.cartPlans[key]
  if plan == nil then
    plan = false
    pcall(function()
      local report = require("src.mods.Loader").planCart(
        require("src.carts.CartStore").get(cart), self:installedMods(version), broken)
      if report and report.refused then
        plan = tostring(report.message or "this cart cannot start")
        -- the message leads with the cart's title, which the panel already shows
        local title = tostring(report.title or "") .. ": "
        if plan:sub(1, #title) == title then plan = plan:sub(#title + 1) end
      end
    end)
    l.cartPlans[key] = plan
  end
  return plan or nil
end

-- The pinned mods a cart needs that are missing or at another version:
-- { fetch = jobs it can download, manual = ids it cannot }.
function CartsPage:pinsToFetch(version, cartId)
  local l = self.launcher
  local rows = l:modsFor(version)
  local key = tostring(rows) .. "|" .. tostring(cartId)
  if self.pinKey == key then return self.pins end
  local out = { fetch = {}, manual = {} }
  pcall(function()
    local cart = require("src.carts.CartStore").get(cartId)
    if type(cart) ~= "table" then return end
    local report = require("src.mods.Loader").planCart(cart, self:installedMods(version))
    local want = {}
    for _, r in ipairs(report.missing or {}) do want[#want + 1] = r.id end
    for _, r in ipairs(report.mismatched or {}) do want[#want + 1] = r.id end
    for _, id in ipairs(want) do
      local pin = report.pins and report.pins[id]
      if pin and pin.source == "github" and pin.repo and pin.version and pin.sha256 then
        out.fetch[#out.fetch + 1] = { kind = "mod", id = id, name = id, repo = pin.repo,
          version = pin.version, sha256 = pin.sha256, replace = true, verb = "Installed" }
      else
        out.manual[#out.manual + 1] = id
      end
    end
  end)
  self.pinKey, self.pins = key, out
  return out
end

function CartsPage:fetchPins(version, cartId)
  local l = self.launcher
  local need = self:pinsToFetch(version, cartId)
  if #need.fetch == 0 then
    if #need.manual > 0 then
      return l:say("Install these by hand, they have no release to fetch: "
        .. table.concat(need.manual, ", ") .. ".", "error")
    end
    return l:say("This cart has every mod it pins.", "info")
  end
  if not ModsPage.canFetch() then
    return l:say("This device cannot download mods from the launcher.", "error")
  end
  local mods = l:modsUi()
  local n = 0
  for _, job in ipairs(need.fetch) do
    if not mods:queued(job.id) then
      local copy = {}
      for k, v in pairs(job) do copy[k] = v end
      mods:enqueue(copy)
      n = n + 1
    end
  end
  self.pinKey = nil
  if n > 0 then
    l:say(("Fetching %d pinned %s."):format(n, n == 1 and "mod" or "mods"), "info")
  end
end

-- Write a cart to exports/carts/ and hand it to the system's save dialog
-- where there is one.
function CartsPage:exportCart(id)
  local l = self.launcher
  local ok, text, err = pcall(require("src.carts.CartStore").export, id)
  if not ok then text, err = nil, text end
  if not text then return l:say("Could not export that cart: " .. tostring(err), "error") end
  local lfs = love.filesystem
  local rel = "exports/carts/" .. id .. ".g1rcart"
  pcall(lfs.createDirectory, "exports/carts")
  local okW, wrote = pcall(lfs.write, rel, text)
  if not (okW and wrote) then return l:say("Could not write " .. rel .. ".", "error") end
  local dir = lfs.getSaveDirectory and lfs.getSaveDirectory() or ""
  local path = (dir ~= "" and (dir .. "/") or "") .. rel
  if l.shareExport and l:shareExport(path) then return end
  l:say("Exported to " .. path, "info")
end

-- Stop this save enforcing the cart's mod setup, for good.
function CartsPage:breakSeal(version)
  local l = self.launcher
  local cart = l:activeCart(version)
  local slot, broken = self:cartSave(version)
  if not (cart and slot) or broken then return end
  local key = "seal:" .. cart .. ":" .. tostring(slot.id)
  if l.armedDelete ~= key then
    l.armedDelete = key
    return l:say("Press again to break the seal on this save. It then plays with your "
      .. "own mods too, and cannot be sealed again.", "error")
  end
  l.armedDelete = nil
  local SaveData = require("src.core.SaveData")
  local ok, done, err = pcall(SaveData.markSlotSealBroken, cart, slot.id)
  l.cartPlans = nil
  if not (ok and done) then
    return l:say("Could not break the seal: " .. tostring(ok and err or done), "error")
  end
  l:say("The seal on this save is broken.", "info")
end

-- A cart id from its title: lower case, dashes, unique among installed carts.
function CartsPage:newId(version, title)
  local base = trim(title):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if base == "" then base = "my-cart" end
  base = base:sub(1, 56)
  local taken = {}
  local okC, all = pcall(require("src.carts.CartStore").list)
  for _, c in ipairs(okC and type(all) == "table" and all or {}) do taken[c.id] = true end
  for _, c in ipairs(self.launcher:cartsFor(version)) do taken[c.id] = true end
  local id, n = base, 1
  while taken[id] do
    n = n + 1
    id = base .. "-" .. n
  end
  return id
end

local function shellFor(version)
  local c = Theme.gameColor(version) or { 128, 128, 128 }
  local function byte(v)
    v = tonumber(v) or 0
    if v <= 1 then v = v * 255 end
    return math.max(0, math.min(255, math.floor(v + 0.5)))
  end
  return ("#%02x%02x%02x"):format(byte(c[1]), byte(c[2]), byte(c[3]))
end

-- Save the mods set up for this game, with their options and order, as a
-- new cart.  form: { title, author, open }.
function CartsPage:saveAsCart(version, form)
  local l = self.launcher
  local title, author = trim(form.title), trim(form.author)
  if title == "" then return l:say("Give the cart a title.", "error") end
  if author == "" then return l:say("Say who made the cart.", "error") end
  local CartStore = require("src.carts.CartStore")
  local CartManifest = require("src.carts.CartManifest")
  local mods = l:modsUi()
  local order, byId = mods:orderList(version)
  local rows = {}
  for _, id in ipairs(order) do
    local row = byId[id]
    if row and row.supported then rows[#rows + 1] = row end
  end
  if #rows == 0 then
    return l:say("Install a mod for " .. gameName(version) .. " first: a cart pins at least one.", "error")
  end
  local okO, modOptions = pcall(require("src.mods.ModLibrary").modOptions)
  local identity = { id = self:newId(version, title), title = title:sub(1, 48),
    author = author:sub(1, 64), version = "1.0.0", base = version,
    seal = form.open and "open" or "sealed", shell = shellFor(version) }
  local ok, cart, unresolved = pcall(CartStore.capture, identity, rows, okO and modOptions or {})
  if not ok then cart, unresolved = nil, cart end
  if not cart then return l:say("Could not make the cart: " .. tostring(unresolved), "error") end
  local okI, installed, err = pcall(CartStore.install, CartManifest.encode(cart))
  if not okI then installed, err = nil, installed end
  l.cartRows, l.cartPlans = nil, nil
  if not installed then return l:say("Could not save the cart: " .. tostring(err), "error") end
  self.form = nil
  l.page = "carts"
  local local_ = type(unresolved) == "table" and #unresolved or 0
  local text = ("Saved %s as a cart for %s."):format(cart.title, gameName(version))
  if local_ > 0 then
    text = text .. (" %d of its mods can only be fetched on this device, so share it "
      .. "with people who have them."):format(local_)
  end
  l:say(text, "info")
  return cart
end

-- ------------------------------------------------------------------- draw

function CartsPage:draw(x, y, w, h, s)
  local l = self.launcher
  if not (l.selected and l.ready[l.selected]) then return l:drawGame(x, y, w, h, s) end
  if l.page == "cartnew" then
    return l:drawFitted("cartnew", x, y, w, h, s, function(_, ...) return self:drawNew(...) end)
  end
  return self:drawCarts(x, y, w, h, s)
end

local function twoLines(title, detail, x, y, h, w, titleInk, detailInk, s)
  local th, dh = Kit.textHeight("button"), Kit.textHeight("micro")
  local top = y + (h - th - dh - Theme.space("xxs", s)) / 2
  Kit.text("button", Kit.ellipsize("button", tostring(title), w), x, top, titleInk)
  Kit.text("micro", Kit.ellipsize("micro", tostring(detail or ""), w), x,
    top + th + Theme.space("xxs", s), detailInk)
end

-- The actions for the cart a game plays as now.
function CartsPage:activeItems(v)
  local l = self.launcher
  local active, row = l:activeCart(v)
  if not active then return {} end
  local items = {
    { label = "Export", id = "cart-export", run = function() self:exportCart(active) end },
  }
  local pins = self:pinsToFetch(v, active)
  local missing = #pins.fetch + #pins.manual
  if missing > 0 then
    items[#items + 1] = { label = ("Get its mods (%d)"):format(missing), id = "cart-fetch",
      kind = "primary", enabled = #pins.fetch > 0,
      run = function() self:fetchPins(v, active) end }
  end
  local slot, broken = self:cartSave(v)
  if row and row.seal and row.seal ~= "open" and slot and not broken then
    local armed = l.armedDelete == "seal:" .. active .. ":" .. tostring(slot.id)
    items[#items + 1] = { label = armed and "Confirm: break seal" or "Break the seal",
      id = "cart-break-seal", kind = "danger", keepArmed = true,
      run = function() self:breakSeal(v) end }
  end
  return items
end

function CartsPage:drawCarts(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local bh = math.max(Kit.tapMin(), math.floor(40 * s))
  cy = l:pageHeader(cx, cy, cw, s, { title = "Carts",
    subtitle = "Play " .. gameName(v) .. " as", accent = Theme.gameColor(v),
    back = function() l.page = nil end, backId = "carts-back" })
  cy = l:modsUi():drawJobStrip(cx, cy, cw, s)

  local carts = l:cartsFor(v)
  local active = l:activeCart(v)
  local rows = { { original = true, title = "The original game",
                   detail = "No cart: your own mods and saves" } }
  for _, c in ipairs(carts) do rows[#rows + 1] = c end
  local hint = "Or drop a .g1rcart file onto this window. Each cart keeps "
    .. "its own saves."
  local hintH = Kit.wrapHeight("micro", hint, cw)
  local items = self:activeItems(v)
  local gap8 = math.floor(8 * s)
  local actH = #items > 0 and (Kit.textHeight("caption") + Theme.space("s", s)
    + ModsPage.flowHeight(cw, s, items)) or 0
  local rowH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(56 * s))
  local gap = math.floor(4 * s)
  local footY = y + h - pad - bh - hintH - gap8
  local viewH = math.max(rowH, footY - gap8 - actH - cy)
  local maxAt = Kit.scrollExtent(#rows * (rowH + gap), viewH)
  l.cartScroll = Kit.scrollInput(l.cartScroll or 0, maxAt, cx, cy, cw, viewH)
  local py = Kit.scrollBegin(cx, cy, cw, viewH, l.cartScroll, maxAt)
  local rw = cw - Kit.scrollGutter(s)
  local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Confirm") + math.floor(24 * s))
  local sbh = math.max(Kit.tapMin(), math.floor(32 * s))
  for i, row in ipairs(rows) do
    local ry = py + (i - 1) * (rowH + gap)
    local chosen = (row.original and active == nil) or (row.id ~= nil and row.id == active)
    local clicked, ink = Kit.row(cx, ry, rw, rowH, chosen,
      "cart-" .. tostring(row.id or "original"))
    local tx = cx + math.floor(12 * s)
    local textW = rw - bw - math.floor(36 * s)
    local detail = row.detail
    if not detail then
      local parts = {}
      if row.version then parts[#parts + 1] = "v" .. tostring(row.version) end
      if row.author then parts[#parts + 1] = "by " .. tostring(row.author) end
      if row.seal and row.seal ~= "open" then parts[#parts + 1] = "sealed" end
      detail = table.concat(parts, "  -  ")
    end
    twoLines(row.title or row.id, detail, tx, ry, rowH, textW, ink or PAL.text,
      chosen and (ink or PAL.text) or PAL.muted, s)
    local rbx, rby = cx + rw - bw - math.floor(8 * s), ry + (rowH - sbh) / 2
    -- a press on Remove is not also a press on its row
    if clicked and (row.original or not Kit.hit(rbx, rby, bw, sbh)) then
      l:queue(function() l:selectCart(v, row.id) end)
    end
    if not row.original then
      local armed = l.armedDelete == "cart:" .. tostring(row.id)
      if Kit.button(rbx, rby, bw, sbh, armed and "Confirm" or "Remove",
          { id = "cart-remove-" .. tostring(row.id), font = "small", kind = "danger" }) then
        l:queue(function() self:removeCart(v, row) end, true)
      end
    end
  end
  Kit.scrollEnd(cx, cy, cw, viewH, l.cartScroll, maxAt, PAL.surface)

  if #items > 0 then
    local ay = footY - gap8 - actH
    Kit.caption(cx, ay, "THIS CART", PAL.caption)
    l:modsUi():flow(cx, ay + Kit.textHeight("caption") + Theme.space("s", s), cw, s, items)
  end
  local iw = math.min(math.floor((cw - math.floor(10 * s)) / 2), math.floor(260 * s))
  if Kit.button(cx, footY, iw, bh, "Install cart", { id = "cart-install", kind = "accent" }) then
    l:queue(function() self:pickCart() end)
  end
  if Kit.button(cx + iw + math.floor(10 * s), footY, iw, bh, "Save mods as cart",
      { id = "cart-new" }) then
    l:queue(function()
      self.form = { title = "", author = "", open = false }
      l.page = "cartnew"
    end)
  end
  Kit.textWrapped("micro", hint, cx, footY + bh + gap8, cw, PAL.faint)
end

-- The form that saves the current mod setup as a cart.
function CartsPage:drawNew(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "New cart",
    subtitle = "Saves the mods set up for " .. gameName(v) .. ", their options and load "
      .. "order, as a cart with its own saves.",
    back = function() l.page = "carts" end, backId = "cartnew-back" })
  self.form = self.form or { title = "", author = "", open = false }
  local f = self.form
  local rh = btnH(s)
  local gap = Theme.space("s", s)
  Kit.caption(cx, cy, "TITLE", PAL.caption)
  cy = cy + Kit.textHeight("caption") + Theme.space("xs", s)
  f.title = Kit.textfield("cart-title", cx, cy, cw, rh, f.title, "My cart")
  cy = cy + rh + gap
  Kit.caption(cx, cy, "MADE BY", PAL.caption)
  cy = cy + Kit.textHeight("caption") + Theme.space("xs", s)
  f.author = Kit.textfield("cart-author", cx, cy, cw, rh, f.author, "Your name")
  cy = cy + rh + gap * 2
  local tw = math.floor(96 * s)
  Kit.textBold("button", "Sealed", cx, cy + (rh - Kit.textHeight("button")) / 2, PAL.heading)
  local sealed, hit = Kit.toggle(cx + cw - tw, cy, tw, rh, not f.open, "cart-seal")
  if hit then f.open = not sealed end
  cy = cy + rh + Theme.space("xxs", s)
  local note = f.open and "Open: players can add their own mods on top."
    or "Sealed: the cart's saves play only with the mods it pins."
  Kit.textWrapped("small", note, cx, cy, cw - tw - gap, PAL.muted)
  cy = cy + Kit.wrapHeight("small", note, cw - tw - gap) + gap * 2
  cy = l:modsUi():flow(cx, cy, cw, s, {
    { label = "Save cart", id = "cart-save", kind = "primary",
      run = function() self:saveAsCart(v, f) end } })
  return cy + pad - y
end

return CartsPage
