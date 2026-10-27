-- PK:GB launcher: pick a game, import its ROM, pick a save, play.
--
-- Written from scratch for this project.  It talks to the rest of the game
-- only through GPL modules: src/import/ImportJob.lua (verify + extract),
-- CacheContract (is a game imported?), SaveData (save slots), FilePicker,
-- and the shared UI kit in src/ui/kit/.  main.lua drives it through the
-- same host callbacks it uses for any front end (update, draw, the input
-- callbacks, filedropped) and gets control back through onLaunch(version).
--
-- Layout: a game list beside a detail panel on a wide window, stacked on a
-- narrow one.  Everything is rebuilt each frame from this object's state;
-- clicks only queue work, which update() runs, so a launch never tears down
-- the frame that asked for it.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local Icons = require("src.ui.kit.Icons")
local GameVersion = require("src.core.GameVersion")
local Version = require("src.core.Version")
local ImportJob = require("src.import.ImportJob")

local PAL = Theme.PAL

local Launcher = {}
Launcher.__index = Launcher

-- LICENSE.MD, Additional Terms 1: every launcher shows this credit.
Launcher.CREDIT_URL = "https://github.com/bryanthaboi/gen1recomp"
Launcher.CREDIT = "Based on the Pokemon Gen 1 Recompilation Project by BOIS "
  .. "CLUB GAMES, LLC (" .. Launcher.CREDIT_URL .. ")"

local ROM_KIND = { label = "Game Boy ROM",
  exts = { "gb", "gbc", "gba", "zip", "7z" } }

-- ------------------------------------------------------------------ model

local function cacheReady(version)
  local ok, CacheContract = pcall(require, "src.import.CacheContract")
  if not ok then return false end
  local okR, ready = pcall(CacheContract.isImported or CacheContract.isReady, version)
  return okR and ready or false
end

-- Imported by an older build: the cache marker is there but no longer
-- passes (a new cache format).  The game shows "Update needed" and offers
-- to import again instead of reading as never imported.
local function cacheStale(version)
  local ok, CacheContract = pcall(require, "src.import.CacheContract")
  if not ok or not CacheContract.readMarker then return false end
  local okM, marker = pcall(CacheContract.readMarker, version)
  return okM and type(marker) == "string" and marker ~= "" or false
end

local function visibleGame(version)
  local ok, SecretGames = pcall(require, "src.import.SecretGames")
  if ok and SecretGames.visible then
    local okV, shown = pcall(SecretGames.visible, version)
    if okV then return shown and true or false end
  end
  return true
end

-- Once per process, before the first launcher reads the cache: move a
-- pre-#899 Red cache into red/ (src/import/CacheFs.lua).
local migrated = false

function Launcher.new(onLaunch, opts)
  opts = opts or {}
  if not migrated then
    migrated = true
    pcall(function() require("src.import.CacheFs").migrateLegacyRedCache() end)
  end
  local self = setmetatable({
    onLaunch = onLaunch,
    opts = opts,
    games = {},
    ready = {},
    slots = {},
    actions = {},
    message = nil,       -- { text, kind = "error" | "info" }
    job = nil,           -- the running ImportJob
    selectedSlot = {},
    cart = {},           -- version -> chosen custom cart id (nil: the original)
    listScroll = 0,
    slotScroll = 0,
  }, Launcher)
  self:refresh()
  local okS, SaveData = pcall(require, "src.core.SaveData")
  local okO, saved = false, nil
  if okS then okO, saved = pcall(SaveData.loadOptions) end
  if okO and type(saved) == "table" and type(saved.activeCart) == "table" then
    for version, id in pairs(saved.activeCart) do
      if type(id) == "string" then self.cart[version] = id end
    end
  end
  local first
  for _, v in ipairs(self.games) do
    if self.ready[v] then first = first or v end
  end
  -- nothing ready: a game waiting on an update before one never imported
  for _, v in ipairs(self.games) do
    if not first and self.stale[v] then first = v end
  end
  local last = okO and type(saved) == "table" and saved.lastVersion or nil
  self.selected = (opts.initialGame and self.ready[opts.initialGame]
    and opts.initialGame) or (last and (self.ready[last] or self.stale[last]) and last)
    or first or self.games[1]
  -- ask the self-updater (src/update/Check.lua) whether a release is out;
  -- it works on a worker thread and is a no-op where it cannot run
  if not opts.noUpdateCheck then
    local okC, Check = pcall(require, "src.update.Check")
    if okC then pcall(Check.start) end
  end
  -- a portable install whose game folder cannot be written says so up front
  local okF, portableErr = pcall(function()
    return require("src.import.CacheFs").portableError()
  end)
  if okF and portableErr then self:say(tostring(portableErr), "error") end
  -- Switch / PS4 import folders: make them, then take what is waiting
  if require("src.launcher.Inbox").enabled() then
    pcall(require("src.launcher.Inbox").prepare)
    self:queue(function() self:scanInbox() end)
  end
  -- back from an online battle: reopen Online and sign back in
  if opts.initialGame == "online" then
    self:openOnline()
    self:queue(function() self.online:connect() end)
  end
  -- opened on a page: the Box (a Box error sends the player back to it),
  -- the selected game's Mods (an update before launch failed)
  if opts.initialGame == "box" then self:queue(function() self:openBox() end) end
  if opts.initialGame == "mods" then self.page = "mods" end
  -- an invite link: Online takes it from here (OnlinePage reads it)
  if type(opts.invite) == "string" and opts.invite ~= "" then
    self.pendingInvite = opts.invite
    self:openOnline()
  end
  local o = self:options()
  self:applyMotion(o.reduceMotion)
  if o.autoReimport then self:queue(function() self:autoReimport() end) end
  -- keyboard and pad focus start on the chosen game, ring hidden until used
  if self.selected then
    Kit.focusId = "game-" .. self.selected
    Kit._ringShown = false
  end
  -- Dev harness: import a ROM from a path at startup, so a scripted run can
  -- exercise the whole import flow without a picker or a drag and drop.
  if opts.importPath then self:startPath(opts.importPath) end
  return self
end

-- Re-read which games are imported and what save slots each has.
function Launcher:refresh()
  self.games = {}
  for _, v in ipairs(GameVersion.ORDER) do
    if visibleGame(v) then self.games[#self.games + 1] = v end
  end
  self.stale = {}
  for _, v in ipairs(self.games) do
    self.ready[v] = cacheReady(v)
    self.stale[v] = not self.ready[v] and cacheStale(v)
  end
  self.slots = {}
  self:publishShortcuts()
end

-- Android: one home-screen shortcut per imported game
-- (love.system.updateShortcuts, mobile/android/.../wrap_System.cpp), sent
-- again only when the set changes.
function Launcher:publishShortcuts()
  local sys = love and love.system
  if not (sys and type(sys.updateShortcuts) == "function") then return end
  local list = {}
  for _, v in ipairs(self.games) do
    if self.ready[v] then list[#list + 1] = v end
  end
  local key = table.concat(list, ",")
  if key == Launcher.shortcutsSent then return end
  if pcall(sys.updateShortcuts, list) then Launcher.shortcutsSent = key end
end

-- ------------------------------------------------------------------ carts

-- Installed custom carts for a game (src/carts/CartStore.lua), cached.
function Launcher:cartsFor(version)
  self.cartRows = self.cartRows or {}
  local rows = self.cartRows[version]
  if rows then return rows end
  local ok, CartStore = pcall(require, "src.carts.CartStore")
  local okL, got = false, nil
  if ok then okL, got = pcall(CartStore.listFor, version) end
  rows = (okL and type(got) == "table") and got or {}
  self.cartRows[version] = rows
  return rows
end

-- The cart a game plays as, or nil for the original; a remembered cart that
-- is no longer installed reads as the original.
function Launcher:activeCart(version)
  local id = self.cart[version]
  if not id then return nil end
  for _, row in ipairs(self:cartsFor(version)) do
    if row.id == id then return id, row end
  end
  return nil
end

-- Saves are kept per game, and per cart inside a game: the key both caches
-- (self.slots, self.selectedSlot) are indexed by.
function Launcher:scopeKey(version)
  local cart = self:activeCart(version)
  return cart and (version .. "#" .. cart) or version
end

-- SaveData's slot calls for the game's current scope.
function Launcher:store(version)
  local SaveData = require("src.core.SaveData")
  local cart = self:activeCart(version)
  if cart then
    return {
      list = function() return SaveData.listCartSlots(cart) end,
      active = function() return SaveData.activeCartSlot(cart) end,
      setActive = function(id) return SaveData.setActiveCartSlot(cart, id) end,
      create = function() return SaveData.createCartSlot(cart) end,
      delete = function(id) return SaveData.deleteCartSlot(cart, id) end,
      rename = function(id, name) return SaveData.renameCartSlot(cart, id, name) end,
      cart = cart,
    }
  end
  return {
    list = function() return SaveData.listSlots(version) end,
    active = function() return SaveData.activeSlot(version) end,
    setActive = function(id) return SaveData.setActiveSlot(version, id) end,
    create = function() return SaveData.createSlot(version) end,
    delete = function(id) return SaveData.deleteSlot(version, id) end,
    rename = function(id, name) return SaveData.renameSlot(version, id, name) end,
  }
end

-- What the mod loader will make of a cart's pinned mods: nil when it can
-- run, else the reason it will be refused (src/launcher/CartsPage.lua).
function Launcher:cartProblem(version) return self:cartsUi():cartProblem(version) end

-- Leave the per-save state behind when the game or cart changes: slot ids
-- repeat across games, so an open menu or rename would act on the new
-- game's save.  A pending import question is answered "no" (its file is
-- cleaned up).
function Launcher:clearSaveState()
  self.renaming, self.saveMenu, self.saveMenuRect = nil, nil, nil
  self.gameMenu, self.gameMenuRect = nil, nil
  if self.saveConfirm then self:confirmSave(false) end
end

function Launcher:selectGame(v)
  if self.selected ~= v then self:clearSaveState() end
  self.selected = v
end

function Launcher:selectCart(version, id)
  self:clearSaveState()
  self.cart[version] = id
  self.cartPlans = nil
  self:rememberCarts()
end

function Launcher:rememberCarts()
  local opts = self:options()
  local map = {}
  for version, id in pairs(self.cart) do
    if self:activeCart(version) == id then map[version] = id end
  end
  opts.activeCart = next(map) ~= nil and map or nil
  local ok, SaveData = pcall(require, "src.core.SaveData")
  if ok then pcall(SaveData.saveOptions, opts) end
end

-- Installing, removing and picking carts live in src/launcher/CartsPage.lua.
function Launcher:cartsUi()
  self.cartsPage = self.cartsPage or require("src.launcher.CartsPage").new(self)
  return self.cartsPage
end
function Launcher:installCart(data, name) return self:cartsUi():installCart(data, name) end
function Launcher:removeCart(version, row) return self:cartsUi():removeCart(version, row) end
function Launcher:pickCart() return self:cartsUi():pickCart() end

function Launcher:slotsFor(version)
  local key = self:scopeKey(version)
  local list = self.slots[key]
  if list then return list end
  local okS, store = pcall(self.store, self, version)
  list = {}
  if okS then
    local okL, got = pcall(store.list)
    if okL and type(got) == "table" then
      for _, s in ipairs(got) do
        if s.exists then list[#list + 1] = s end
      end
    end
  end
  self.slots[key] = list
  -- the choice must be a save that exists: the active slot can be a New
  -- game nobody saved yet, or the one a delete left behind
  local function listed(id)
    for _, sl in ipairs(list) do if sl.id == id then return true end end
    return false
  end
  if not listed(self.selectedSlot[key]) then
    local okA, active = false, nil
    if okS then okA, active = pcall(store.active) end
    self.selectedSlot[key] = (okA and listed(active) and active) or (list[1] and list[1].id) or nil
  end
  return list
end

function Launcher:queue(fn, keepArmed)
  if not keepArmed then self.armedDelete = nil end
  self.actions[#self.actions + 1] = fn
end

-- ---------------------------------------------------------------- actions

-- The one message line, shown as a toast: info fades after a few seconds,
-- an error stays longer; a press on it dismisses it.
Launcher.TOAST_INFO, Launcher.TOAST_ERROR = 4, 8
Launcher.SLIDE_TIME = 0.15

local function now()
  return love.timer and love.timer.getTime and love.timer.getTime() or os.clock()
end

-- `action` = { label, run } adds one button to the toast (and keeps it up
-- a little longer, so there is time to press it).
function Launcher:say(text, kind, action)
  self.message = text and { text = text, kind = kind or "info", at = now(), action = action } or nil
end

function Launcher:drawToast(x, y, w, s)
  local m = self.message
  self.toastRect = nil
  if not m then return end
  local life = (m.kind == "error" or m.action) and Launcher.TOAST_ERROR or Launcher.TOAST_INFO
  local age = now() - (m.at or now())
  if age > life then
    self.message = nil
    return
  end
  local alpha = math.min(1, (life - age) / 0.4, age / 0.12 + 0.2)
  local pad = Theme.space("m", s)
  local icon = math.floor(18 * s)
  local tw = math.min(w - 2 * pad, math.floor(560 * s))
  local actW = m.action and (Kit.textWidth("small", m.action.label) + Theme.space("xl", s)) or 0
  local actH = math.max(Kit.tapMin(), math.floor(30 * s))
  local textW = tw - 3 * pad - icon - (actW > 0 and actW + pad or 0)
  local th = Kit.wrapHeight("small", m.text, textW)
  local lines = math.min(3, math.max(1, math.floor(th / Kit.textHeight("small") + 0.5)))
  local h = math.max(lines * Kit.textHeight("small"), m.action and actH or 0) + 2 * pad
  local bx = x + (w - tw) / 2
  local color = m.kind == "error" and PAL.red or PAL.green
  Theme.shadow(bx, y, tw, h, Theme.radius())
  Theme.fillRounded(bx, y, tw, h, PAL.raised, alpha, Theme.radius())
  Theme.fillRounded(bx, y, math.max(3, math.floor(4 * s)), h, color, alpha, 2)
  Icons.draw(m.kind == "error" and "triangle-alert" or "check", bx + pad, y + pad, icon, color, alpha)
  Kit.textWrapped("small", m.text, bx + 2 * pad + icon, y + pad, textW, PAL.text, lines)
  self.toastRect = { bx, y, tw, h }
  local wasOverlay = Kit._overlay
  Kit._overlay = true
  local acted = false
  if m.action then
    acted = Kit.button(bx + tw - pad - actW, y + (h - actH) / 2, actW, actH, m.action.label,
      { id = "toast-action", font = "small" })
    if acted then
      local run = m.action.run
      self:queue(function() self.message = nil; run() end, true)
    end
  end
  if not acted and Kit.press(bx, y, tw, h) then
    self:queue(function() self.message = nil end, true)
  end
  Kit._overlay = wasOverlay
end

-- Verify bytes from a picker or a drop and start importing them.
function Launcher:importData(data, name)
  if self.job and self.job.state == "working" then
    return self:say("An import is already running.", "error")
  end
  local rom, err = ImportJob.verify(data, name, visibleGame)
  local picked = self.pickedRomPath
  self.pickedRomPath = nil
  if not rom then return self:say(err, "error") end
  -- a desktop path that verified is where this game comes from next time
  if picked then
    local opts = self:options()
    opts.romSources = type(opts.romSources) == "table" and opts.romSources or {}
    opts.romSources[rom.version] = picked
    self:setOption("romSources", opts.romSources)
  end
  self:selectGame(rom.version)
  self:say(nil)
  self.job = ImportJob.start(rom)
  if self.job.state == "error" then
    self:say(self.job.error, "error")
    self.job = nil
  end
end

-- Hosts without a desktop file dialog open files through love.system:
-- pickFile(kind) shows the platform's picker, and the chosen file arrives
-- one of two ways.
--   path:    the browser and UWP builds hand it back through getPickedFile()
--            as a temporary path, or getPickError() explains why not
--            (ports/web/native/lovejs_bridge.cpp).
--   savedir: Android and iOS copy it into the save directory under a fixed
--            name per kind (mobile/android/.../System.cpp,
--            mobile/ios/native/GRPickerBridge.swift).
local PICKED = { rom = "picked_rom.gb", mod = "picked_mod.zip", sav = "picked_save.sav",
                 cart = "picked_cart.g1rcart", required_import = "picked_required_import.bin" }

local function hostPicker()
  local sys = love and love.system
  if not (sys and type(sys.pickFile) == "function") then return nil end
  if type(sys.getPickedFile) == "function" then return sys, "path" end
  local os_ = type(sys.getOS) == "function" and sys.getOS() or ""
  if os_ == "Android" or os_ == "iOS" then return sys, "savedir" end
  return nil
end

-- `as` names what the picked file is for when it differs from the picker's
-- filter (a Box save is picked with the "sav" filter).
function Launcher:requestHostPick(kind, as)
  local sys, mode = hostPicker()
  if not sys then return false end
  if mode == "savedir" and PICKED[kind] then
    -- a file left from an earlier pick must not be taken for this one
    pcall(love.filesystem.remove, PICKED[kind])
  end
  local ok, started = pcall(sys.pickFile, kind)
  if not ok or started == false then
    self:say("The file picker could not open.", "error")
    return true
  end
  self.pendingPick, self.pendingPickFile = as or kind, mode == "savedir" and PICKED[kind] or nil
  return true
end

-- Hand a picked file to what asked for it.  `path` is absolute; `read`
-- returns its bytes; `release` deletes it once nothing needs it.
function Launcher:takePick(kind, path, name, read, release)
  if kind == "sav" then
    -- by path: SaveFileIO only takes raw bytes for a bare 32 KiB image,
    -- and a Gen 2 save (RTC footer) or a Gen 3 one is larger
    if self:importSave(path, name, nil, release) ~= "confirm" then release() end
    return
  end
  local data, err = read()
  release()
  if kind == "box" then return self:importBox(data, err) end
  if kind == "modfile" then return self:storeModFile(data, err) end
  if kind == "importer" then return self:startImporter(data, err) end
  if not data then
    return self:say("Could not read that file: " .. tostring(err), "error")
  end
  if kind == "cart" then return self:installCart(data, name) end
  if kind == "mod" then return self:installMod(data, name) end
  return self:importData(data, name)
end

-- Collect a finished host pick; called from update().
function Launcher:pollHostPick()
  local sys = self.pendingPick and hostPicker()
  if not sys then return end
  local kind = self.pendingPick
  local file = self.pendingPickFile
  if file then
    local lfs = love.filesystem
    if lfs.getInfo(file) then
      self.pendingPick, self.pendingPickFile = nil, nil
      return self:takePick(kind, lfs.getSaveDirectory() .. "/" .. file, file,
        function() return lfs.read(file) end,
        function() pcall(lfs.remove, file) end)
    end
  else
    local okP, path = pcall(sys.getPickedFile)
    if okP and type(path) == "string" and path ~= "" then
      self.pendingPick = nil
      local FilePicker = require("src.core.FilePicker")
      return self:takePick(kind, path, FilePicker.basename(path),
        function() return FilePicker.read(path) end,
        function() pcall(os.remove, path) end)
    end
  end
  local okE, err = false, nil
  if type(sys.getPickError) == "function" then okE, err = pcall(sys.getPickError) end
  if okE and type(err) == "string" and err ~= "" then
    self.pendingPick, self.pendingPickFile = nil, nil
    -- closing the picker is not an error
    if not err:match("^cancelled:") then self:say(err, "error") end
  end
end

-- Pick a file on a desktop or handheld: the system dialog when there is
-- one, else the in-app browser (a minimal Linux desktop, a handheld).
-- `onPath(path)` runs from the queue once a file is chosen; a cancel does
-- nothing.  Returns false when neither can run (say `dropHint` instead).
function Launcher:pickPath(prompt, kind, browseMode, onPath, dropHint)
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  if ok and FilePicker.available() and FilePicker.hasDialog() then
    local path = FilePicker.open(prompt, kind)
    if path then onPath(path) end
    return true
  end
  if ok and FilePicker.available() then
    Kit.FileBrowser.open({ title = prompt, mode = browseMode,
      onSelect = function(path) self:queue(function() onPath(path) end) end })
    return true
  end
  if dropHint then self:say(dropHint, "info") end
  return false
end

-- Read a picked path and hand its bytes on; a read error is said.
local function readPicked(self, path, use)
  local FilePicker = require("src.core.FilePicker")
  local data, err = FilePicker.read(path)
  if not data then return self:say("Could not read that file: " .. tostring(err), "error") end
  use(data, FilePicker.basename(path))
end

function Launcher:pickRom()
  if self:requestHostPick("rom") then return end
  self:pickPath("Choose a Pokemon ROM", ROM_KIND, "rom", function(path)
    self:rememberRomSource(path)
    readPicked(self, path, function(data, name) self:importData(data, name) end)
  end, "Drop a .gb, .gbc or .gba file onto this window to import it.")
end

-- ------------------------------------------------------------------- mods

-- The mod pages and their actions live in src/launcher/ModsPage.lua; these
-- names stay for the rest of the launcher, main.lua and the tests.
function Launcher:modsUi()
  self.modsPage = self.modsPage or require("src.launcher.ModsPage").new(self)
  return self.modsPage
end
function Launcher:modsFor(version) return self:modsUi():modsFor(version) end
function Launcher:toggleMod(version, row) return self:modsUi():toggleMod(version, row) end
function Launcher:removeMod(row) return self:modsUi():removeMod(row) end
function Launcher:installMod(data, name) return self:modsUi():installMod(data, name) end
function Launcher:modNeeds(row) return self:modsUi():modNeeds(row) end
function Launcher:findModNeeds(row) return self:modsUi():findModNeeds(row) end
function Launcher:addModFile(row, spec) return self:modsUi():addModFile(row, spec) end
function Launcher:storeModFile(data, err) return self:modsUi():storeModFile(data, err) end
function Launcher:runImporter(id) return self:modsUi():runImporter(id) end
function Launcher:startImporter(data, err) return self:modsUi():startImporter(data, err) end
function Launcher:stepImporter(budget) return self:modsUi():stepImporter(budget) end

-- --------------------------------------------------------- import folder

-- Switch / PS4: take whatever waits in the imports folders
-- (src/launcher/Inbox.lua).  A file that imported is removed; one that did
-- not stays, reported once, so the player can see what was wrong.
function Launcher:scanInbox()
  local Inbox = require("src.launcher.Inbox")
  local lfs = love.filesystem
  self.inboxTried = self.inboxTried or {}
  local took, failed = 0, nil
  for _, item in ipairs(Inbox.scan()) do
    if not self.inboxTried[item.path] then
      self.inboxTried[item.path] = true
      local ok
      if item.kind == "save" then
        if self.ready[item.version] then
          local was = self.selected
          self.selected = item.version
          ok = self:importSave(lfs.getSaveDirectory() .. "/" .. item.path, item.name, nil,
            function() Inbox.take(item) end)
          if ok == "confirm" then ok = nil else self.selected = was end
        end
      elseif item.kind == "rom" then
        if not self:importing() then
          self:importData(lfs.read(item.path), item.name)
          ok = self:importing()
          if not ok then self.inboxTried[item.path] = true end
        else
          self.inboxTried[item.path] = nil -- one ROM at a time; next scan
        end
      else
        local data = lfs.read(item.path)
        if item.kind == "mod" then ok = self:installMod(data, item.name)
        elseif item.kind == "cart" then ok = self:installCart(data, item.name)
        elseif item.kind == "modfile" then ok = self:storeInboxModFile(data) end
      end
      if ok == true then
        Inbox.take(item)
        took = took + 1
      elseif ok == false or ok == nil then
        failed = failed or (self.message and self.message.kind == "error" and self.message.text)
      end
    end
  end
  if failed then self:say(failed, "error")
  elseif took > 1 then self:say(("Imported %d files from the imports folder."):format(took), "info") end
  return took
end

-- A file from imports/baseroms/: offer it to every installed mod still
-- missing one; RequiredImports checks its MD5 against each.
function Launcher:storeInboxModFile(data) return self:modsUi():storeInboxModFile(data) end
function Launcher:pickMod() return self:modsUi():pickMod() end

-- ------------------------------------------------------------------ skins

-- The on-screen controller skin in use (src/core/TouchSkin.lua), or nil for
-- the built-in pad.
function Launcher:activeSkin()
  local tc = self:options().touchControls
  if type(tc) ~= "table" or tc.enabled == false then return nil end
  return tc.skin
end

-- Skins are chosen, imported, exported and drawn in the Skin Studio, a
-- screen of its own: main.lua hands it the window and calls
-- resumeAfterOverlay when it closes.
function Launcher:openStudio(skinId)
  local open = self.opts.onOpenSkinStudio
  if not open then return self:say("The Skin Studio is not available here.", "error") end
  open(self.selected, skinId)
end

-- -------------------------------------------------------------------- box

-- The Pokemon Box (src/import/BoxPanel.lua and src/box/) runs as a page of
-- this launcher.  It draws through src/import/BoxHost.lua, which this
-- launcher points at the shared UI kit, and reads a few host fields:
-- tab == "box" while it is showing, _tabScroll.box, _tabRegionRect.
function Launcher:openBox()
  require("src.import.BoxHost").use(require("src.import.BoxHost").kit)
  self.page, self.tab = "box", "box"
  self._tabScroll = { box = 0 }
  local ok, err = pcall(require("src.import.BoxPanel").refresh, self)
  if not ok then
    self.page, self.tab = nil, nil
    self:say("The Box could not open: " .. tostring(err), "error")
  end
end

function Launcher:closeBox()
  pcall(require("src.import.BoxUI").close, self)
  if self._boxPrompt then pcall(require("src.import.BoxPrompt").close, self, false) end
  pcall(function()
    local Showcase = require("src.box.Showcase")
    local _, owner = Showcase.currentMusic()
    if owner == "box" then Showcase.stopMusic() end
  end)
  self.page, self.tab = nil, nil
  self.slots = {}
  -- hand the Box back to its default host
  require("src.import.BoxHost").use(nil)
end

-- BoxPrompt asks its host to take typed text for its rename field.
function Launcher:_armTextInput()
  Kit.setFocus("box-prompt")
  Kit.focus = "box-prompt"
  if love.keyboard and love.keyboard.setTextInput then pcall(love.keyboard.setTextInput, true) end
end
function Launcher:_disarmTextInput() Kit.blur() end

local BOX_KIND = { label = "Pokemon Box save", exts = { "gci", "sav" } }
local BOX_SIZES = { [0x76040] = true, [0x76000] = true }

function Launcher:importBox(data, why)
  local BoxPanel = require("src.import.BoxPanel")
  if data and not BOX_SIZES[#data] then
    data, why = nil, "Choose a native Box GCI (0x76040 bytes) or raw save (0x76000 bytes)."
  end
  return BoxPanel.importGCI(self, data, why)
end

-- BoxTools' "Import Box save" button.
function Launcher:chooseBoxImport()
  if self:requestHostPick("sav", "box") then return end
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  if not (ok and FilePicker.available()) then
    return self:importBox(nil, "Drop the Box .gci or .sav onto this window.")
  end
  if not FilePicker.hasDialog() then
    return self:pickPath("Choose a Pokemon Box save", BOX_KIND, "box", function(p)
      readPicked(self, p, function(data) self:importBox(data) end)
    end)
  end
  local path = FilePicker.open("Choose a Pokemon Box save", BOX_KIND)
  if not path then return end
  local data, err = FilePicker.read(path)
  self:importBox(data, err)
end

function Launcher:importing()
  return self.job ~= nil and self.job.state == "working"
end

function Launcher:play(version, slotId)
  -- the import only advances while this launcher runs; leaving now would
  -- strand it with that game's old data already cleared
  if self:importing() then return self:say("Wait for the import to finish.", "error") end
  local problem = self:cartProblem(version)
  if problem then return self:say(problem, "error") end
  local store = self:store(version)
  if slotId then store.setActive(slotId) end
  -- the next start opens on this game, playing as this cart
  local opts = self:options()
  opts.lastVersion = version
  local ok, SaveData = pcall(require, "src.core.SaveData")
  if ok then pcall(SaveData.saveOptions, opts) end
  self:rememberCarts()
  pcall(function() require("src.import.BoxHost").use(nil) end)
  self.launched = version
  -- no launch options: main.lua's shortcut boot reads opts ~= nil as a
  -- different request than the one it is waiting for
  if self.onLaunch then self.onLaunch(version, store.cart, nil) end
end

function Launcher:newGame(version)
  if self:importing() then return self:say("Wait for the import to finish.", "error") end
  local problem = self:cartProblem(version)
  if problem then return self:say(problem, "error") end
  local id = self:store(version).create()
  if not id then return self:say("Could not create a save slot.", "error") end
  self:play(version, id)
end

-- ------------------------------------------------------------ save files

local SAVE_KIND = { label = "Save file", exts = { "sav", "srm", "sa1", "dsv", "sgm" } }

function Launcher:selectedSaveId(version)
  version = version or self.selected
  if version then self:slotsFor(version) end -- settles the choice on a save that exists
  return self.selectedSlot[self:scopeKey(version)]
end

-- `source` is a dropped LÖVE file, an absolute path, or raw bytes.
-- Returns "confirm" when SaveFileIO asks before dropping an emulator footer;
-- the source must stay readable until confirmSave answers (`cleanup` then
-- runs).
function Launcher:importSave(source, name, force, cleanup)
  local v = self.selected
  if not (v and self.ready[v]) then
    return self:say("Import the game's ROM before importing a save for it.", "error")
  end
  if self:activeCart(v) then
    return self:say("Save files import into the original game, not a cart.", "error")
  end
  local SaveFileIO = require("src.import.SaveFileIO")
  local ok, result, info = SaveFileIO.importToSlot(source, v, force)
  self.slots[v] = nil
  if not ok and type(info) == "table" and info.needsConfirm then
    -- one question at a time: an earlier unanswered one is dropped cleanly
    if self.saveConfirm then self:confirmSave(false) end
    self.saveConfirm = { source = source, name = name, cleanup = cleanup, version = v,
      extra = (tonumber(info.size) or 32768) - 32768 }
    self:say(("%s has %d extra bytes after the save (an emulator's clock data). "
      .. "Import it without them?"):format(tostring(name or "This file"),
      self.saveConfirm.extra), "info")
    return "confirm"
  end
  if not ok then return self:say("Save import failed: " .. tostring(result), "error") end
  local SaveData = require("src.core.SaveData")
  local okA, active = pcall(SaveData.activeSlot, v)
  if okA and active then self.selectedSlot[v] = active end
  self:say((name and (name .. " ") or "The save ") .. "was imported as a new save.", "info")
  return true
end

function Launcher:editSave()
  local v, id = self.selected, self:selectedSaveId()
  if not (v and id and self.opts.onEditSave) then return end
  self.opts.onEditSave(v, id)
end

function Launcher:confirmSave(yes)
  local c = self.saveConfirm
  self.saveConfirm = nil
  if not c then return end
  if yes and c.version == self.selected then
    self:importSave(c.source, c.name, true)
  else
    self:say(nil)
  end
  if c.cleanup then c.cleanup() end
end

function Launcher:pickSave()
  if self:requestHostPick("sav") then return end
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  if not (ok and FilePicker.available()) then
    return self:say("Drop a .sav file onto this window to import it.", "info")
  end
  if not FilePicker.hasDialog() then
    return self:pickPath("Choose a save file", SAVE_KIND, "save", function(p)
      self:importSave(p, FilePicker.basename(p))
    end)
  end
  local path = FilePicker.open("Choose a save file", SAVE_KIND)
  if path then self:importSave(path, FilePicker.basename(path)) end
end

function Launcher:exportSave()
  local v, id = self.selected, self:selectedSaveId()
  if not (v and id) then return end
  if self:activeCart(v) then
    return self:say("Only the original game's saves export as .sav files.", "error")
  end
  local SaveData = require("src.core.SaveData")
  SaveData.setActiveSlot(v, id)
  local SaveFileIO = require("src.import.SaveFileIO")
  local ok, result = SaveFileIO.exportActiveSlot(v)
  if not ok then return self:say("Export failed: " .. tostring(result), "error") end
  if self:shareExport(result) then return end
  self:sayExported(result)
end

-- "Exported to <path>", with Open folder where the system can show one.
function Launcher:sayExported(path)
  local dir = tostring(path):match("^(.*)[/\\][^/\\]+$")
  local sys = love and love.system
  local okP, Platform = pcall(require, "src.core.Platform")
  local action
  if dir and sys and sys.openURL and okP and Platform.canSpawnProcess() then
    action = { label = "Open folder", run = function()
      local url = "file://" .. (dir:sub(1, 1) == "/" and "" or "/") .. dir:gsub("\\", "/")
      if not pcall(sys.openURL, url) then self:say("Could not open " .. dir, "error") end
    end }
  end
  self:say("Exported to " .. tostring(path), "info", action)
end

-- The selected save as its original .lua file (it keeps everything the .sav
-- format has no room for: mod data, port-only fields).
function Launcher:exportSaveLua()
  local v, id = self.selected, self:selectedSaveId()
  if not (v and id) then return end
  local ok, result = require("src.import.SaveFileIO").exportLuaSlot(v, id, self:activeCart(v))
  if not ok then return self:say("Export failed: " .. tostring(result), "error") end
  self:sayExported(result)
end

-- A copy of the selected save, chosen once it exists.
function Launcher:duplicateSave()
  local v, id = self.selected, self:selectedSaveId()
  if not (v and id) then return end
  local SaveData = require("src.core.SaveData")
  local cartId = self:activeCart(v)
  local current = self:currentSave(v)
  local label = current and ((current.label or current.name or id) .. " copy") or nil
  local newId, err
  if cartId then newId, err = SaveData.duplicateCartSlot(cartId, id, label)
  else newId, err = SaveData.duplicateSlot(v, id, label) end
  if not newId then return self:say("Could not copy the save: " .. tostring(err), "error") end
  self.slots[self:scopeKey(v)] = nil
  self.selectedSlot[self:scopeKey(v)] = newId
  self:say("Save copied.", "info")
end

-- Android and iOS keep the export in the app's own folder, out of the
-- player's reach: stage it as pending_export.sav and let the system's save
-- dialog (love.system.createFile) copy it where they choose.  The host
-- writes export_done.flag when it has (GameActivity.java,
-- GRPickerBridge.swift).
function Launcher:shareExport(path)
  local sys, lfs = love and love.system, love and love.filesystem
  if not (sys and type(sys.createFile) == "function" and lfs) then return false end
  local rel = tostring(path):match("(exports/.*)$")
  local bytes = rel and lfs.read(rel)
  if not bytes then return false end
  pcall(lfs.remove, "export_done.flag")
  if not lfs.write("pending_export.sav", bytes) then return false end
  local okC, started = pcall(sys.createFile, rel:match("[^/]+$"))
  if not okC or started == false then
    pcall(lfs.remove, "pending_export.sav")
    return false
  end
  self.pendingExport = true
  self:say("Choose where to save the file.", "info")
  return true
end

function Launcher:pollExport()
  if not self.pendingExport then return end
  local lfs = love.filesystem
  if lfs.getInfo("export_done.flag") then
    self.pendingExport = nil
    pcall(lfs.remove, "export_done.flag")
    pcall(lfs.remove, "pending_export.sav")
    self:say("Save exported.", "info")
  end
end

-- Delete takes two presses: the first arms it, any other action disarms.
function Launcher:deleteSave()
  local v, id = self.selected, self:selectedSaveId()
  if not (v and id) then return end
  if self.armedDelete ~= v .. ":" .. id then
    self.armedDelete = v .. ":" .. id
    return self:say("Press Delete again to remove this save for good.", "error")
  end
  self.armedDelete = nil
  local key = self:scopeKey(v)
  local ok, err = self:store(v).delete(id)
  self.slots[key], self.selectedSlot[key] = nil, nil
  if ok == false then return self:say("Could not delete: " .. tostring(err), "error") end
  self:say("Save deleted.", "info")
end

function Launcher:renameSave(name)
  local v, id = self.selected, self:selectedSaveId()
  self.renaming = nil
  if not (v and id) then return end
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local ok, err = self:store(v).rename(id, name ~= "" and name or nil)
  self.slots[self:scopeKey(v)] = nil
  if ok == false then return self:say("Could not rename: " .. tostring(err), "error") end
end

-- --------------------------------------------------------------- settings

-- The options this launcher edits, read and written through SaveData so the
-- game sees exactly what was chosen.
-- Read fresh every time (SaveData caches the file by revision): SaveData's
-- own writes -- a new save slot, a mod switch -- replace its table, and
-- writing back a copy held from before would undo them.
function Launcher:options()
  local ok, SaveData = pcall(require, "src.core.SaveData")
  local okL, opts = false, nil
  if ok then okL, opts = pcall(SaveData.loadOptions) end
  if okL and type(opts) == "table" then return opts end
  self.fallbackOpts = self.fallbackOpts or {}
  return self.fallbackOpts
end

-- The launcher's volumes are for every game: Gen 1 and Gen 3 read the flat
-- keys, Gen 2 its own block (src/core/gen2/Save.lua OPTIONS_KEY).
local ALL_GAMES_KEYS = { musicVol = true, sfxVol = true }

function Launcher:setOption(key, value)
  local opts = self:options()
  opts[key] = value
  if key == "reduceMotion" then self:applyMotion(value) end
  if ALL_GAMES_KEYS[key] then
    local okG, Gen2Save = pcall(require, "src.core.gen2.Save")
    local block = okG and Gen2Save.OPTIONS_KEY or "gold"
    opts[block] = type(opts[block]) == "table" and opts[block] or {}
    opts[block][key] = value
  end
  local ok, SaveData = pcall(require, "src.core.SaveData")
  if ok then pcall(SaveData.saveOptions, opts) end
  if key == "videoMode" then
    local okV, VideoMode = pcall(require, "src.core.VideoMode")
    if okV then VideoMode.apply(value) end
  end
end

-- Reduce motion: no page slide here, no screen transitions in the kit.
function Launcher:applyMotion(reduce)
  self.reduceMotion = reduce == true
  local okT, Transition = pcall(require, "src.ui.kit.Transition")
  if okT then Transition.reduceMotion = self.reduceMotion end
end

-- Open a prefilled issue form (src/core/IssueReport.lua) with this build,
-- platform and the mods in use.
function Launcher:reportProblem()
  local ok, done, _, note = pcall(require("src.core.IssueReport").open, self:options())
  if not ok then return self:say("Could not open the report: " .. tostring(done), "error") end
  if not done then return self:say("Could not open the report form.", "error") end
  self:say(note or "The report form opened in your browser.", "info")
end

-- Save the online relay address; an empty one goes back to the default.
function Launcher:setRelay(text)
  local Net = require("src.link.Net")
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    self:setOption("relayAddress", nil)
    self.relayDraft = ""
    return self:say("Online play uses the default relay, " .. Net.DEFAULT_RELAY_ADDRESS .. ".", "info")
  end
  local address, why = Net.normalizeRelayAddress(text)
  if not address then return self:say("That relay address won't work: " .. tostring(why), "error") end
  self:setOption("relayAddress", address)
  self.relayDraft = address
  self:say("Online play will connect to " .. address .. ".", "info")
end

-- ---------------------------------------------------------------- updates

-- What the update chip says and does right now, or nil when there is nothing
-- to act on.  Returns label, action (a function or nil), enabled.
function Launcher:updateChip()
  local okC, Check = pcall(require, "src.update.Check")
  if not okC then return nil end
  local okS, st = pcall(Check.state)
  if not okS or type(st) ~= "table" then return nil end
  local status = st.status
  if status == "available" then
    return "Update to " .. tostring(st.latest or "new version"),
      function() Check.download() end, true
  elseif status == "downloading" or status == "full_downloading" then
    return ("Downloading %d%%"):format(math.floor((st.progress or 0) * 100)), nil, false
  elseif status == "ready" then
    -- Boot.lua mounts the downloaded payload on the next start; HostShell
    -- owns restarting (the browser and some Android hosts cannot)
    return "Restart to update", function()
      local HostShell = require("src.core.HostShell")
      if HostShell.canRestart() then return HostShell.restart() end
      self:say("Close and reopen the game to finish updating.", "info")
    end, true
  elseif status == "needs_full" or status == "full_ready" then
    local okA, action = pcall(Check.fullUpdateAction)
    if okA and action then
      return action.label, function() Check.performFullUpdate() end, true
    end
  end
  return nil
end

function Launcher:quit()
  local okP, Platform = pcall(require, "src.core.Platform")
  if okP and Platform.systemQuit and Platform.systemQuit() then return end
  love.event.quit()
end

-- ------------------------------------------------------------- host hooks

function Launcher:update(dt)
  self:stickRepeat(dt or 0)
  pcall(self.pollExport, self)
  if self.assetJob then self:stepImporter(0.008) end
  local okP, errP = pcall(self.pollHostPick, self)
  if not okP then
    self.pendingPick = nil
    self:say(tostring(errP), "error")
  end
  if self.page == "box" then
    local ok, err = pcall(require("src.import.BoxPanel").update, self, dt)
    if not ok then self:say(tostring(err), "error") end
  end
  -- device save sync keeps running while the launcher is up
  local eng = require("src.launcher.SyncPage").pump(dt)
  if eng then
    local okN, notice = pcall(eng.takeNotice, eng)
    if okN and notice then self:say(notice, "info") end
    if eng.phase ~= self.lastSyncPhase then
      if self.lastSyncPhase and eng.phase == "idle" then self.slots = {} end
      self.lastSyncPhase = eng.phase
    end
  end
  if self.online then
    local ok, err = pcall(self.online.update, self.online, dt)
    if not ok then self:say(tostring(err), "error") end
  end
  if self.modsPage then
    local ok, err = pcall(self.modsPage.update, self.modsPage, dt)
    if not ok then self:say(tostring(err), "error") end
  end
  if self.job then
    local state = self.job:step(0.008)
    if state == "done" then
      local version = self.job.version
      self.job = nil
      self:refresh()
      self:selectGame(version)
      self:say(GameVersion.info(version).displayName .. " is ready to play.", "info")
      -- more games waiting on an automatic re-import go next
      if self:options().autoReimport and self:autoReimport() then return end
      -- scripted runs (main.lua: POKEPORT_IMPORT_ROM / IMPORT_ONLY) go on
      -- from here on their own
      if self.opts.onImported then return self.opts.onImported(version) end
    elseif state == "error" then
      self:say("Import failed: " .. tostring(self.job.error), "error")
      self.job = nil
      self:refresh()
    end
  end
  if #self.actions > 0 then
    local pending = self.actions
    self.actions = {}
    for _, fn in ipairs(pending) do
      local ok, err = pcall(fn)
      if not ok then self:say(tostring(err), "error") end
      if self.launched then return end
    end
  end
end

-- On the Box page the showcase editor owns drags that start on its stage.
local function showcase(self, method, ...)
  if self.page ~= "box" then return false end
  local ok, took = pcall(require("src.import.ShowcaseEditor")[method], self, ...)
  return ok and took and true or false
end

-- Escape / B: leave the current page (Mods and Carts lead back to the game).
-- Escape / B: the same page the on-screen Back button goes to.
local PARENT = { sync = "settings" }
for k, v in pairs(require("src.launcher.ModsPage").PARENT) do PARENT[k] = v end
for k, v in pairs(require("src.launcher.CartsPage").PARENT) do PARENT[k] = v end

function Launcher:back()
  if self.page == "box" then return self:closeBox() end
  if self.page == "notes" then self.page = self.notesFrom return end
  self.page = PARENT[self.page]
end

-- --------------------------------------------------------------- online

function Launcher:openOnline()
  if self.page == "box" then self:closeBox() end
  self.online = self.online or require("src.launcher.OnlinePage").new(self)
  self.page = "online"
end

-- The relay started a battle (src/launcher/OnlinePage.lua): boot the game
-- straight into it.
function Launcher:launchArena(version, spec)
  if self:importing() then return self:say("Wait for the import to finish.", "error") end
  pcall(function() require("src.import.BoxHost").use(nil) end)
  if self.online then self.online:close() end
  self.launched = version
  if self.onLaunch then self.onLaunch(version, nil, { arena = spec }) end
end

function Launcher:mousepressed(x, y, button)
  Kit.pointerUsed()
  if button == 1 and showcase(self, "pointerPressed", "mouse", x, y) then return end
  if button == 1 or button == nil then self.pressAt = { x = x, y = y } end
end

function Launcher:mousereleased(x, y, button)
  if button == 1 and showcase(self, "pointerReleased", "mouse") then
    self.pressAt = nil
    return
  end
  if (button == 1 or button == nil) and self.pressAt then
    self.click = { x = x, y = y }
    self.pressAt = nil
  end
end

function Launcher:mousemoved(x, y) showcase(self, "pointerMoved", "mouse", x, y) end
-- A finger drags lists (Kit.dragBegin/dragAdd feed every scroll area); one
-- that moved further than a tap is a drag, not a press.
local DRAG_SLOP = 12

function Launcher:touchpressed(id, x, y)
  Kit.pointerUsed()
  if showcase(self, "pointerPressed", id, x, y) then return end
  self.pressAt = { x = x, y = y }
  self.touchY = y
  Kit.dragBegin(x, y)
end
function Launcher:touchmoved(id, x, y)
  if showcase(self, "pointerMoved", id, x, y) then return end
  if self.touchY then
    Kit.dragAdd(self.touchY - y)  -- finger up scrolls the content down
    self.touchY = y
  end
  local p = self.pressAt
  if p and (math.abs(x - p.x) > DRAG_SLOP or math.abs(y - p.y) > DRAG_SLOP) then
    self.pressAt = nil
  end
end
function Launcher:touchreleased(id, x, y)
  self.touchY = nil
  if showcase(self, "pointerReleased", id) then
    self.pressAt = nil
    Kit.dragEnd()
    return
  end
  if self.pressAt then self.click = { x = x, y = y } end
  self.pressAt = nil
  -- the drag ends after the frame that reads it
  self:queue(function() Kit.dragEnd() end, true)
end

function Launcher:wheelmoved(_, dy) self.wheel = (self.wheel or 0) + dy end

function Launcher:keypressed(key)
  if Kit.FileBrowser.active then return Kit.keypressed(key) end
  if self._boxPrompt then
    if key == "escape" then
      self:queue(function() require("src.import.BoxPrompt").close(self, false) end)
    elseif key == "return" or key == "kpenter" then
      self:queue(function() require("src.import.BoxPrompt").close(self, true) end)
    else
      Kit.keypressed(key)
    end
    return true
  end
  if self._boxPopup and require("src.import.BoxUI").keypressed(self, key) then return true end
  if self.page == "box" and require("src.import.BoxPanel").keypressed(self, key) then return true end
  if key == "escape" and self.page == "box" then
    self:queue(function() self:closeBox() end)
    return true
  end
  local isDown = love.keyboard and love.keyboard.isDown
  local ctrl = isDown and (isDown("lctrl") or isDown("rctrl") or isDown("lgui") or isDown("rgui"))
  local shiftDown = isDown and (isDown("lshift") or isDown("rshift"))
  -- Ctrl+Tab / Ctrl+PgDn: next section; with Shift / PgUp: the one before
  if ctrl and (key == "tab" or key == "pagedown" or key == "pageup") then
    self:cycleSection((key == "pageup" or (key == "tab" and shiftDown)) and -1 or 1)
    return true
  end
  if key == "f11" then
    local okW, Window = pcall(require, "src.import.LauncherWindow")
    if okW then pcall(Window.toggle) end
    return true
  end
  if key == "tab" and not Kit.focus then
    local shift = shiftDown
    Kit.navigate(shift and "up" or "down")
    return true
  end
  if Kit.keypressed(key) then return true end
  if key == "escape" and self.page and not self.renaming then
    self:queue(function() self:back() end)
    return true
  end
  if key == "escape" and self.renaming then
    self:queue(function() self.renaming = nil end)
    return true
  end
  return false
end

local POPUP_KEYS = { dpup = "up", dpdown = "down", a = "return", b = "escape" }

function Launcher:gamepadpressed(_, button)
  -- a Box popup or rename prompt owns the pad while it is up
  if self._boxPrompt and button == "b" then return self:keypressed("escape") end
  if self._boxPopup and POPUP_KEYS[button] then return self:keypressed(POPUP_KEYS[button]) end
  if button == "b" and not Kit.focus then
    if self._boxPopup or self._boxPrompt or self.page then return self:keypressed("escape") end
  end
  if Kit.FileBrowser.active then return Kit.gamepadpressed(button) end
  -- shoulders step through the sections, as tabs do on a console
  if not (self._boxPopup or self._boxPrompt) and (button == "leftshoulder" or button == "rightshoulder") then
    self:cycleSection(button == "leftshoulder" and -1 or 1)
    return true
  end
  if Kit.gamepadpressed(button) then return true end
  if button == "start" then
    -- Start plays: Continue on the game screen, else whatever is focused
    if not self.page and self.selected and self.ready[self.selected]
        and #self:slotsFor(self.selected) > 0 then
      local v = self.selected
      self:queue(function() self:play(v) end)
    else
      Kit.activateFocused()
    end
    return true
  end
  return false
end

function Launcher:cycleSection(dir)
  local at = 1
  for i, it in ipairs(Launcher.NAV) do if it.id == self:section() then at = i end end
  local nextId = Launcher.NAV[(at - 1 + dir) % #Launcher.NAV + 1].id
  self:queue(function() self:goSection(nextId) end)
end

-- The left stick moves the ring like the d-pad: one step when it is pushed
-- past half way, then repeats while held (update).
local STICK_ON, STICK_OFF = 0.6, 0.3
function Launcher:gamepadaxis(_, axis, value)
  if axis ~= "leftx" and axis ~= "lefty" then return false end
  self.stick = self.stick or { leftx = 0, lefty = 0 }
  self.stick[axis] = value
  local dir
  if math.abs(self.stick.lefty) >= STICK_ON then dir = self.stick.lefty > 0 and "down" or "up"
  elseif math.abs(self.stick.leftx) >= STICK_ON then dir = self.stick.leftx > 0 and "right" or "left" end
  if dir and dir ~= self.stickDir then
    self.stickDir, self.stickHeld = dir, 0
    if Kit.FileBrowser.active then
      Kit.gamepadpressed("dp" .. dir)
    else
      Kit.navigate(dir)
    end
  elseif not dir and math.abs(self.stick.lefty) < STICK_OFF and math.abs(self.stick.leftx) < STICK_OFF then
    self.stickDir = nil
  end
  return true
end

function Launcher:stickRepeat(dt)
  if not self.stickDir then return end
  self.stickHeld = (self.stickHeld or 0) + dt
  if self.stickHeld >= 0.4 then
    self.stickHeld = 0.4 - 0.12
    if Kit.FileBrowser.active then Kit.gamepadpressed("dp" .. self.stickDir)
    else Kit.navigate(self.stickDir) end
  end
end

function Launcher:gamepadreleased() end
function Launcher:joystickpressed() end
function Launcher:joystickreleased() end
function Launcher:joystickaxis() end
function Launcher:joystickhat(_, _, direction)
  local map = { u = "up", d = "down", l = "left", r = "right" }
  if map[direction] then Kit.navigate(map[direction]) end
end
function Launcher:textinput(text)
  if self.page == "box" and not self._boxPrompt
      and require("src.import.BoxPanel").textinput(self, text) then
    return true
  end
  return Kit.textinput(text)
end

local SAVE_EXTS = { sav = true, srm = true, sa1 = true, dsv = true, sgm = true }

local function isSaveName(name)
  local ext = tostring(name or ""):lower():match("%.([%w]+)$")
  return ext ~= nil and SAVE_EXTS[ext] == true
end
Launcher.isSaveName = isSaveName

function Launcher:filedropped(file)
  self:queue(function() self:handleDrop(file) end)
end

function Launcher:handleDrop(file)
  local fname = file.getFilename and file:getFilename() or ""
  local lower = fname:lower()
  if self.page == "box" and (lower:match("%.gci$") or lower:match("%.sav$")) then
    local ok, data = pcall(function()
      file:open("r")
      local bytes = file:read()
      file:close()
      return bytes
    end)
    return self:importBox(ok and data or nil, not ok and tostring(data) or nil)
  end
  if isSaveName(fname) then
    return self:importSave(file, fname:match("[^/\\]+$") or fname)
  end
  local isCart = fname:lower():match("%.g1rcart$") ~= nil
  -- a .zip dropped on the Mods page is a mod; anywhere else, a zipped ROM
  local asMod = self.page == "mods" and fname:lower():match("%.zip$") ~= nil
  local ok, data = pcall(function()
    file:open("r")
    local bytes = file:read()
    file:close()
    return bytes
  end)
  local name = file.getFilename and file:getFilename() or "dropped file"
  if not ok or type(data) ~= "string" then
    return self:say("Could not read the dropped file.", "error")
  end
  if asMod then return self:installMod(data, name:match("[^/\\]+$") or name) end
  if isCart then return self:installCart(data, name:match("[^/\\]+$") or name) end
  if name:match("^/") or name:match("^%a:[/\\]") then self:rememberRomSource(name) end
  self:importData(data, name:match("[^/\\]+$") or name)
end

-- Where a ROM was picked or dropped from, kept once it verifies (above) so
-- an update that needs a fresh import can read the same file again.  Only
-- real paths on a desktop: a phone's picked file is a temporary copy.
function Launcher:rememberRomSource(path)
  local okP, Platform = pcall(require, "src.core.Platform")
  if okP and Platform.canSpawnProcess() and type(path) == "string" then
    self.pickedRomPath = path
  end
end

-- The remembered file for a game, when it is still there.
function Launcher:romSource(version)
  local sources = self:options().romSources
  local path = type(sources) == "table" and sources[version]
  if type(path) ~= "string" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  f:close()
  return path
end

function Launcher:reimport(version)
  local path = self:romSource(version)
  if not path then return self:pickRom() end
  self.pickedRomPath = path
  self:startPath(path)
end

-- Settings > Import again after updates: the first game that needs it and
-- still has its file is imported again.  Returns true when one started.
function Launcher:autoReimport()
  if self:importing() then return false end
  for _, v in ipairs(self.games) do
    if self.stale and self.stale[v] and self:romSource(v) then
      self:reimport(v)
      return self:importing()
    end
  end
  return false
end

-- Forget every remembered ROM location (Settings).
function Launcher:forgetRomSources()
  self:setOption("romSources", {})
  self:say("PK:GB no longer remembers where your ROMs are.", "info")
end

-- How else a ROM can arrive, in this platform's terms.
function Launcher:importHint()
  local Inbox = require("src.launcher.Inbox")
  local okP, Platform = pcall(require, "src.core.Platform")
  local P = okP and Platform.detect() or {}
  if Inbox.enabled() then
    local how = P.inboxTransfer == "mtp" and "Connect by USB and copy it into "
      or P.inboxTransfer == "ftp" and "Copy it over FTP into "
      or "Or copy it into "
    return how .. Inbox.location() .. ", then choose Settings > Scan again."
  end
  if P.mobile then return "Choose the file from your device's storage or a cloud drive." end
  if P.web then return "The file stays in your browser; it is never uploaded." end
  return "Or drop the .gb / .gbc / .gba file onto this window."
end

-- An import started from a command line path.
function Launcher:startPath(path)
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  local data = ok and FilePicker.read(path)
  if not data then return self:say("Could not read " .. tostring(path), "error") end
  self:importData(data, ok and FilePicker.basename(path) or path)
end

-- Hooks main.lua calls on any launcher when another screen hands control
-- back (save editor, skin studio) or saves changed underneath it.
function Launcher:focus()
  self:refresh()
  if require("src.launcher.Inbox").enabled() then self:queue(function() self:scanInbox() end) end
  self.modRows, self.cartRows, self.cartPlans = nil, nil, nil
end
function Launcher:savesChanged() self.slots = {} end
function Launcher:resumeAfterOverlay() self:refresh() end
function Launcher:prepareOverlayHandoff() end
function Launcher:ignoreReturningPointer() self.pressAt, self.click = nil, nil end
-- main.lua asks a launcher to update mods before a shortcut boots
-- (src/launcher/ModsPage.lua); done(result) runs once they are.
function Launcher:autoUpdateAll(done, opts) return self:modsUi():autoUpdateAll(done, opts) end

-- ------------------------------------------------------------------- draw

local function statusText(self, version)
  if self.job and self.job.version == version then return "Importing", PAL.yellow end
  if self.ready[version] then return "Ready", PAL.green end
  if self.stale and self.stale[version] then return "Update needed", PAL.yellow end
  return "Not imported", PAL.muted
end

-- The save a game opens on: the chosen one, else the first.
function Launcher:currentSave(version)
  if not self.ready[version] then return nil end
  local slots = self:slotsFor(version)
  local key = self:scopeKey(version)
  for _, slot in ipairs(slots) do
    if slot.id == self.selectedSlot[key] then return slot end
  end
  return slots[1]
end

-- One line about a save: trainer and play time.
local function saveLine(slot)
  if not slot then return nil end
  local parts = { tostring(slot.label or slot.name or slot.id) }
  local meta = slot.meta
  if meta and meta.timeText then parts[#parts + 1] = tostring(meta.timeText) end
  return table.concat(parts, "  -  ")
end

-- The game list, grouped by generation: a colour stripe per game, and for
-- an imported one its trainer and play time; the rest offer Import.
-- A list row's name over its detail line, centred as a pair in the row.
local function twoLines(title, detail, x, y, h, w, titleInk, detailInk, s)
  local th, dh = Kit.textHeight("button"), Kit.textHeight("micro")
  local top = y + (h - th - dh - Theme.space("xxs", s)) / 2
  Kit.text("button", Kit.ellipsize("button", tostring(title), w), x, top, titleInk)
  Kit.text("micro", Kit.ellipsize("micro", tostring(detail or ""), w), x, top + th + Theme.space("xxs", s),
    detailInk)
end

function Launcher:drawGameList(x, y, w, h, s)
  local rowH = math.max(Kit.tapMin(), math.floor(50 * s))
  local gap = Theme.space("xs", s)
  local headH = Kit.textHeight("caption") + Theme.space("m", s)
  -- lay the list out once per frame: headers and rows in order
  local items, gens = {}, {}
  for _, v in ipairs(self.games) do
    local gen = GameVersion.generation(v) or 1
    if not gens[gen] then
      gens[gen] = true
      items[#items + 1] = { header = "GEN " .. gen }
    end
    items[#items + 1] = { version = v }
  end
  local contentH = 0
  for _, it in ipairs(items) do contentH = contentH + (it.header and headH or rowH + gap) end
  local maxAt = Kit.scrollExtent(contentH, h)
  self.listScroll = Kit.scrollInput(self.listScroll, maxAt, x, y, w, h)
  local py = Kit.scrollBegin(x, y, w, h, self.listScroll, maxAt)
  local rw = w - Kit.scrollGutter(s)
  local inset = Theme.space("m", s)
  local shortNames = false
  for i, it in ipairs(items) do
    if it.header then
      Kit.caption(x + Theme.space("xs", s), py + (i > 1 and Theme.space("s", s) or 0), it.header, PAL.caption)
      py = py + headH
    else
      local v = it.version
      local info = GameVersion.info(v)
      local chosen = self.selected == v
      local clicked, ink = Kit.row(x, py, rw, rowH, chosen, "game-" .. v)
      local color = Theme.gameColor(v)
      local ready = self.ready[v]
      local stripe = Theme.space("xs", s)
      Theme.fillRounded(x + Theme.space("s", s), py + Theme.space("s", s), stripe,
        rowH - 2 * Theme.space("s", s), color, ready and 1 or 0.35, stripe / 2)
      local tx = x + Theme.space("s", s) + stripe + inset
      -- right side: Import chip, or an importing note
      local rightW = 0
      local importing = self.job and self.job.version == v
      if importing then
        local note = math.floor((self.job.progress or 0) * 100) .. "%"
        rightW = Kit.textWidth("micro", note) + inset
        Kit.text("micro", note, x + rw - rightW, py + (rowH - Kit.textHeight("micro")) / 2, PAL.yellow)
      elseif not ready then
        -- a game an update left behind says so, and imports from its file
        local stale = self.stale and self.stale[v]
        local chip = stale and "Update" or "Import"
        local cw = Kit.textWidth("micro", "Import") + Theme.BUTTON.labelInset * s + Theme.space("s", s)
        -- a full tap target where the row has room for one
        local ch = math.min(rowH - Theme.space("s", s), math.max(Kit.tapMin(), math.floor(28 * s)))
        rightW = cw + inset
        if Kit.button(x + rw - cw - inset, py + (rowH - ch) / 2, cw, ch, chip,
            { id = "game-import-" .. v, face = "chip", active = chosen,
              color = stale and PAL.yellow or Theme.readable(color, PAL.bg) }) then
          self:queue(function()
            self:selectGame(v)
            self.page = nil
            if stale then self:reimport(v) else self:pickRom() end
          end)
        end
      end
      local nameW = rw - (tx - x) - rightW - inset
      -- "Pokemon Red" when every row fits it, else "Red" on every row: the
      -- part that tells them apart (decided from the frame before)
      local name = info.displayName
      if Kit.textWidth("button", name) > nameW then shortNames = true end
      if self.shortNames then name = info.label or name end
      local line = ready and (saveLine(self:currentSave(v)) or "No saves yet") or nil
      if line then
        local top = py + (rowH - Kit.textHeight("button") - Kit.textHeight("micro")) / 2
        Kit.text("button", Kit.ellipsize("button", name, math.max(0, nameW)), tx, top, ink or PAL.text)
        Kit.text("micro", Kit.ellipsize("micro", line, math.max(0, nameW)), tx,
          top + Kit.textHeight("button"), chosen and (ink or PAL.text) or PAL.muted)
      else
        Kit.text("button", Kit.ellipsize("button", name, math.max(0, nameW)), tx,
          py + (rowH - Kit.textHeight("button")) / 2, ink or (ready and PAL.text or PAL.muted))
      end
      if clicked and not (not ready and Kit.hit(x + rw - rightW, py, rightW, rowH)) then
        self:queue(function()
          self:selectGame(v)
          self.page = nil
          self:say(nil)
        end)
      end
      py = py + rowH + gap
    end
  end
  self.shortNames = shortNames
  Kit.scrollEnd(x, y, w, h, self.listScroll, maxAt)
end

-- The one page header: title, an optional subtitle (wrapped), an optional
-- Back button on the right, and an optional game colour mark.  Returns the
-- y the page's content starts at.
function Launcher:pageHeader(cx, cy, cw, s, o)
  local backW = 0
  if o.back then
    backW = math.max(Kit.tapMin(), Kit.textWidth("small", "Back") + Theme.space("xl", s) + Theme.space("s", s))
    if Kit.button(cx + cw - backW, cy, backW, math.max(Kit.tapMin(), math.floor(32 * s)), "Back",
        { id = o.backId or "page-back", font = "small", icon = "arrow-left", fullLabel = true }) then
      self:queue(o.back)
    end
  end
  local textW = cw - backW - (backW > 0 and Theme.space("m", s) or 0)
  Kit.textBold("title", Kit.ellipsize("title", o.title, textW), cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("title") + Theme.space("xs", s)
  if o.subtitle then
    local tx = cx
    if o.accent then
      local d = Theme.space("s", s)
      Theme.fillRounded(cx, cy + (Kit.textHeight("small") - d) / 2, d, d, o.accent, 1, d / 2)
      tx = cx + d + Theme.space("s", s)
    end
    Kit.textWrapped("small", o.subtitle, tx, cy, textW - (tx - cx), PAL.muted)
    cy = cy + Kit.wrapHeight("small", o.subtitle, textW - (tx - cx))
  end
  return cy + Theme.space("l", s)
end

function Launcher:drawSettings(x, y, w, h, s)
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = self:pageHeader(cx, cy, cw, s, { title = "Settings" })
  local opts = self:options()
  local rowH = math.max(Kit.tapMin(), math.floor(40 * s))
  local stepW = math.max(Kit.tapMin(), math.floor(40 * s))
  local function label(text, ry)
    Kit.text("button", text, cx, ry + (rowH - Kit.textHeight("button")) / 2, PAL.text)
  end
  local function stepper(key, text, lo, hi, ry)
    label(text, ry)
    local value = tonumber(opts[key]) or hi
    local vx = cx + cw - stepW
    if Kit.button(vx, ry, stepW, rowH, "+", { id = key .. "-up", enabled = value < hi }) then
      self:queue(function() self:setOption(key, math.min(hi, value + 1)) end)
    end
    local mid = math.floor(60 * s)
    Kit.textCenter("button", tostring(value), vx - mid, ry
      + (rowH - Kit.textHeight("button")) / 2, mid, PAL.heading)
    if Kit.button(vx - mid - stepW, ry, stepW, rowH, "-",
        { id = key .. "-down", enabled = value > lo }) then
      self:queue(function() self:setOption(key, math.max(lo, value - 1)) end)
    end
  end

  -- on/off rows: the button names the state, a press flips it
  local function toggle(id, text, on, flip, note)
    label(text, cy)
    local tw = math.floor(math.min(cw * 0.5, 300 * s))
    if Kit.button(cx + cw - tw, cy, tw, rowH, on and "On" or "Off",
        { id = id, font = "small", kind = on and "primary" or nil }) then
      self:queue(flip)
    end
    cy = cy + rowH + math.floor(note and 4 or 10) * s
    if note then
      Kit.textWrapped("micro", note, cx, cy, cw, PAL.faint)
      cy = cy + Kit.wrapHeight("micro", note, cw) + math.floor(10 * s)
    end
  end
  -- groups, each under a caption
  local function section(text)
    if cy > y + pad + 60 * s then cy = cy + Theme.space("s", s) end
    Kit.caption(cx, cy, text, PAL.caption)
    cy = cy + Kit.textHeight("caption") + Theme.space("s", s)
  end
  section("DISPLAY AND SOUND")
  local okV, VideoMode = pcall(require, "src.core.VideoMode")
  if okV and not VideoMode.fixedDisplay() then
    -- the launcher's own window (src/import/LauncherWindow.lua); each game
    -- keeps its display mode in its OPTIONS menu
    label("Launcher window", cy)
    local okW, Window = pcall(require, "src.import.LauncherWindow")
    local okM, mode = false, nil
    if okW then okM, mode = pcall(Window.mode) end
    local full = okM and mode == "fullscreen"
    local bw = math.floor(math.min(cw * 0.5, 300 * s))
    if Kit.button(cx + cw - bw, cy, bw, rowH, full and "Fullscreen" or "Windowed",
        { id = "video-mode", font = "small", enabled = okW }) then
      self:queue(function()
        local okT, done = pcall(Window.toggle)
        if not (okT and done) then self:say("The window mode could not be changed here.", "error") end
      end)
    end
    cy = cy + rowH + math.floor(10 * s)
  end
  stepper("musicVol", "Music volume", 0, 7, cy)
  cy = cy + rowH + math.floor(10 * s)
  stepper("sfxVol", "Sound volume", 0, 7, cy)
  cy = cy + rowH + math.floor(10 * s)
  toggle("reduce-motion", "Reduce motion", opts.reduceMotion == true, function()
    self:setOption("reduceMotion", self:options().reduceMotion ~= true)
  end)
  section("CONTROLS")
  if self.opts.onOpenSkinStudio then
    label("Controller skin", cy)
    local sw = math.floor(math.min(cw * 0.5, 300 * s))
    if Kit.button(cx + cw - sw, cy, sw, rowH,
        Kit.ellipsize("small", tostring(self:activeSkin() or "Built-in pad"), sw - math.floor(24 * s)),
        { id = "skins", font = "small" }) then
      self:queue(function() self:openStudio(self:activeSkin()) end)
    end
    cy = cy + rowH + math.floor(10 * s)
  end
  if self.opts.onEditTouchControls then
    label("Touch controls", cy)
    local tw = math.floor(math.min(cw * 0.5, 300 * s))
    if Kit.button(cx + cw - tw, cy, tw, rowH, "Arrange", { id = "touch-controls", font = "small" }) then
      self:queue(function() self.opts.onEditTouchControls(self.selected) end)
    end
    cy = cy + rowH + math.floor(10 * s)
  end
  section("ONLINE")
  -- the online relay (src/link/Net.lua): typed here, saved on Save
  label("Online relay", cy)
  local Net = require("src.link.Net")
  local current, source = Net.relaySetting()
  if self.relayDraft == nil then
    self.relayDraft = type(opts.relayAddress) == "string" and opts.relayAddress or ""
  end
  local saveW = math.max(Kit.tapMin(), Kit.textWidth("small", "Save") + math.floor(28 * s))
  local fieldW = math.floor(math.min(cw * 0.5, 300 * s))
  -- too narrow for an address beside its label: the field takes its own line
  if fieldW - saveW < 180 * s then
    cy = cy + rowH
    fieldW = cw
  end
  local relayEnd
  self.relayDraft, relayEnd = Kit.textfield("relay-field", cx + cw - fieldW, cy,
    fieldW - saveW - math.floor(8 * s), rowH, self.relayDraft, Net.DEFAULT_RELAY_ADDRESS)
  if Kit.button(cx + cw - saveW, cy, saveW, rowH, "Save", { id = "relay-save", font = "small" })
      or relayEnd == "submit" then
    local draft = self.relayDraft
    self:queue(function() self:setRelay(draft) end)
  end
  cy = cy + rowH + math.floor(4 * s)
  local why = ({ env = " (POKEPORT_RELAY_ADDR)", launch = " (--relay, this run only)",
    saved = "", default = " (default)" })[source] or ""
  Kit.text("micro", Kit.ellipsize("micro", "Connecting to " .. tostring(current) .. why, cw),
    cx, cy, PAL.faint)
  cy = cy + Kit.textHeight("micro") + math.floor(10 * s)
  local okU, Union = pcall(require, "src.online.union.Setting")
  if okU then
    toggle("union-room", "Union Room", Union.enabledIn(opts), function()
      self:setOption(Union.KEY, not Union.enabledIn(self:options()))
    end, "Red, Blue, Yellow, Gold, Silver and Crystal: the Pokemon Center's upstairs "
      .. "room for online trades and battles.")
  end
  label("Save sync", cy)
  local syncW = math.floor(math.min(cw * 0.5, 300 * s))
  local SyncEngine = package.loaded["src.sync.SyncEngine"]
  local linked = SyncEngine and type(SyncEngine._shared) == "table" and SyncEngine._shared:linked()
  if Kit.button(cx + cw - syncW, cy, syncW, rowH, linked and "Linked - manage" or "Set up",
      { id = "sync", font = "small" }) then
    self:queue(function()
      self.sync = self.sync or require("src.launcher.SyncPage").new(self)
      self.page = "sync"
    end)
  end
  cy = cy + rowH + math.floor(10 * s)
  section("GAMES AND FILES")
  local Inbox = require("src.launcher.Inbox")
  if Inbox.enabled() then
    label("Imports folder", cy)
    local iw = math.floor(math.min(cw * 0.5, 300 * s))
    if Kit.button(cx + cw - iw, cy, iw, rowH, "Scan again", { id = "inbox-scan", font = "small" }) then
      self:queue(function()
        self.inboxTried = {}
        if self:scanInbox() == 0 and not (self.message and self.message.kind == "error") then
          self:say("Nothing new in " .. Inbox.location() .. ".", "info")
        end
      end)
    end
    cy = cy + rowH + math.floor(4 * s)
    Kit.text("micro", Kit.ellipsize("micro", "Copy files into " .. Inbox.location(), cw), cx, cy, PAL.faint)
    cy = cy + Kit.textHeight("micro") + math.floor(10 * s)
  end
  local okPl, Platform = pcall(require, "src.core.Platform")
  if okPl and Platform.canSpawnProcess() then
    toggle("auto-reimport", "Import again after updates", opts.autoReimport == true, function()
      self:setOption("autoReimport", self:options().autoReimport ~= true)
    end, "When an update needs a game imported again, read the same ROM file without asking.")
    local sources = type(opts.romSources) == "table" and next(opts.romSources) ~= nil
    if sources then
      label("Remembered ROM files", cy)
      local fw = math.floor(math.min(cw * 0.5, 300 * s))
      if Kit.button(cx + cw - fw, cy, fw, rowH, "Forget", { id = "forget-roms", font = "small" }) then
        self:queue(function() self:forgetRomSources() end)
      end
      cy = cy + rowH + math.floor(10 * s)
    end
  end
  section("HELP")
  label("Something wrong?", cy)
  local rw = math.floor(math.min(cw * 0.5, 300 * s))
  if Kit.button(cx + cw - rw, cy, rw, rowH, "Report a problem", { id = "report", font = "small" }) then
    self:queue(function() self:reportProblem() end)
  end
  cy = cy + rowH + math.floor(10 * s)
  -- the tab bar has room for four sections only: the rest live here
  if not self.railMode then
    local extras = { { id = "settings-notes", label = "What's new", icon = "sparkles",
      run = function() self.notesFrom, self.page, self.notesScroll = "settings", "notes", 0 end } }
    if self:canQuit() then
      extras[#extras + 1] = { id = "settings-quit", label = "Quit", icon = "x",
        run = function() self:quit() end }
    end
    local gap = Theme.space("m", s)
    local bw2 = math.floor((cw - (#extras - 1) * gap) / #extras)
    for i, e in ipairs(extras) do
      if Kit.button(cx + (i - 1) * (bw2 + gap), cy, bw2, rowH, e.label,
          { id = e.id, icon = e.icon, fullLabel = true }) then
        self:queue(e.run)
      end
    end
    cy = cy + rowH + Theme.space("m", s)
  end
  local more = "More options (colors, zoom, speed, controls) are in the game's own OPTIONS menu."
  Kit.textWrapped("micro", more, cx, cy, cw, PAL.faint)
  cy = cy + Kit.wrapHeight("micro", more, cw) + Theme.space("s", s)
  -- the build, for bug reports
  Kit.text("micro", Kit.ellipsize("micro", Version.NAME .. " " .. tostring(Version.engine), cw), cx, cy, PAL.faint)
  return cy + Kit.textHeight("micro") + pad - y
end

function Launcher:drawNotes(x, y, w, h, s)
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  if not self.notesText then
    local okP, PatchNotes = pcall(require, "src.update.PatchNotes")
    local okC, Check = pcall(require, "src.update.Check")
    local body, ver
    if okP then
      local okB, b, v = pcall(PatchNotes.body, okC and Check or nil)
      if okB then body, ver = b, v end
    end
    self.notesText = body or "Unable to fetch patch notes."
    self.notesVersion = ver
  end
  cy = self:pageHeader(cx, cy, cw, s, { title = "What's new",
    subtitle = self.notesVersion and ("Version " .. tostring(self.notesVersion)) or nil,
    back = function() self.page = self.notesFrom end, backId = "notes-back" })
  local viewH = y + h - pad - cy
  -- wrapped once per width, not per frame
  local wrapW = cw - Kit.scrollGutter(s)
  if self.notesWrapW ~= wrapW or not self.notesLines then
    local lines = {}
    for raw in (self.notesText .. "\n"):gmatch("(.-)\r?\n") do
      local line = raw:gsub("^#+%s*", ""):gsub("%*%*", "")
      for _, wl in ipairs(Kit.wrapLines("small", line, wrapW) or { "" }) do
        lines[#lines + 1] = wl
      end
    end
    self.notesLines, self.notesWrapW = lines, wrapW
  end
  local lines = self.notesLines
  local lh = Kit.textHeight("small") + math.floor(2 * s)
  local maxAt = Kit.scrollExtent(#lines * lh, viewH)
  self.notesScroll = Kit.scrollInput(self.notesScroll or 0, maxAt, cx, cy, cw, viewH)
  local py = Kit.scrollBegin(cx, cy, cw, viewH, self.notesScroll, maxAt)
  local first = math.max(1, math.floor((self.notesScroll or 0) / lh))
  for i = first, math.min(#lines, first + math.ceil(viewH / lh) + 1) do
    Kit.text("small", lines[i], cx, py + (i - 1) * lh, PAL.text)
  end
  Kit.scrollEnd(cx, cy, cw, viewH, self.notesScroll, maxAt, PAL.surface)
end

function Launcher:drawMods(x, y, w, h, s) return self:modsUi():drawMods(x, y, w, h, s) end
function Launcher:drawImporters(x, y, w, h, s) return self:modsUi():drawImporters(x, y, w, h, s) end
function Launcher:drawCarts(x, y, w, h, s) return self:cartsUi():drawCarts(x, y, w, h, s) end

-- The height the game panel needs: banner, the saves caption, one save
-- card and the Continue / New game row.
function Launcher:detailNeed(w, s, compact)
  local pad = Theme.space("l", s) + Theme.space("xxs", s)
  return self:gameBannerHeight(s, compact) + Theme.space("l", s)
    + math.max(Kit.tapMin(), math.floor(30 * s)) + Theme.space("s", s)
    + math.max(Kit.tapMin() + Theme.space("m", s), math.floor(62 * s)) + Theme.space("l", s)
    + math.max(Kit.tapMin(), math.floor(44 * s)) + pad
end

-- Draw a panel that reports the height it used; when that is more than the
-- window gives it, the panel scrolls instead of drawing over its neighbours.
function Launcher:drawFitted(key, x, y, w, h, s, draw)
  self.fit, self.fitScroll = self.fit or {}, self.fitScroll or {}
  local need = self.fit[key]
  if not need or need <= h + 1 then
    self.fitScroll[key] = 0
    self.fit[key] = draw(self, x, y, w, h, s) or h
    return
  end
  local maxAt = need - h
  local at = Kit.scrollInput(math.min(self.fitScroll[key] or 0, maxAt), maxAt, x, y, w, h)
  self.fitScroll[key] = at
  local py = Kit.scrollBegin(x, y, w, h, at, maxAt)
  self.fit[key] = draw(self, x, py, w, need, s) or need
  Kit.scrollEnd(x, y, w, h, at, maxAt, PAL.field)
end

function Launcher:drawDetail(x, y, w, h, s)
  if not self.page then
    -- a short window (a phone on its side) gets the slim banner, so Continue
    -- stays on screen without scrolling
    self.compactBanner = h < self:detailNeed(w, s)
    return self:drawFitted("detail:" .. tostring(self.selected), x, y, w, h, s, self.drawGame)
  end
  return self:drawPage(x, y, w, h, s)
end

function Launcher:drawPage(x, y, w, h, s)
  if self.page == "settings" then
    return self:drawFitted("settings", x, y, w, h, s, self.drawSettings)
  end
  if self.page == "notes" then return self:drawNotes(x, y, w, h, s) end
  if self.page == "sync" and self.sync then
    return self:drawFitted("sync", x, y, w, h, s, function(l, ...) return l.sync:draw(...) end)
  end
  if self.page and require("src.launcher.ModsPage").PAGES[self.page] then
    return self:modsUi():draw(x, y, w, h, s)
  end
  if self.page and require("src.launcher.CartsPage").PAGES[self.page] then
    return self:cartsUi():draw(x, y, w, h, s)
  end
  return self:drawGame(x, y, w, h, s)
end

-- The chosen game: import, or its saves with Continue / New game.  Returns
-- the height it needs (drawFitted scrolls it on a short window).
-- A cartridge drawn in code, w wide and tinted by the game's colour: a
-- Game Boy cart (portrait, the corner notch) or a Game Boy Advance one
-- (landscape).  No image assets.
local function drawCartridge(x, y, w, h, color, gba, s)
  local G = love.graphics
  local r = math.max(2, math.floor(4 * s))
  local shell = { color[1] * 0.55, color[2] * 0.55, color[3] * 0.55 }
  if gba then
    Theme.fillRounded(x, y, w, h, shell, 1, r)
    local lw, lh = w * 0.62, h * 0.56
    Theme.fillRounded(x + (w - lw) / 2, y + h * 0.12, lw, lh, color, 1, r)
    for i = 0, 2 do
      Theme.fill(x + w * 0.2 + i * w * 0.24, y + h * 0.82, w * 0.12, math.max(1, 2 * s), PAL.bg, 0.6)
    end
    return
  end
  Theme.fillRounded(x, y, w, h, shell, 1, r)
  -- the cut corner, top right
  if G then
    Theme.col(PAL.surface, 1)
    local c = w * 0.22
    G.polygon("fill", x + w - c, y, x + w + 1, y, x + w + 1, y + c)
  end
  for i = 0, 3 do
    Theme.fill(x + w * 0.14, y + h * 0.06 + i * math.max(2, 3 * s), w * 0.6, math.max(1, s), PAL.bg, 0.35)
  end
  local lw, lh = w * 0.74, h * 0.48
  Theme.fillRounded(x + (w - lw) / 2, y + h * 0.26, lw, lh, color, 1, r)
end
Launcher.drawCartridge = drawCartridge

-- Badge dots: earned ones filled in the game's colour.
local function drawBadges(x, y, earned, total, color, s)
  local d = math.max(4, math.floor(6 * s))
  local g = math.max(2, math.floor(3 * s))
  local perRow = 8
  for i = 1, total do
    local row, col = math.floor((i - 1) / perRow), (i - 1) % perRow
    local dx, dy = x + col * (d + g), y + row * (d + g)
    if i <= earned then
      Theme.fillRounded(dx, dy, d, d, color, 1, d / 2)
    else
      Theme.strokeRounded(dx, dy, d, d, PAL.line, 0.6, 1, d / 2)
    end
  end
  local rows = math.ceil(total / perRow)
  return perRow * (d + g) - g, rows * (d + g) - g
end

-- The banner atop the game panel: colour wash, cartridge, title, status.
-- Returns its height.
function Launcher:gameBannerHeight(s, compact)
  if compact then
    return math.max(Kit.tapMin() + Theme.space("m", s) * 2, Kit.textHeight("button") + Kit.textHeight("small")
      + Theme.space("m", s) * 2)
  end
  return math.max(math.floor(92 * s), Kit.textHeight("title") + Kit.textHeight("small")
    + Theme.space("xl", s) * 2)
end

function Launcher:drawGame(x, y, w, h, s)
  local v = self.selected
  if not v then return end
  local info = GameVersion.info(v)
  local color = Theme.gameColor(v)
  local pad = Theme.space("l", s) + Theme.space("xxs", s)
  Kit.card(x, y, w, h)
  local ready = self.ready[v]
  local importing = self.job and self.job.version == v
  -- an open save menu covers what is drawn under it (last frame's rect: the
  -- menu itself draws last), so one press never lands on both
  local r = self.saveMenu and self.saveMenuRect
  if r then Kit.occlude(r[1], r[2], r[3], r[4]) else self.saveMenuRect = nil end
  local gr = self.gameMenu and self.gameMenuRect
  if gr then Kit.occlude(gr[1], gr[2], gr[3], gr[4]) else self.gameMenuRect = nil end

  -- banner
  local compact = self.compactBanner
  local bannerH = self:gameBannerHeight(s, compact)
  local titleFont = compact and "button" or "title"
  Theme.fillRounded(x + 1, y + 1, w - 2, bannerH, color, ready and 0.16 or 0.08, Theme.cardRadius())
  Theme.fill(x + 1, y + bannerH - 1, w - 2, 1, color, 0.35)
  local cartH = bannerH - Theme.space("xl", s)
  local gba = GameVersion.generation(v) == 3
  local cartW = gba and math.floor(cartH * 1.45) or math.floor(cartH * 0.82)
  if w < 360 * s then cartW, cartH = math.floor(cartW * 0.75), math.floor(cartH * 0.75) end
  local tx = x + pad + cartW + Theme.space("l", s)
  local cx, cw = x + pad, w - 2 * pad
  local slots = ready and self:slotsFor(v) or {}
  local scope = self:scopeKey(v)
  local cartId, cartRow = self:activeCart(v)
  local problem = ready and self:cartProblem(v) or nil

  -- Carts / Mods on the banner's right
  local rightW = 0
  local gameMenuAt
  if ready and not importing then
    local mh = math.max(Kit.tapMin(), math.floor(32 * s))
    local mw = math.max(Kit.tapMin(), Kit.textWidth("small", "Mods") + Theme.space("xl", s) + Theme.space("s", s))
    local kw = math.max(Kit.tapMin(), Kit.textWidth("small", "Carts") + Theme.space("xl", s) + Theme.space("s", s))
    local by = compact and y + (bannerH - mh) / 2 or y + Theme.space("m", s)
    if Kit.button(x + w - pad - mw, by, mw, mh, "Mods", { id = "mods", font = "small" }) then
      self:queue(function() self.page = "mods"; self.modScroll = 0 end)
    end
    if Kit.button(x + w - pad - mw - Theme.space("s", s) - kw, by, kw, mh, "Carts",
        { id = "carts", font = "small", active = cartId ~= nil }) then
      self:queue(function() self.page = "carts"; self.cartScroll = 0 end)
    end
    rightW = mw + kw + Theme.space("s", s) + Theme.space("m", s)
    -- "..." : the game's own, rarer actions
    local gx = x + w - pad - mw - Theme.space("s", s) - kw - Theme.space("s", s) - mh
    if Kit.button(gx, by, mh, mh, "", { id = "banner-menu", icon = "ellipsis", face = "bare", ring = false,
        iconInk = PAL.text }) then
      self:queue(function() self.gameMenu = not self.gameMenu end)
    end
    if self.gameMenu then gameMenuAt = { x = gx + mh, y = by + mh } end
    rightW = rightW + mh + Theme.space("s", s)
  end
  -- the name matters more than the art: a banner too narrow for both
  -- (a GBA cartridge on a phone) drops the cartridge
  local betaW = info.beta and Kit.textWidth("micro", "BETA") + Theme.space("m", s) or 0
  local betaGap = info.beta and Theme.space("s", s) or 0
  local wantW = Kit.textWidth(titleFont, info.label or info.displayName) + betaW + betaGap
  if x + w - pad - rightW - tx < wantW then
    tx = x + pad
  else
    drawCartridge(x + pad, y + (bannerH - cartH) / 2, cartW, cartH, color, gba, s)
  end
  local titleW = x + w - pad - rightW - tx
  -- still too narrow: one size down before the name is cut
  if titleFont == "title" and Kit.textWidth(titleFont, info.label or info.displayName) + betaW + betaGap > titleW then
    titleFont = "stat"
  end
  local ty = y + (bannerH - Kit.textHeight(titleFont) - Kit.textHeight("small") - Theme.space("xs", s)) / 2
  local title = info.displayName
  -- a game still in beta says so beside its name
  local nameW = math.max(0, titleW - betaW - betaGap)
  if Kit.textWidth(titleFont, title) > nameW then title = info.label or title end
  local drawnW = Kit.textBold(titleFont, Kit.ellipsize(titleFont, title, nameW), tx, ty, PAL.heading) or 0
  if info.beta and nameW > 0 then
    local bh = Kit.textHeight("micro") + Theme.space("xs", s)
    Kit.tag(tx + drawnW + betaGap, ty + (Kit.textHeight(titleFont) - bh) / 2, betaW, bh, "BETA",
      PAL.yellow, { fill = true, bold = true })
  end
  local status, scolor = statusText(self, v)
  if cartRow then
    status = "Playing as " .. tostring(cartRow.title or cartId)
      .. (problem and (" - " .. problem) or "")
    scolor = problem and PAL.red or PAL.blue
  end
  -- beside Carts / Mods when the banner is slim, under them otherwise
  Kit.text("small", Kit.ellipsize("small", status, math.max(0, (compact and titleW or x + w - pad - tx))),
    tx, ty + Kit.textHeight(titleFont) + Theme.space("xs", s), scolor)

  local cy = y + bannerH + Theme.space("l", s)
  local btnH = math.max(Kit.tapMin(), math.floor(44 * s))

  if importing then
    Kit.text("small", self.job.stage or "Importing", cx, cy, PAL.text)
    local pct = math.floor((self.job.progress or 0) * 100) .. "%"
    Kit.text("small", pct, cx + cw - Kit.textWidth("small", pct), cy, PAL.muted)
    cy = cy + Kit.textHeight("small") + Theme.space("s", s)
    Theme.meter(cx, cy, cw, math.floor(10 * s), self.job.progress or 0, color)
    return cy + math.floor(10 * s) + pad - y
  end

  if not ready then
    local stale = self.stale and self.stale[v]
    local help = stale
      and ("This game was imported by an older version of PK:GB and has to be imported again. "
        .. "Your saves are kept.")
      or ("Import your own " .. info.displayName .. " ROM to play. "
        .. "It is checked against the original release before anything is "
        .. "written, read once, and never copied.")
    Kit.textWrapped("small", help, cx, cy, cw, stale and PAL.text or PAL.muted)
    cy = cy + Kit.wrapHeight("small", help, cw) + Theme.space("m", s)
    local source = self:romSource(v)
    local bw = math.min(cw, math.floor(260 * s))
    if source then
      -- the file it came from last time is still there: one press
      if Kit.button(cx, cy, bw, btnH, "Import again",
          { id = "reimport", kind = "accent", icon = "refresh-cw", fullLabel = true }) then
        self:queue(function() self:reimport(v) end)
      end
      if cw >= 2 * bw + Theme.space("m", s) then
        if Kit.button(cx + bw + Theme.space("m", s), cy, bw, btnH, "Choose another file",
            { id = "import", icon = "folder-open", fullLabel = true }) then
          self:queue(function() self:pickRom() end)
        end
      else
        cy = cy + btnH + Theme.space("s", s)
        if Kit.button(cx, cy, bw, btnH, "Choose another file",
            { id = "import", icon = "folder-open", fullLabel = true }) then
          self:queue(function() self:pickRom() end)
        end
      end
      cy = cy + btnH + Theme.space("s", s)
      Kit.text("micro", Kit.ellipsize("micro", "From " .. source, cw), cx, cy, PAL.faint)
      cy = cy + Kit.textHeight("micro") + Theme.space("xs", s)
    else
      if Kit.button(cx, cy, bw, btnH, "Import ROM",
          { id = "import", kind = "accent", icon = "download", fullLabel = true }) then
        self:queue(function() self:pickRom() end)
      end
      cy = cy + btnH + Theme.space("s", s)
    end
    Kit.textWrapped("micro", self:importHint(), cx, cy, cw, PAL.faint)
    cy = cy + Kit.wrapHeight("micro", self:importHint(), cw) + Theme.space("m", s)
    -- which dumps are accepted (each is checked by SHA-1)
    local revs = {}
    for _, r in ipairs(info.revisions or {}) do revs[#revs + 1] = r.label end
    if #revs > 0 then
      local line = "Accepted: the original " .. tostring(info.label or info.displayName)
        .. " release, version " .. table.concat(revs, " or ") .. "."
      Kit.textWrapped("micro", line, cx, cy, cw, PAL.faint)
      cy = cy + Kit.wrapHeight("micro", line, cw)
    end
    return cy + pad - y
  end

  -- saves caption, with Import .sav at its right
  local smallH = math.max(Kit.tapMin(), math.floor(30 * s))
  local iw = Kit.textWidth("small", "Import .sav") + Theme.space("xl", s) + Theme.space("m", s)
  Kit.caption(cx, cy + (smallH - Kit.textHeight("caption")) / 2, "SAVES", PAL.caption)
  if Kit.button(cx + cw - iw, cy, iw, smallH, "Import .sav",
      { id = "save-import", font = "small", icon = "upload", fullLabel = true,
        enabled = cartId == nil }) then
    self:queue(function() self:pickSave() end)
  end
  cy = cy + smallH + Theme.space("s", s)

  local chosen = self.selectedSlot[scope]
  local has = chosen ~= nil and #slots > 0
  local cardH = math.max(Kit.tapMin() + Theme.space("m", s), math.floor(62 * s))
  local gap = Theme.space("s", s)
  local extraH = (self.saveConfirm and self.saveConfirm.version == v or (self.renaming == chosen and has))
    and (smallH + Theme.space("m", s)) or 0
  local footY = y + h - pad - btnH
  local viewH = footY - Theme.space("l", s) - extraH - cy
  local menuAt
  if viewH < cardH * 0.75 then
    local line = "No saves yet - New game starts one"
    for _, sl in ipairs(slots) do
      if sl.id == chosen then line = "Save: " .. tostring(sl.label or sl.name or sl.id) end
    end
    if viewH >= Kit.textHeight("small") then
      Kit.text("small", Kit.ellipsize("small", line, cw), cx, cy, PAL.muted)
    end
  elseif #slots == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, cardH * 1.5), "No saves yet. New game starts one.")
  else
    local maxAt = Kit.scrollExtent(#slots * (cardH + gap) - gap, viewH)
    self.slotScroll = Kit.scrollInput(self.slotScroll, maxAt, cx, cy, cw, viewH)
    local py = Kit.scrollBegin(cx, cy, cw, viewH, self.slotScroll, maxAt)
    local rw = cw - Kit.scrollGutter(s)
    local total = GameVersion.generation(v) == 2 and 16 or 8
    for i, slot in ipairs(slots) do
      local ry = py + (i - 1) * (cardH + gap)
      local picked = chosen == slot.id
      local clicked, ink = Kit.row(cx, ry, rw, cardH, picked, "slot-" .. slot.id)
      local mbw = math.max(Kit.tapMin(), math.floor(36 * s))
      local mbx, mby = cx + rw - mbw - Theme.space("s", s), ry + (cardH - mbw) / 2
      if Kit.button(mbx, mby, mbw, mbw, "", { id = "save-menu-" .. slot.id, icon = "ellipsis",
          face = "bare", ring = false, iconInk = picked and PAL.inverse or PAL.text }) then
        local id = slot.id
        self:queue(function()
          self.selectedSlot[scope] = id
          self.saveMenu = self.saveMenu ~= id and id or nil
        end)
      end
      if self.saveMenu == slot.id then menuAt = { x = mbx + mbw, y = mby + mbw, slot = slot } end
      local meta = slot.meta or {}
      local dotsW = 0
      if rw > 300 * s then
        local d = math.max(4, math.floor(6 * s))
        local g = math.max(2, math.floor(3 * s))
        dotsW = 8 * (d + g) - g
        local dotsH = math.ceil(total / 8) * (d + g) - g
        drawBadges(mbx - Theme.space("m", s) - dotsW, ry + (cardH - dotsH) / 2,
          tonumber(meta.badges) or 0, total, color, s)
      end
      local textW = mbx - Theme.space("l", s) - dotsW - (cx + Theme.space("m", s))
      local tx2 = cx + Theme.space("m", s)
      local top = ry + (cardH - Kit.textHeight("button") - Kit.textHeight("micro") - Theme.space("xxs", s)) / 2
      Kit.text("button", Kit.ellipsize("button", tostring(slot.label or slot.name or slot.id), textW),
        tx2, top, ink or PAL.text)
      local parts = {}
      if meta.timeText then parts[#parts + 1] = tostring(meta.timeText) end
      if meta.dexCount then parts[#parts + 1] = tostring(meta.dexCount) .. " in Pokedex" end
      if dotsW == 0 and meta.badges then parts[#parts + 1] = tostring(meta.badges) .. " badges" end
      Kit.text("micro", Kit.ellipsize("micro", table.concat(parts, "  -  "), textW), tx2,
        top + Kit.textHeight("button") + Theme.space("xxs", s), picked and (ink or PAL.text) or PAL.muted)
      if clicked and not Kit.hit(mbx, mby, mbw, mbw) then
        local id = slot.id
        self:queue(function() self.selectedSlot[scope] = id; self.saveMenu = nil end)
      end
    end
    Kit.scrollEnd(cx, cy, cw, viewH, self.slotScroll, maxAt, PAL.surface)
  end

  -- rename field, or the footer-bytes question, above the buttons
  local ay = footY - Theme.space("m", s) - smallH
  if self.saveConfirm and self.saveConfirm.version == v then
    local half2 = math.floor((cw - Theme.space("m", s)) / 2)
    if Kit.button(cx, ay, half2, smallH, "Import without them",
        { id = "save-confirm-yes", kind = "primary", font = "small" }) then
      self:queue(function() self:confirmSave(true) end)
    end
    if Kit.button(cx + cw - half2, ay, half2, smallH, "Cancel",
        { id = "save-confirm-no", font = "small" }) then
      self:queue(function() self:confirmSave(false) end)
    end
  elseif self.renaming == chosen and has then
    local okW = math.floor(90 * s)
    local fw = cw - 2 * (okW + Theme.space("s", s))
    local ended
    self.renameText, ended = Kit.textfield("rename-field", cx, ay, fw, smallH, self.renameText, "Save name")
    if Kit.button(cx + fw + Theme.space("s", s), ay, okW, smallH, "Save",
        { id = "rename-ok", kind = "primary", font = "small" }) or ended == "submit" then
      local text = self.renameText
      self:queue(function() self:renameSave(text) end)
    end
    if Kit.button(cx + cw - okW, ay, okW, smallH, "Cancel",
        { id = "rename-cancel", font = "small" }) or ended == "cancel" then
      self:queue(function() self.renaming = nil end)
    end
  end

  -- Continue opens the chosen save; New game makes another
  local half = math.floor((cw - Theme.space("m", s)) / 2)
  local current
  for _, sl in ipairs(slots) do if sl.id == chosen then current = sl end end
  local label = "Continue"
  if current and Kit.textWidth("button", "Continue  -  " .. tostring(current.label or current.name or ""))
      < half - Theme.space("xl", s) then
    label = "Continue  -  " .. tostring(current.label or current.name or "")
  end
  if Kit.button(cx, footY, half, btnH, label,
      { id = "continue", kind = "primary",
        enabled = has and not problem and not self:importing() }) then
    self:queue(function() self:play(v, chosen) end)
  end
  if Kit.button(cx + cw - half, footY, half, btnH, "New game",
      { id = "newgame", kind = "accent", enabled = not problem and not self:importing() }) then
    self:queue(function() self:newGame(v) end)
  end

  if menuAt then self:drawSaveMenu(menuAt, x, y, w, h, s, cartId, scope)
  else self.saveMenuRect = nil end
  if gameMenuAt then
    local items = { { id = "banner-reimport", label = "Import ROM again", icon = "refresh-cw",
      run = function() self:reimport(v) end } }
    local okP, Platform = pcall(require, "src.core.Platform")
    local lfs = love and love.filesystem
    if okP and Platform.canSpawnProcess() and lfs and lfs.getSaveDirectory and love.system.openURL then
      items[#items + 1] = { id = "banner-folder", label = "Open data folder", icon = "folder-open",
        run = function() pcall(love.system.openURL, "file://" .. lfs.getSaveDirectory()) end }
    end
    self.gameMenuRect = self:drawPopup(gameMenuAt, items, x, y, w, h, s, "banner-menu",
      function() self.gameMenu = nil end)
  end
  return self:detailNeed(w, s, compact)
end

-- The "..." menu of one save: the actions used less often than Continue.
function Launcher:drawSaveMenu(at, x, y, w, h, s, cartId, scope)
  local v = self.selected
  local slot = at.slot
  local items = {
    { id = "save-rename", label = "Rename", icon = "pencil", run = function()
        self.renaming = slot.id
        self.renameText = slot.label or slot.name or ""
        Kit.setFocus("rename-field")
        Kit.focus = "rename-field"
        -- the old name is selected: typing replaces it
        Kit.selectAll = "rename-field"
      end },
    { id = "save-duplicate", label = "Duplicate", icon = "copy",
      run = function() self:duplicateSave() end },
    { id = "save-export", label = "Export .sav", icon = "download", enabled = cartId == nil,
      run = function() self:exportSave() end },
  }
  -- the full .lua save, where a file manager can reach the exports folder
  local okP, Platform = pcall(require, "src.core.Platform")
  if okP and Platform.canSpawnProcess() then
    items[#items + 1] = { id = "save-export-lua", label = "Export .lua", icon = "download",
      run = function() self:exportSaveLua() end }
  end
  if self.opts.onEditSave then
    items[#items + 1] = { id = "save-edit", label = "Edit", icon = "file-pen-line",
      enabled = cartId == nil, run = function() self:editSave() end }
  end
  local armed = self.armedDelete == v .. ":" .. tostring(slot.id)
  items[#items + 1] = { id = "save-delete", label = armed and "Confirm delete" or "Delete",
    icon = "trash", danger = true, keep = true, run = function() self:deleteSave() end }
  self.saveMenuRect = self:drawPopup(at, items, x, y, w, h, s, "save-menu-" .. tostring(slot.id),
    function() self.saveMenu = nil end)
end

-- A small menu of actions under (or above) an anchor point, inside the box
-- x, y, w, h.  It draws over everything and takes the press; a press
-- outside, or the pad ring leaving it, calls `close`.  Returns its rect for
-- the caller to occlude next frame (it is drawn last).
function Launcher:drawPopup(at, items, x, y, w, h, s, openerId, close)
  local itemH = math.max(Kit.tapMin(), math.floor(38 * s))
  local mw = math.floor(math.min(220 * s, w - 2 * Theme.space("m", s)))
  local mh = #items * itemH + 2 * Theme.space("xs", s)
  local mx = math.max(x + Theme.space("s", s), math.min(at.x - mw, x + w - mw - Theme.space("s", s)))
  local my = at.y + Theme.space("xs", s)
  if my + mh > y + h - Theme.space("s", s) then my = math.max(y + Theme.space("s", s), at.y - mh - 44 * s) end
  Theme.shadow(mx, my, mw, mh, Theme.radius())
  Theme.fillRounded(mx, my, mw, mh, PAL.raised, 1, Theme.radius())
  Theme.strokeRounded(mx, my, mw, mh, PAL.line, Theme.A.hairline, 1, Theme.radius())
  local wasOverlay = Kit._overlay
  Kit._overlay = true
  for i, it in ipairs(items) do
    local iy = my + Theme.space("xs", s) + (i - 1) * itemH
    if Kit.button(mx + Theme.space("xs", s), iy, mw - 2 * Theme.space("xs", s), itemH, it.label,
        { id = it.id, face = "nav", icon = it.icon, fullLabel = true, align = "left",
          enabled = it.enabled ~= false,
          ink = it.danger and Theme.readable(PAL.red, PAL.raised) or PAL.text }) then
      self:queue(function()
        if not it.keep then close() end
        it.run()
      end, it.danger)
    end
  end
  -- the ring leaving it closes it too (pad and keyboard)
  local inMenu = Kit.focusId == openerId
  for _, it in ipairs(items) do inMenu = inMenu or Kit.focusId == it.id end
  if Kit._ringShown and not inMenu then self:queue(close, true) end
  -- a press anywhere else closes it
  if Kit.mouseClicked and not Kit.hit(mx, my, mw, mh) then self:queue(close, true) end
  Kit._overlay = wasOverlay
  return { mx, my, mw, mh }
end

function Launcher:boxMetrics(s)
  local W, H = love.graphics.getDimensions()
  return { s = s, W = W, H = H, pad = math.floor(16 * s),
           btnH = math.max(Kit.tapMin(), math.floor(40 * s)) }
end

function Launcher:drawBox(x, y, w, h, s)
  local m = self:boxMetrics(s)
  local BoxPanel = require("src.import.BoxPanel")
  self._tabScroll = self._tabScroll or {}
  self._tabRegionRect = { x = x, y = y, w = w, h = h }
  local popup = self._boxPopup or self._boxPrompt
  local blocked = Kit.blockClicks
  if popup then Kit.blockClicks = true end
  local maxAt = Kit.scrollExtent(self.boxContentH or h, h)
  local at = Kit.scrollInput(math.min(self._tabScroll.box or 0, maxAt), maxAt, x, y, w, h)
  self._tabScroll.box = at
  local py = Kit.scrollBegin(x, y, w, h, at, maxAt)
  local okD, contentH = pcall(BoxPanel.draw, self, x, py, w - Kit.scrollGutter(s), h, m)
  Kit.scrollEnd(x, y, w, h, at, maxAt, PAL.field)
  if okD then
    self.boxContentH = tonumber(contentH) or h
  else
    self:say("The Box could not draw: " .. tostring(contentH), "error")
  end
  pcall(require("src.import.BoxOrganizer").drawSticky, self, m)
  Kit.blockClicks = blocked
end

-- What the Box opens over everything: its chooser/confirm popup and its
-- rename prompt.  Drawn last, after the footer.
function Launcher:drawBoxOverlays(s)
  local m = self:boxMetrics(s)
  local BoxUI = require("src.import.BoxUI")
  pcall(BoxUI.occludeToast, self)
  pcall(BoxUI.drawToast, self, m, m.H - math.floor(12 * s))
  if self._boxPopup then
    local ok, err = pcall(BoxUI.drawPopup, self, m)
    if not ok then self:say(tostring(err), "error") BoxUI.close(self) end
    return
  end
  local prompt = self._boxPrompt
  if not prompt then return end
  local BoxHost = require("src.import.BoxHost")
  local pad = math.floor(18 * s)
  local fieldH = math.max(Kit.tapMin(), math.floor(40 * s))
  local px, py, pw = BoxHost.kit.modalPanel(m, math.floor(460 * s),
    2 * pad + Kit.textHeight("title") + 2 * fieldH + math.floor(24 * s), { scrim = 0.76 })
  local cx, cw = px + pad, pw - 2 * pad
  local cy = py + pad
  Kit.textBold("title", Kit.ellipsize("title", tostring(prompt.title or "Rename"), cw), cx, cy,
    PAL.heading)
  cy = cy + Kit.textHeight("title") + math.floor(12 * s)
  local text = Kit.textfield("box-prompt", cx, cy, cw, fieldH, prompt.text, "")
  if prompt.maxLen then
    -- maxLen counts characters, not bytes: "é" is one
    local count, cut = 0, #text
    for pos in text:gmatch("()[^\128-\191]") do
      count = count + 1
      if count > prompt.maxLen then cut = pos - 1 break end
    end
    text = text:sub(1, cut)
  end
  prompt.text = text
  cy = cy + fieldH + math.floor(12 * s)
  local bw = math.floor((cw - math.floor(10 * s)) / 2)
  local BoxPrompt = require("src.import.BoxPrompt")
  if Kit.button(cx, cy, bw, fieldH, "Cancel", { id = "box-prompt-cancel" }) then
    self:queue(function() BoxPrompt.close(self, false) end)
  end
  if Kit.button(cx + cw - bw, cy, bw, fieldH, "Save", { id = "box-prompt-ok", kind = "primary" }) then
    self:queue(function() BoxPrompt.close(self, true) end)
  end
end

-- --------------------------------------------------------- navigation

-- Which top-level section a page belongs to: the rail / tab bar highlight.
local SECTION_OF = { box = "box", online = "online", settings = "settings", sync = "settings",
  notes = "notes" }
function Launcher:section()
  return SECTION_OF[self.page] or "games"
end

function Launcher:goSection(section)
  if section == self:section() and section ~= "games" then return end
  if self.page == "box" and section ~= "box" then self:closeBox() end
  if section == "games" then self.page = nil
  elseif section == "box" then self:openBox()
  elseif section == "online" then self:openOnline()
  elseif section == "notes" then
    self.notesFrom, self.page, self.notesScroll = nil, "notes", 0
  else self.page = section end
end

local NAV = {
  { id = "games", label = "Games", icon = "gamepad-2" },
  { id = "box", label = "Box", icon = "package" },
  { id = "online", label = "Online", icon = "globe" },
  { id = "settings", label = "Settings", icon = "settings" },
}
Launcher.NAV = NAV

function Launcher:railWidth(W, s)
  return math.floor(Theme.clamp(W * 0.18, 168 * s, 220 * s))
end

function Launcher:drawRail(x, y, w, h, s)
  Theme.fill(x, y, w, h, PAL.sidebar, 1)
  Theme.fill(x + w - 1, y, 1, h, PAL.line, Theme.A.hairline)
  local inset = Theme.space("m", s)
  local ix, iw = x + inset, w - 2 * inset
  local upLabel, upAction, upEnabled = self:updateChip()
  local quits = self:canQuit()
  local count = #NAV + 1 + (upLabel and 1 or 0) + (quits and 1 or 0)
  local gap, groupGap = Theme.space("xs", s), Theme.space("l", s)
  local itemH = math.max(Kit.tapMin(), math.floor(44 * s))
  local top = Theme.space("xl", s) * 2 + Kit.textHeight("headline")
  -- a short window (a landscape phone) tightens the rail, then drops the name
  local function fits() return top + count * (itemH + gap) + groupGap * 2 <= h end
  if not fits() then
    itemH = math.max(Kit.tapMin(), math.floor((h - top - groupGap * 2) / count) - gap)
  end
  local showName = fits()
  if not showName then top, groupGap = Theme.space("s", s), Theme.space("xs", s) end
  local cy = y + Theme.space(showName and "xl" or "s", s)
  if showName then
    Kit.textBold("headline", Version.NAME or "PK:GB", ix + Theme.space("s", s), cy, PAL.heading)
    cy = cy + Kit.textHeight("headline") + Theme.space("xl", s)
  end
  local current = self:section()
  local function item(it, iy, opts)
    opts = opts or {}
    if Kit.button(ix, iy, iw, itemH, it.label, { id = "nav-" .. it.id, face = "nav",
        icon = it.icon, fullLabel = true, align = "left", active = current == it.id,
        color = opts.color, glow = opts.glow, enabled = opts.enabled }) then
      if opts.run then self:queue(opts.run) else self:queue(function() self:goSection(it.id) end) end
    end
  end
  for _, it in ipairs(NAV) do
    item(it, cy)
    cy = cy + itemH + gap
  end
  cy = cy + groupGap
  item({ id = "notes", label = "What's new", icon = "sparkles" }, cy)
  cy = cy + itemH + gap
  if upLabel then
    item({ id = "update", label = upLabel, icon = "download" }, cy,
      { run = upAction, enabled = upEnabled, glow = upEnabled, color = PAL.yellow })
    cy = cy + itemH + gap
  end
  -- Quit sits at the foot, away from everything else, when there is room
  if quits then
    local footY = y + h - Theme.space(showName and "l" or "s", s) - itemH
    item({ id = "quit", label = "Quit", icon = "x" }, math.max(cy + groupGap, footY),
      { run = function() self:quit() end })
  end
end

function Launcher:tabBarHeight(s)
  return math.max(Kit.tapMin() + Theme.space("m", s), math.floor(60 * s))
end

function Launcher:drawTabBar(x, y, w, h, s)
  Theme.fill(x, y, w, h, PAL.sidebar, 1)
  Theme.fill(x, y, w, 1, PAL.line, Theme.A.hairline)
  local current = self:section()
  if current == "notes" then current = "settings" end
  local tw = w / #NAV
  for i, it in ipairs(NAV) do
    if Kit.button(x + (i - 1) * tw, y + Theme.space("xs", s), tw, h - Theme.space("s", s), it.label,
        { id = "tab-" .. it.id, face = "nav", icon = it.icon, fullLabel = true, font = "micro",
          iconStack = true, active = current == it.id, accent = "top" }) then
      local id = it.id
      self:queue(function() self:goSection(id) end)
    end
  end
end

-- Phones and the browser leave through the system; a desktop window gets Quit.
function Launcher:canQuit()
  local os_ = love.system and love.system.getOS and love.system.getOS() or ""
  return os_ ~= "Android" and os_ ~= "iOS" and os_ ~= "Web"
end

function Launcher:drawFooter(x, y, w, s)
  local lines = Kit.wrapLines("micro", Launcher.CREDIT, w) or {}
  local lh = Kit.textHeight("micro")
  for i, line in ipairs(lines) do
    local lw = Kit.textWidth("micro", line)
    Kit.text("micro", line, x + (w - lw) / 2, y + (i - 1) * lh, PAL.muted)
  end
  return #lines * lh
end

function Launcher:footerHeight(w)
  return #(Kit.wrapLines("micro", Launcher.CREDIT, w) or { 1 }) * Kit.textHeight("micro")
end

function Launcher:draw()
  local W, H = love.graphics.getDimensions()
  Kit.layout(W, H)
  local s = Kit.scale or 1
  local mx, my = 0, 0
  if love.mouse and love.mouse.getPosition then mx, my = love.mouse.getPosition() end
  local click = self.click
  if click then mx, my = click.x, click.y end
  -- the pad moves between the launcher's columns (Kit._resolveColumns);
  -- set for this frame only, so another screen keeps the kit's own rules
  Kit.navColumn, Kit.navColumnOrder = Launcher.navColumn, Launcher.NAV_COLUMNS
  Kit.navAnchor = function(col)
    if col == "list" then return self.selected and ("game-" .. self.selected) end
    if col == "rail" then return "nav-" .. self:section() end
    if col == "content" and not self.page and self.selected then
      local save = self:currentSave(self.selected)
      return save and ("slot-" .. save.id) or "continue"
    end
  end
  Kit.beginFrame(mx, my, click ~= nil, self.wheel or 0)
  -- the toast is drawn last; last frame's rect keeps a press on it from
  -- also landing on the control underneath
  local tr = self.message and self.toastRect
  if tr then Kit.occlude(tr[1], tr[2], tr[3], tr[4]) end
  -- the in-app file browser is modal: nothing under it takes a press
  local browsing = Kit.FileBrowser.active
  if browsing then Kit.blockClicks = true end
  self.click, self.wheel = nil, 0
  Theme.field()
  -- a Box popup or prompt owns the frame: nothing under its scrim takes clicks
  local boxModal = self.page == "box" and (self._boxPopup or self._boxPrompt) ~= nil
  Kit.blockClicks = boxModal

  local pad = math.floor(Theme.clamp(W * 0.03, 12, 28))
  -- a left rail on a wide window or a landscape phone; a bottom tab bar on
  -- a portrait one (Launcher:drawRail / drawTabBar)
  local railMode = W >= 860 * s or (W >= 520 and W >= H * 1.3)
  self.railMode = railMode
  local x, w, y, bottom
  if railMode then
    local railW = self:railWidth(W, s)
    self:drawRail(0, 0, railW, H, s)
    x, w, y, bottom = railW + pad, W - railW - 2 * pad, pad, H - pad
  else
    x, w, y = pad, W - 2 * pad, pad
    -- compact title bar: the name, and an update when one is ready
    Kit.textBold("title", Version.NAME or "PK:GB", x, y, PAL.heading)
    local upLabel, upAction, upEnabled = self:updateChip()
    if upLabel then
      local uh = math.max(Kit.tapMin(), math.floor(30 * s))
      local uw = math.min(w - Kit.textWidth("title", Version.NAME or "PK:GB") - Theme.space("m", s),
        Kit.textWidth("small", upLabel) + Theme.space("xl", s))
      if Kit.button(x + w - uw, y + (Kit.textHeight("title") - uh) / 2, uw, uh, upLabel,
          { id = "update", font = "small", kind = "warn", glow = upEnabled,
            enabled = upEnabled }) and upAction then
        self:queue(upAction)
      end
    end
    y = y + Kit.textHeight("title") + Theme.space("m", s)
    local tabH = self:tabBarHeight(s)
    self:drawTabBar(0, H - tabH, W, tabH, s)
    bottom = H - tabH - Theme.space("s", s)
  end

  local footH = self:footerHeight(w) + Theme.space("m", s)
  local bodyH = bottom - y - footH

  -- a page change slides the content in from a little to the right; clicks
  -- wait for it to settle so none lands where the content used to be
  local pageKey = tostring(self.page)
  if pageKey ~= self.lastPageKey then
    if self.lastPageKey ~= nil and not self.reduceMotion then self.pageAt, self.pageFrames = now(), 0 end
    self.lastPageKey = pageKey
  end
  local slide = 0
  local t = 1
  if self.pageAt then
    -- by time, or by frames when the clock stalls (a hitch, a headless run)
    self.pageFrames = (self.pageFrames or 0) + 1
    t = math.max((now() - self.pageAt) / Launcher.SLIDE_TIME, self.pageFrames / 9)
  end
  if t < 1 then
    slide = math.floor((1 - t) * (1 - t) * Theme.space("xl", s))
    love.graphics.push()
    love.graphics.translate(slide, 0)
    Kit.blockClicks = true
  end

  -- side by side when the content area is wide enough, else stacked
  local wide = w >= 600 * s or (railMode and w >= 480)
  if self.page == "box" then
    self:drawBox(x, y, w, bodyH, s)
  elseif self.page == "online" and self.online then
    self:drawFitted("online", x, y, w, bodyH, s, function(l, ...) return l.online:draw(...) end)
  elseif self.page and (not wide or self:section() ~= "games") then
    -- a section page (settings, what's new) or, stacked, a game page (mods,
    -- carts) takes the whole content area
    self:drawDetail(x, y, w, bodyH, s)
  elseif wide then
    local listW = math.floor(math.min(320 * s, w * 0.36))
    self:drawGameList(x, y, listW, bodyH, s)
    self:drawDetail(x + listW + Theme.space("l", s), y, w - listW - Theme.space("l", s), bodyH, s)
  else
    -- the game list yields height to the detail panel down to two rows
    local listMin = Kit.textHeight("caption") + math.floor(110 * s)
    local listH = math.floor(math.max(listMin,
      math.min(bodyH * 0.42, bodyH - Theme.space("m", s) - self:detailNeed(w, s))))
    self:drawGameList(x, y, w, listH, s)
    self:drawDetail(x, y + listH + Theme.space("m", s), w, bodyH - listH - Theme.space("m", s), s)
  end

  local fy = bottom - self:footerHeight(w)
  self:drawFooter(x, fy, w, s)
  if slide ~= 0 then
    love.graphics.pop()
    Kit.blockClicks = boxModal
  end
  self:drawToast(x, y + Theme.space("xs", s), w, s)
  if browsing then
    local W, H = love.graphics.getDimensions()
    Kit.FileBrowser.draw({ s = s, W = W, H = H })
  end
  if self.page == "box" then
    Kit.blockClicks = false
    self:drawBoxOverlays(s)
  end
  Kit.endFrame()
  Kit.navColumn, Kit.navColumnOrder, Kit.navAnchor = nil, nil, nil
end

Launcher.NAV_COLUMNS = { "rail", "list", "content" }

function Launcher.navColumn(slot)
  local id = tostring(slot.id or "")
  if id:match("^nav%-") then return "rail" end
  if id:match("^tab%-") then return "tabs" end
  if id:match("^game%-import%-") then return "skip" end
  if id:match("^game%-") then return "list" end
  return "content"
end

return Launcher
