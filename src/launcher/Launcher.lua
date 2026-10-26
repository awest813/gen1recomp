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
local MOD_KIND = { label = "Mod package", exts = { "zip" } }
local CART_KIND = { label = "Custom cart", exts = { "g1rcart" } }

-- ------------------------------------------------------------------ model

local function cacheReady(version)
  local ok, CacheContract = pcall(require, "src.import.CacheContract")
  if not ok then return false end
  local okR, ready = pcall(CacheContract.isReady, version)
  return okR and ready or false
end

local function visibleGame(version)
  local ok, SecretGames = pcall(require, "src.import.SecretGames")
  if ok and SecretGames.visible then
    local okV, shown = pcall(SecretGames.visible, version)
    if okV then return shown and true or false end
  end
  return true
end

function Launcher.new(onLaunch, opts)
  opts = opts or {}
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
  local last = okO and type(saved) == "table" and saved.lastVersion or nil
  self.selected = (opts.initialGame and self.ready[opts.initialGame]
    and opts.initialGame) or (last and self.ready[last] and last)
    or first or self.games[1]
  -- ask the self-updater (src/update/Check.lua) whether a release is out;
  -- it works on a worker thread and is a no-op where it cannot run
  if not opts.noUpdateCheck then
    local okC, Check = pcall(require, "src.update.Check")
    if okC then pcall(Check.start) end
  end
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
  for _, v in ipairs(self.games) do self.ready[v] = cacheReady(v) end
  self.slots = {}
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
-- run, else the reason it will be refused.
function Launcher:cartProblem(version)
  local cart = self:activeCart(version)
  if not cart then return nil end
  self.cartPlans = self.cartPlans or {}
  local plan = self.cartPlans[cart]
  if plan == nil then
    plan = false
    pcall(function()
      local installed = {}
      for _, row in ipairs(self:modsFor(version)) do
        if row.manifest then
          installed[row.id] = { id = row.id, version = row.manifest.version }
        end
      end
      local report = require("src.mods.Loader").planCart(
        require("src.carts.CartStore").get(cart), installed)
      if report and report.refused then
        plan = tostring(report.message or "this cart cannot start")
        -- the message leads with the cart's title, which the panel already shows
        local title = tostring(report.title or "") .. ": "
        if plan:sub(1, #title) == title then plan = plan:sub(#title + 1) end
      end
    end)
    self.cartPlans[cart] = plan
  end
  return plan or nil
end

function Launcher:selectCart(version, id)
  self.renaming, self.saveConfirm = nil, nil
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

function Launcher:installCart(data, name)
  local CartStore = require("src.carts.CartStore")
  local ok, cart, err = pcall(CartStore.install, data)
  if not ok then cart, err = nil, cart end
  self.cartRows, self.cartPlans = nil, nil
  if not cart then
    return self:say("Could not install " .. tostring(name or "that cart") .. ": "
      .. tostring(err), "error")
  end
  if cart.base and self.ready[cart.base] ~= nil then
    self.selected = cart.base
    self:selectCart(cart.base, cart.id)
  end
  local info = cart.base and GameVersion.info(cart.base)
  self:say(("Installed %s%s."):format(tostring(cart.title or cart.id),
    info and (" for " .. info.displayName) or ""), "info")
end

function Launcher:removeCart(version, row)
  local key = "cart:" .. tostring(row.id)
  if self.armedDelete ~= key then
    self.armedDelete = key
    return self:say("Press Remove again to uninstall " .. tostring(row.title)
      .. ". Its saves are kept.", "info")
  end
  self.armedDelete = nil
  local ok, done, err = pcall(require("src.carts.CartStore").uninstall, row.id)
  if self.cart[version] == row.id then self.cart[version] = nil end
  self.cartRows, self.cartPlans = nil, nil
  if not (ok and done) then
    return self:say("Could not remove " .. tostring(row.title) .. ": "
      .. tostring(ok and err or done), "error")
  end
  self:say(tostring(row.title) .. " was removed.", "info")
end

function Launcher:pickCart()
  if self:requestHostPick("cart") then return end
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  if not (ok and FilePicker.available()) then
    return self:say("Drop a .g1rcart file onto this window to install it.", "info")
  end
  local path = FilePicker.open("Choose a custom cart", CART_KIND)
  if not path then return end
  local data, err = FilePicker.read(path)
  if not data then return self:say("Could not read that file: " .. tostring(err), "error") end
  self:installCart(data, FilePicker.basename(path))
end

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
  if not self.selectedSlot[key] and list[1] then
    local okA, active = false, nil
    if okS then okA, active = pcall(store.active) end
    self.selectedSlot[key] = okA and active or list[1].id
  end
  return list
end

function Launcher:queue(fn, keepArmed)
  if not keepArmed then self.armedDelete = nil end
  self.actions[#self.actions + 1] = fn
end

-- ---------------------------------------------------------------- actions

function Launcher:say(text, kind)
  self.message = text and { text = text, kind = kind or "info" } or nil
end

-- Verify bytes from a picker or a drop and start importing them.
function Launcher:importData(data, name)
  if self.job and self.job.state == "working" then
    return self:say("An import is already running.", "error")
  end
  local rom, err = ImportJob.verify(data, name, visibleGame)
  if not rom then return self:say(err, "error") end
  self.selected = rom.version
  self:say(nil)
  self.job = ImportJob.start(rom)
  if self.job.state == "error" then
    self:say(self.job.error, "error")
    self.job = nil
  end
end

-- The browser (and UWP) build opens files through an async bridge on
-- love.system: pickFile(kind) shows the picker, and the chosen file later
-- appears through getPickedFile() as a temporary path (or getPickError()
-- explains why not).  See ports/web/native/lovejs_bridge.cpp.
local function hostPicker()
  local sys = love and love.system
  if sys and type(sys.pickFile) == "function"
      and type(sys.getPickedFile) == "function" then
    return sys
  end
  return nil
end

-- `as` names what the picked file is for when it differs from the picker's
-- filter (a Box save is picked with the "sav" filter).
function Launcher:requestHostPick(kind, as)
  local sys = hostPicker()
  if not sys then return false end
  local ok, started = pcall(sys.pickFile, kind)
  if not ok or started == false then
    self:say("The file picker could not open.", "error")
    return true
  end
  self.pendingPick = as or kind
  return true
end

-- Collect a finished host pick; called from update().
function Launcher:pollHostPick()
  local sys = self.pendingPick and hostPicker()
  if not sys then return end
  local kind = self.pendingPick
  local okP, path = pcall(sys.getPickedFile)
  if okP and type(path) == "string" and path ~= "" then
    self.pendingPick = nil
    local FilePicker = require("src.core.FilePicker")
    local name = FilePicker.basename(path)
    if kind == "box" then
      local data, err = FilePicker.read(path)
      pcall(os.remove, path)
      return self:importBox(data, err)
    end
    if kind == "cart" then
      local data, err = FilePicker.read(path)
      pcall(os.remove, path)
      if not data then
        return self:say("Could not read that file: " .. tostring(err), "error")
      end
      return self:installCart(data, name)
    end
    if kind == "mod" then
      local data, err = FilePicker.read(path)
      pcall(os.remove, path)
      if not data then
        return self:say("Could not read that file: " .. tostring(err), "error")
      end
      return self:installMod(data, name)
    end
    if kind == "sav" then
      -- by path: SaveFileIO only takes raw bytes for a bare 32 KiB image,
      -- and a Gen 2 save (RTC footer) or a Gen 3 one is larger
      local cleanup = function() pcall(os.remove, path) end
      if self:importSave(path, name, nil, cleanup) ~= "confirm" then cleanup() end
      return
    end
    local data, err = FilePicker.read(path)
    pcall(os.remove, path)
    if not data then
      return self:say("Could not read that file: " .. tostring(err), "error")
    end
    return self:importData(data, name)
  end
  local okE, err = false, nil
  if type(sys.getPickError) == "function" then okE, err = pcall(sys.getPickError) end
  if okE and type(err) == "string" and err ~= "" then
    self.pendingPick = nil
    -- closing the picker is not an error
    if not err:match("^cancelled:") then self:say(err, "error") end
  end
end

function Launcher:pickRom()
  if self:requestHostPick("rom") then return end
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  if not (ok and FilePicker.available()) then
    return self:say("Drop a .gb, .gbc or .gba file onto this window to "
      .. "import it.", "info")
  end
  local path = FilePicker.open("Choose a Pokemon ROM", ROM_KIND)
  if not path then return end
  local data, err = FilePicker.read(path)
  if not data then return self:say("Could not read that file: " .. tostring(err), "error") end
  self:importData(data, FilePicker.basename(path))
end

-- ------------------------------------------------------------------- mods

-- Installed mods as src/mods/ModLibrary.lua lists them for one game, cached
-- until something changes them.
function Launcher:modsFor(version)
  self.modRows = self.modRows or {}
  local rows = self.modRows[version]
  if rows then return rows end
  local ok, ModLibrary = pcall(require, "src.mods.ModLibrary")
  local okL, got = false, nil
  if ok then okL, got = pcall(ModLibrary.list, version) end
  rows = (okL and type(got) == "table") and got or {}
  self.modRows[version] = rows
  return rows
end

function Launcher:toggleMod(version, row)
  if not (row and row.id) or row.broken then return end
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, err = pcall(ModLibrary.setEnabled, row.id, not row.enabled, version)
  if not ok then return self:say("Could not change that mod: " .. tostring(err), "error") end
  self.modRows, self.cartPlans = nil, nil
  self:say(("%s is %s for %s. It applies the next time the game starts."):format(
    row.name, row.enabled and "off" or "on", GameVersion.info(version).displayName), "info")
end

function Launcher:removeMod(row)
  local key = "mod:" .. tostring(row and row.folder)
  if self.armedDelete ~= key then
    self.armedDelete = key
    return self:say("Press Remove again to uninstall " .. tostring(row.name) .. ".", "info")
  end
  self.armedDelete = nil
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, done, err = pcall(ModLibrary.uninstall, row.folder)
  self.modRows, self.cartPlans = nil, nil
  if not (ok and done) then
    return self:say("Could not remove " .. tostring(row.name) .. ": "
      .. tostring(ok and err or done), "error")
  end
  self:say(tostring(row.name) .. " was removed.", "info")
end

function Launcher:installMod(data, name)
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, manifest, err = pcall(ModLibrary.installZip, data, name, { upgrade = true })
  if not ok then manifest, err = nil, manifest end
  self.modRows, self.cartPlans = nil, nil
  if not manifest then
    return self:say("Could not install " .. tostring(name or "that mod") .. ": "
      .. tostring(err), "error")
  end
  local missing = ModLibrary.missingDependencies(manifest, ModLibrary.list())
  local text = ("Installed %s."):format(manifest.name or manifest.id)
  if #missing > 0 then
    text = text .. " It also needs: " .. table.concat(missing, ", ") .. "."
  end
  self:say(text, #missing > 0 and "error" or "info")
end

function Launcher:pickMod()
  if self:requestHostPick("mod") then return end
  local ok, FilePicker = pcall(require, "src.core.FilePicker")
  if not (ok and FilePicker.available()) then
    return self:say("Drop a mod .zip onto this window to install it.", "info")
  end
  local path = FilePicker.open("Choose a mod .zip", MOD_KIND)
  if not path then return end
  local data, err = FilePicker.read(path)
  if not data then return self:say("Could not read that file: " .. tostring(err), "error") end
  self:installMod(data, FilePicker.basename(path))
end

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
  -- hand the Box back to its default host: a launcher built after this one
  -- (the classic one, after a switch) does not take queued actions
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
  return self.selectedSlot[self:scopeKey(version or self.selected)]
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
  self:say("Exported to " .. tostring(result), "info")
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

function Launcher:setOption(key, value)
  local opts = self:options()
  opts[key] = value
  local ok, SaveData = pcall(require, "src.core.SaveData")
  if ok then pcall(SaveData.saveOptions, opts) end
  if key == "videoMode" then
    local okV, VideoMode = pcall(require, "src.core.VideoMode")
    if okV then VideoMode.apply(value) end
  end
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
  local okP, errP = pcall(self.pollHostPick, self)
  if not okP then
    self.pendingPick = nil
    self:say(tostring(errP), "error")
  end
  if self.page == "box" then
    local ok, err = pcall(require("src.import.BoxPanel").update, self, dt)
    if not ok then self:say(tostring(err), "error") end
  end
  if self.job then
    local state = self.job:step(0.008)
    if state == "done" then
      local version = self.job.version
      self.job = nil
      self:refresh()
      self.selected = version
      self:say(GameVersion.info(version).displayName .. " is ready to play.", "info")
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
function Launcher:back()
  if self.page == "box" then return self:closeBox() end
  self.page = nil
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
function Launcher:touchpressed(id, x, y)
  if showcase(self, "pointerPressed", id, x, y) then return end
  self.pressAt = { x = x, y = y }
end
function Launcher:touchmoved(id, x, y) showcase(self, "pointerMoved", id, x, y) end
function Launcher:touchreleased(id, x, y)
  if showcase(self, "pointerReleased", id) then
    self.pressAt = nil
    return
  end
  if self.pressAt then self.click = { x = x, y = y } end
  self.pressAt = nil
end

function Launcher:wheelmoved(_, dy) self.wheel = (self.wheel or 0) + dy end

function Launcher:keypressed(key)
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
  if key == "tab" and not Kit.focus then
    local shift = love.keyboard and love.keyboard.isDown
      and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift"))
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

function Launcher:gamepadpressed(_, button)
  if button == "b" and not Kit.focus then
    if self._boxPopup or self._boxPrompt or self.page then return self:keypressed("escape") end
  end
  if Kit.gamepadpressed(button) then return true end
  if button == "start" then Kit.activateFocused() return true end
  return false
end

function Launcher:gamepadreleased() end
function Launcher:gamepadaxis() end
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
  self:importData(data, name:match("[^/\\]+$") or name)
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
  self.modRows, self.cartRows, self.cartPlans = nil, nil, nil
end
function Launcher:savesChanged() self.slots = {} end
function Launcher:resumeAfterOverlay() self:refresh() end
function Launcher:prepareOverlayHandoff() end
function Launcher:ignoreReturningPointer() self.pressAt, self.click = nil, nil end
-- main.lua asks a launcher to update mods before a shortcut boots; this one
-- has no mod updater, so it says so and the boot goes ahead.
function Launcher:autoUpdateAll(done)
  if done then done({ skipped = true }) end
end

-- ------------------------------------------------------------------- draw

local function statusText(self, version)
  if self.job and self.job.version == version then return "Importing", PAL.yellow end
  if self.ready[version] then return "Ready", PAL.green end
  return "Not imported", PAL.muted
end

function Launcher:drawGameList(x, y, w, h, s)
  Kit.caption(x, y, "GAMES", PAL.caption)
  local top = y + Kit.textHeight("caption") + math.floor(8 * s)
  local rowH = math.max(Kit.tapMin(), math.floor(38 * s))
  local gap = math.floor(4 * s)
  local viewH = h - (top - y)
  local contentH = #self.games * (rowH + gap)
  local maxAt = Kit.scrollExtent(contentH, viewH)
  self.listScroll = Kit.scrollInput(self.listScroll, maxAt, x, top, w, viewH)
  local py = Kit.scrollBegin(x, top, w, viewH, self.listScroll, maxAt)
  for i, v in ipairs(self.games) do
    local ry = py + (i - 1) * (rowH + gap)
    local info = GameVersion.info(v)
    local clicked, ink = Kit.row(x, ry, w - Kit.scrollGutter(s), rowH,
      self.selected == v, "game-" .. v)
    local status, color = statusText(self, v)
    local sw = Kit.textWidth("micro", status)
    local nameW = w - Kit.scrollGutter(s) - sw - math.floor(36 * s)
    -- "Pokemon Red" when it fits, else "Red": the part that tells them apart
    local name = info.displayName
    if Kit.textWidth("button", name) > nameW then name = info.label or name end
    Kit.text("button", Kit.ellipsize("button", name, math.max(0, nameW)),
      x + math.floor(12 * s), ry + (rowH - Kit.textHeight("button")) / 2, ink or PAL.text)
    Kit.text("micro", status, x + w - Kit.scrollGutter(s) - sw - math.floor(12 * s),
      ry + (rowH - Kit.textHeight("micro")) / 2,
      self.selected == v and (ink or PAL.text) or color)
    if clicked then
      self:queue(function()
        self.selected, self.page, self.renaming, self.saveConfirm = v, nil, nil, nil
        self:say(nil)
      end)
    end
  end
  Kit.scrollEnd(x, top, w, viewH, self.listScroll, maxAt)
end

function Launcher:drawSettings(x, y, w, h, s)
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  Kit.textBold("title", "Settings", cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("title") + math.floor(16 * s)
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

  local okV, VideoMode = pcall(require, "src.core.VideoMode")
  if okV and not VideoMode.fixedDisplay() then
    label("Display", cy)
    local full = VideoMode.normalize(opts.videoMode) == "borderless"
    local bw = math.floor(math.min(cw * 0.5, 300 * s))
    if Kit.button(cx + cw - bw, cy, bw, rowH, full and "Fullscreen" or "Windowed",
        { id = "video-mode" }) then
      self:queue(function()
        self:setOption("videoMode", full and "windowed" or "borderless")
      end)
    end
    cy = cy + rowH + math.floor(10 * s)
  end
  stepper("musicVol", "Music volume", 0, 7, cy)
  cy = cy + rowH + math.floor(10 * s)
  stepper("sfxVol", "Sound volume", 0, 7, cy)
  cy = cy + rowH + math.floor(10 * s)
  label("Controller skin", cy)
  local sw = math.floor(math.min(cw * 0.5, 300 * s))
  if self.opts.onOpenSkinStudio and Kit.button(cx + cw - sw, cy, sw, rowH,
      Kit.ellipsize("small", tostring(self:activeSkin() or "Built-in pad"), sw - math.floor(24 * s)),
      { id = "skins", font = "small" }) then
    self:queue(function() self:openStudio(self:activeSkin()) end)
  end
  cy = cy + rowH + math.floor(10 * s)
  -- this launcher is opt-in for now (--ui=new); offer the way back
  label("Launcher", cy)
  local classic = opts.launcherUi == "classic"
  local lw = math.floor(math.min(cw * 0.5, 300 * s))
  if Kit.button(cx + cw - lw, cy, lw, rowH, classic and "Keep this one" or "Use classic",
      { id = "launcher-ui", font = "small" }) then
    self:queue(function()
      self:setOption("launcherUi", classic and "new" or "classic")
      self:say(classic and "This launcher stays." or
        "The classic launcher opens the next time you come back from a game "
          .. "or start PK:GB.", "info")
    end)
  end
  cy = cy + rowH + math.floor(10 * s)
  -- a narrow window drops Box / What's new from the header; reach them here
  local hidden = self.headerHidden or {}
  if hidden.box or hidden.notes then
    local n = (hidden.box and 1 or 0) + (hidden.notes and 1 or 0)
    local bw2 = math.floor((cw - (n - 1) * math.floor(10 * s)) / n)
    local bx = cx
    if hidden.box then
      if Kit.button(bx, cy, bw2, rowH, "Pokemon Box", { id = "settings-box" }) then
        self:queue(function() self.page = nil; self:openBox() end)
      end
      bx = bx + bw2 + math.floor(10 * s)
    end
    if hidden.notes then
      if Kit.button(bx, cy, bw2, rowH, "What's new", { id = "settings-notes" }) then
        self:queue(function() self.page = "notes"; self.notesScroll = 0 end)
      end
    end
    cy = cy + rowH + math.floor(10 * s)
  end
  Kit.textWrapped("micro", "More options (colors, zoom, speed, controls) are in "
    .. "the game's own OPTIONS menu.", cx, cy, cw, PAL.faint)
  return cy + Kit.wrapHeight("micro", "More options (colors, zoom, speed, controls) are in "
    .. "the game's own OPTIONS menu.", cw) + pad - y
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
  Kit.textBold("title", "What's new" .. (self.notesVersion
    and ("  v" .. tostring(self.notesVersion)) or ""), cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("title") + math.floor(12 * s)
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

function Launcher:drawMods(x, y, w, h, s)
  local v = self.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local btnH = math.max(Kit.tapMin(), math.floor(40 * s))
  local backW = math.max(Kit.tapMin(), Kit.textWidth("small", "Back") + math.floor(32 * s))
  if Kit.button(cx + cw - backW, cy, backW, math.max(Kit.tapMin(), math.floor(32 * s)),
      "Back", { id = "mods-back", font = "small" }) then
    self:queue(function() self.page = nil end)
  end
  Kit.textBold("title", "Mods", cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("title") + math.floor(4 * s)
  Kit.text("small", "For " .. GameVersion.info(v).displayName, cx, cy, PAL.muted)
  cy = cy + Kit.textHeight("small") + math.floor(14 * s)

  local rows = self:modsFor(v)
  local rowH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(56 * s))
  local gap = math.floor(4 * s)
  local hint = "Or drop a mod .zip onto this window. Changes apply the next "
    .. "time the game starts."
  local hintH = Kit.wrapHeight("micro", hint, cw)
  local footH = btnH + math.floor(12 * s) + hintH
  local viewH = math.max(rowH, y + h - pad - footH - math.floor(10 * s) - cy)
  if #rows == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2), "No mods installed")
  else
    local maxAt = Kit.scrollExtent(#rows * (rowH + gap), viewH)
    self.modScroll = Kit.scrollInput(self.modScroll or 0, maxAt, cx, cy, cw, viewH)
    local py = Kit.scrollBegin(cx, cy, cw, viewH, self.modScroll, maxAt)
    local rw = cw - Kit.scrollGutter(s)
    local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Confirm") + math.floor(24 * s))
    local bh = math.max(Kit.tapMin(), math.floor(32 * s))
    for i, row in ipairs(rows) do
      local ry = py + (i - 1) * (rowH + gap)
      Kit.row(cx, ry, rw, rowH, false, "mod-" .. tostring(row.folder))
      local tx = cx + math.floor(12 * s)
      local textW = rw - 2 * bw - math.floor(36 * s)
      Kit.text("button", Kit.ellipsize("button", row.name, textW), tx, ry + math.floor(6 * s), PAL.text)
      local detail
      if row.broken then
        detail = "Broken: " .. row.broken
      elseif not row.supported then
        detail = "Not made for this game"
      else
        local parts = {}
        if row.version then parts[#parts + 1] = "v" .. tostring(row.version) end
        if row.author then parts[#parts + 1] = "by " .. tostring(row.author) end
        if row.experimental then parts[#parts + 1] = "experimental" end
        detail = table.concat(parts, "  -  ")
        if detail == "" then detail = row.id end
      end
      Kit.text("micro", Kit.ellipsize("micro", detail, textW),
        tx, ry + rowH - Kit.textHeight("micro") - math.floor(8 * s),
        row.broken and PAL.red or PAL.muted)
      local by = ry + (rowH - bh) / 2
      local onX = cx + rw - 2 * bw - math.floor(16 * s)
      local usable = not row.broken and row.supported
      if Kit.button(onX, by, bw, bh, row.enabled and usable and "On" or "Off",
          { id = "mod-toggle-" .. tostring(row.folder), font = "small",
            kind = row.enabled and usable and "primary" or nil, enabled = usable }) then
        self:queue(function() self:toggleMod(v, row) end)
      end
      local armed = self.armedDelete == "mod:" .. tostring(row.folder)
      if row.bundled then
        Kit.textCenter("micro", "Built in", onX + bw + math.floor(8 * s),
          by + (bh - Kit.textHeight("micro")) / 2, bw, PAL.faint)
      elseif Kit.button(onX + bw + math.floor(8 * s), by, bw, bh,
          armed and "Confirm" or "Remove",
          { id = "mod-remove-" .. tostring(row.folder), font = "small", kind = "danger" }) then
        self:queue(function() self:removeMod(row) end, true)
      end
    end
    Kit.scrollEnd(cx, cy, cw, viewH, self.modScroll, maxAt, PAL.surface)
  end

  local by = y + h - pad - btnH - hintH - math.floor(8 * s)
  if Kit.button(cx, by, math.min(cw, math.floor(260 * s)), btnH, "Install mod .zip",
      { id = "mod-install", kind = "accent" }) then
    self:queue(function() self:pickMod() end)
  end
  Kit.textWrapped("micro", hint, cx, by + btnH + math.floor(8 * s), cw, PAL.faint)
end

function Launcher:drawCarts(x, y, w, h, s)
  local v = self.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local btnH = math.max(Kit.tapMin(), math.floor(40 * s))
  local backW = math.max(Kit.tapMin(), Kit.textWidth("small", "Back") + math.floor(32 * s))
  if Kit.button(cx + cw - backW, cy, backW, math.max(Kit.tapMin(), math.floor(32 * s)),
      "Back", { id = "carts-back", font = "small" }) then
    self:queue(function() self.page = nil end)
  end
  Kit.textBold("title", "Carts", cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("title") + math.floor(4 * s)
  Kit.text("small", "Play " .. GameVersion.info(v).displayName .. " as", cx, cy, PAL.muted)
  cy = cy + Kit.textHeight("small") + math.floor(14 * s)

  local carts = self:cartsFor(v)
  local active = self:activeCart(v)
  local rows = { { original = true, title = "The original game",
                   detail = "No cart: your own mods and saves" } }
  for _, c in ipairs(carts) do rows[#rows + 1] = c end
  local hint = "Or drop a .g1rcart file onto this window. Each cart keeps "
    .. "its own saves."
  local hintH = Kit.wrapHeight("micro", hint, cw)
  local rowH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(56 * s))
  local gap = math.floor(4 * s)
  local viewH = math.max(rowH, y + h - pad - btnH - hintH - math.floor(22 * s) - cy)
  local maxAt = Kit.scrollExtent(#rows * (rowH + gap), viewH)
  self.cartScroll = Kit.scrollInput(self.cartScroll or 0, maxAt, cx, cy, cw, viewH)
  local py = Kit.scrollBegin(cx, cy, cw, viewH, self.cartScroll, maxAt)
  local rw = cw - Kit.scrollGutter(s)
  local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Confirm") + math.floor(24 * s))
  local bh = math.max(Kit.tapMin(), math.floor(32 * s))
  for i, row in ipairs(rows) do
    local ry = py + (i - 1) * (rowH + gap)
    local chosen = (row.original and active == nil) or (row.id ~= nil and row.id == active)
    local clicked, ink = Kit.row(cx, ry, rw, rowH, chosen,
      "cart-" .. tostring(row.id or "original"))
    local tx = cx + math.floor(12 * s)
    local textW = rw - bw - math.floor(36 * s)
    Kit.text("button", Kit.ellipsize("button", tostring(row.title or row.id), textW),
      tx, ry + math.floor(6 * s), ink or PAL.text)
    local detail = row.detail
    if not detail then
      local parts = {}
      if row.version then parts[#parts + 1] = "v" .. tostring(row.version) end
      if row.author then parts[#parts + 1] = "by " .. tostring(row.author) end
      if row.seal and row.seal ~= "open" then parts[#parts + 1] = "sealed" end
      detail = table.concat(parts, "  -  ")
    end
    Kit.text("micro", Kit.ellipsize("micro", detail, textW), tx,
      ry + rowH - Kit.textHeight("micro") - math.floor(8 * s),
      chosen and (ink or PAL.text) or PAL.muted)
    local rbx, rby = cx + rw - bw - math.floor(8 * s), ry + (rowH - bh) / 2
    -- a press on Remove is not also a press on its row
    if clicked and (row.original or not Kit.hit(rbx, rby, bw, bh)) then
      self:queue(function() self:selectCart(v, row.id) end)
    end
    if not row.original then
      local armed = self.armedDelete == "cart:" .. tostring(row.id)
      if Kit.button(rbx, rby, bw, bh,
          armed and "Confirm" or "Remove",
          { id = "cart-remove-" .. tostring(row.id), font = "small", kind = "danger" }) then
        self:queue(function() self:removeCart(v, row) end, true)
      end
    end
  end
  Kit.scrollEnd(cx, cy, cw, viewH, self.cartScroll, maxAt, PAL.surface)

  local by = y + h - pad - btnH - hintH - math.floor(8 * s)
  if Kit.button(cx, by, math.min(cw, math.floor(260 * s)), btnH, "Install cart",
      { id = "cart-install", kind = "accent" }) then
    self:queue(function() self:pickCart() end)
  end
  Kit.textWrapped("micro", hint, cx, by + btnH + math.floor(8 * s), cw, PAL.faint)
end

-- The height the game panel needs to show one save row with its tools.
function Launcher:detailNeed(w, s)
  local cw = w - 2 * math.floor(18 * s)
  local tg = math.floor(8 * s)
  local smallH = math.max(Kit.tapMin(), math.floor(32 * s))
  local needW = Kit.textWidth("small", "Confirm delete") + math.floor(24 * s)
  local toolRows = (cw - 3 * tg) / 4 >= needW and 1 or 2
  local h = 2 * math.floor(18 * s) + Kit.textHeight("title") + math.floor(6 * s)
    + Kit.textHeight("small") + math.floor(16 * s)
    + Kit.textHeight("caption") + math.floor(8 * s)
    + math.max(Kit.tapMin(), math.floor(44 * s))
    + toolRows * smallH + (toolRows - 1) * tg
    + math.max(Kit.tapMin(), math.floor(40 * s)) + math.floor(22 * s)
  if self.selected and self:activeCart(self.selected) then
    h = h + Kit.textHeight("small") + math.floor(4 * s)
  end
  return h
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
    return self:drawFitted("detail:" .. tostring(self.selected), x, y, w, h, s, self.drawGame)
  end
  return self:drawPage(x, y, w, h, s)
end

function Launcher:drawPage(x, y, w, h, s)
  if self.page == "settings" then
    return self:drawFitted("settings", x, y, w, h, s, self.drawSettings)
  end
  if self.page == "notes" then return self:drawNotes(x, y, w, h, s) end
  if self.page == "mods" and self.selected and self.ready[self.selected] then
    return self:drawMods(x, y, w, h, s)
  end
  if self.page == "carts" and self.selected and self.ready[self.selected] then
    return self:drawCarts(x, y, w, h, s)
  end
  return self:drawGame(x, y, w, h, s)
end

-- The chosen game: import, or its saves with Continue / New game.  Returns
-- the height it needs (drawFitted scrolls it on a short window).
function Launcher:drawGame(x, y, w, h, s)
  local v = self.selected
  if not v then return end
  local info = GameVersion.info(v)
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  -- the Carts / Mods buttons share the title's line on an imported game
  local titleW = cw
  if self.ready[v] and not (self.job and self.job.version == v) then
    titleW = cw - Kit.textWidth("small", "Carts") - Kit.textWidth("small", "Mods")
      - math.floor(84 * s)
  end
  Kit.textBold("title", Kit.ellipsize("title", info.displayName, math.max(0, titleW)),
    cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("title") + math.floor(6 * s)
  local status, color = statusText(self, v)
  Kit.text("small", status, cx, cy, color)
  cy = cy + Kit.textHeight("small") + math.floor(16 * s)
  local btnH = math.max(Kit.tapMin(), math.floor(40 * s))

  if self.job and self.job.version == v then
    Kit.text("small", self.job.stage or "Importing", cx, cy, PAL.text)
    cy = cy + Kit.textHeight("small") + math.floor(8 * s)
    Theme.meter(cx, cy, cw, math.floor(10 * s), self.job.progress or 0, PAL.green)
    return cy + math.floor(10 * s) + pad - y
  end

  if not self.ready[v] then
    local help = "Import your own " .. info.displayName .. " ROM to play. "
      .. "It is checked against the original release before anything is "
      .. "written, read once, and never copied."
    Kit.textWrapped("small", help, cx, cy, cw, PAL.muted)
    cy = cy + Kit.wrapHeight("small", help, cw) + math.floor(12 * s)
    if Kit.button(cx, cy, math.min(cw, math.floor(260 * s)), btnH, "Import ROM",
        { id = "import", kind = "accent" }) then
      self:queue(function() self:pickRom() end)
    end
    cy = cy + btnH + math.floor(8 * s)
    Kit.text("micro", "Or drop the .gb / .gbc / .gba file onto this window.",
      cx, cy, PAL.faint)
    return cy + Kit.textHeight("micro") + pad - y
  end

  local slots = self:slotsFor(v)
  local scope = self:scopeKey(v)
  local cartId, cartRow = self:activeCart(v)
  do
    local mh = math.max(Kit.tapMin(), math.floor(32 * s))
    local mw = math.max(Kit.tapMin(), Kit.textWidth("small", "Mods") + math.floor(32 * s))
    local kw = math.max(Kit.tapMin(), Kit.textWidth("small", "Carts") + math.floor(32 * s))
    if Kit.button(cx + cw - mw, y + pad, mw, mh, "Mods", { id = "mods", font = "small" }) then
      self:queue(function() self.page = "mods"; self.modScroll = 0 end)
    end
    if Kit.button(cx + cw - mw - math.floor(8 * s) - kw, y + pad, kw, mh, "Carts",
        { id = "carts", font = "small", active = cartId ~= nil }) then
      self:queue(function() self.page = "carts"; self.cartScroll = 0 end)
    end
  end
  local problem = self:cartProblem(v)
  if cartRow then
    local line = "Playing as " .. tostring(cartRow.title or cartId)
    if problem then line = line .. " - " .. problem end
    Kit.text("small", Kit.ellipsize("small", line, cw), cx, cy - math.floor(8 * s),
      problem and PAL.red or PAL.blue)
    cy = cy + Kit.textHeight("small") + math.floor(4 * s)
  end
  Kit.caption(cx, cy, "SAVES", PAL.caption)
  cy = cy + Kit.textHeight("caption") + math.floor(8 * s)
  local rowH = math.max(Kit.tapMin(), math.floor(44 * s))
  local gap = math.floor(4 * s)
  local smallH = math.max(Kit.tapMin(), math.floor(32 * s))
  -- the four save tools sit in one row, or two when their labels would not fit
  local tg = math.floor(8 * s)
  local needW = Kit.textWidth("small", "Confirm delete") + math.floor(24 * s)
  local toolCols = (cw - 3 * tg) / 4 >= needW and 4 or 2
  local toolRows = 4 / toolCols
  local toolsH = toolRows * smallH + (toolRows - 1) * tg
  local footH = btnH + toolsH + math.floor(22 * s)
  local viewH = y + h - pad - footH - cy
  if viewH < rowH then
    -- a window too short for even one save row: Continue still plays the
    -- chosen save, so the list just steps aside rather than overlap the tools
    local line = "No saves yet - New game starts one"
    for _, sl in ipairs(slots) do
      if sl.id == self.selectedSlot[scope] then
        line = "Save: " .. tostring(sl.label or sl.name or sl.id)
      end
    end
    if viewH >= Kit.textHeight("small") then
      Kit.text("small", Kit.ellipsize("small", line, cw), cx, cy, PAL.muted)
    end
  elseif #slots == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2), "No saves yet")
  else
    local contentH = #slots * (rowH + gap)
    local maxAt = Kit.scrollExtent(contentH, viewH)
    self.slotScroll = Kit.scrollInput(self.slotScroll, maxAt, cx, cy, cw, viewH)
    local py = Kit.scrollBegin(cx, cy, cw, viewH, self.slotScroll, maxAt)
    for i, slot in ipairs(slots) do
      local ry = py + (i - 1) * (rowH + gap)
      local chosen = self.selectedSlot[scope] == slot.id
      local clicked, ink = Kit.row(cx, ry, cw - Kit.scrollGutter(s), rowH, chosen,
        "slot-" .. slot.id)
      local title = slot.label or slot.name or slot.id
      Kit.text("button", title, cx + math.floor(12 * s),
        ry + math.floor(6 * s), ink or PAL.text)
      local meta = slot.meta
      if meta then
        local line = ("%s  -  %d badges  -  %d in Pokedex"):format(
          meta.timeText or "0:00", meta.badges or 0, meta.dexCount or 0)
        Kit.text("micro", line, cx + math.floor(12 * s),
          ry + rowH - Kit.textHeight("micro") - math.floor(6 * s),
          chosen and (ink or PAL.text) or PAL.muted)
      end
      if clicked then
        self:queue(function() self.selectedSlot[scope] = slot.id end)
      end
    end
    Kit.scrollEnd(cx, cy, cw, viewH, self.slotScroll, maxAt, PAL.surface)
  end

  -- save tools: import / export / rename / delete, or the rename field
  local ty = y + h - pad - btnH - math.floor(10 * s) - toolsH
  local chosen = self.selectedSlot[scope]
  local has = chosen ~= nil and #slots > 0
  if self.saveConfirm and self.saveConfirm.version == v then
    local half2 = math.floor((cw - math.floor(10 * s)) / 2)
    if Kit.button(cx, ty, half2, smallH, "Import without them",
        { id = "save-confirm-yes", kind = "primary", font = "small" }) then
      self:queue(function() self:confirmSave(true) end)
    end
    if Kit.button(cx + cw - half2, ty, half2, smallH, "Cancel",
        { id = "save-confirm-no", font = "small" }) then
      self:queue(function() self:confirmSave(false) end)
    end
  elseif self.renaming == chosen and has then
    local okW = math.floor(90 * s)
    local fw = cw - 2 * (okW + math.floor(8 * s))
    self.renameText = Kit.textfield("rename-field", cx, ty, fw, smallH,
      self.renameText, "Save name")
    if Kit.button(cx + fw + math.floor(8 * s), ty, okW, smallH, "Save",
        { id = "rename-ok", kind = "primary", font = "small" }) then
      local text = self.renameText
      self:queue(function() self:renameSave(text) end)
    end
    if Kit.button(cx + cw - okW, ty, okW, smallH, "Cancel",
        { id = "rename-cancel", font = "small" }) then
      self:queue(function() self.renaming = nil end)
    end
  else
    local tools = {
      { id = "save-import", label = "Import .sav", enabled = cartId == nil,
        run = function() self:pickSave() end },
      { id = "save-export", label = "Export", enabled = has and cartId == nil,
        run = function() self:exportSave() end },
      { id = "save-rename", label = "Rename", enabled = has,
        run = function()
          self.renaming = chosen
          local slot
          for _, sl in ipairs(slots) do if sl.id == chosen then slot = sl end end
          self.renameText = slot and (slot.label or slot.name) or ""
          Kit.setFocus("rename-field")
          Kit.focus = "rename-field"
        end },
      { id = "save-delete", label = self.armedDelete == v .. ":" .. tostring(chosen)
          and "Confirm delete" or "Delete", enabled = has, danger = true,
        run = function() self:deleteSave() end },
    }
    local tw = math.floor((cw - (toolCols - 1) * tg) / toolCols)
    for i, t in ipairs(tools) do
      local col, row = (i - 1) % toolCols, math.floor((i - 1) / toolCols)
      if Kit.button(cx + col * (tw + tg), ty + row * (smallH + tg), tw, smallH, t.label,
          { id = t.id, font = "small", enabled = t.enabled,
            kind = t.danger and "danger" or nil }) then
        self:queue(t.run, t.danger)
      end
    end
  end

  local by = y + h - pad - btnH
  local half = math.floor((cw - math.floor(10 * s)) / 2)
  if Kit.button(cx, by, half, btnH, "Continue",
      { id = "continue", kind = "primary",
        enabled = chosen ~= nil and #slots > 0 and not problem and not self:importing() }) then
    self:queue(function() self:play(v, chosen) end)
  end
  local need = self:detailNeed(w, s)
  if Kit.button(cx + cw - half, by, half, btnH, "New game",
      { id = "newgame", kind = "accent", enabled = not problem and not self:importing() }) then
    self:queue(function() self:newGame(v) end)
  end
  return need
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
  if prompt.maxLen and #text > prompt.maxLen then text = text:sub(1, prompt.maxLen) end
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
  Kit.beginFrame(mx, my, click ~= nil, self.wheel or 0)
  self.click, self.wheel = nil, 0
  Theme.field()
  -- a Box popup or prompt owns the frame: nothing under its scrim takes clicks
  local boxModal = self.page == "box" and (self._boxPopup or self._boxPrompt) ~= nil
  Kit.blockClicks = boxModal

  local pad = math.floor(Theme.clamp(W * 0.03, 12, 28))
  local x, w = pad, W - 2 * pad
  local y = pad

  -- header: name, version, quit
  Kit.textBold("headline", Version.NAME or "PK:GB", x, y, PAL.heading)
  local hh = Kit.textHeight("headline")
  local qw = math.max(Kit.tapMin(), math.floor(80 * s))
  local bh = math.max(Kit.tapMin(), math.floor(34 * s))
  local by = y + (hh - Kit.tapMin()) / 2
  if Kit.button(x + w - qw, by, qw, bh, "Quit", { id = "quit" }) then
    self:queue(function() self:quit() end)
  end
  local sw = math.max(Kit.tapMin(), math.floor(110 * s))
  local hgap = math.floor(8 * s)
  local rx = x + w - qw - hgap - sw
  if Kit.button(rx, by, sw, bh,
      self.page == "settings" and "Close" or "Settings",
      { id = "settings", active = self.page == "settings" }) then
    self:queue(function()
      if self.page == "box" then self:closeBox() end
      self.page = self.page ~= "settings" and "settings" or nil
    end)
  end
  local titleRight = x + Kit.textWidth("headline", Version.NAME or "PK:GB") + hgap
  local boxW = math.max(Kit.tapMin(), Kit.textWidth("button", "Close Box") + math.floor(28 * s))
  -- what the header has no room for, Settings offers instead
  self.headerHidden = { box = rx - hgap - boxW < titleRight }
  if rx - hgap - boxW >= titleRight then
    rx = rx - hgap - boxW
    if Kit.button(rx, by, boxW, bh, self.page == "box" and "Close Box" or "Box",
        { id = "box", active = self.page == "box" }) then
      self:queue(function()
        if self.page == "box" then self:closeBox() else self:openBox() end
      end)
    end
  end
  local nw = math.max(Kit.tapMin(), Kit.textWidth("small", "What's new") + math.floor(28 * s))
  self.headerHidden.notes = rx - hgap - nw < titleRight
  if rx - hgap - nw >= titleRight then
    rx = rx - hgap - nw
    if Kit.button(rx, by, nw, bh, self.page == "notes" and "Close" or "What's new",
        { id = "notes", font = "small", active = self.page == "notes" }) then
      self:queue(function()
        if self.page == "box" then self:closeBox() end
        self.page = self.page ~= "notes" and "notes" or nil
        self.notesScroll = 0
      end)
    end
  end
  local upLabel, upAction, upEnabled = self:updateChip()
  if upLabel then
    local uw = Kit.textWidth("small", upLabel) + math.floor(28 * s)
    if rx - hgap - uw >= titleRight then
      if Kit.button(rx - hgap - uw, by, uw, bh, upLabel,
          { id = "update", font = "small", kind = "warn", glow = upEnabled,
            enabled = upEnabled }) and upAction then
        self:queue(upAction)
      end
    end
  end
  y = y + hh + math.floor(14 * s)

  local footH = self:footerHeight(w) + math.floor(12 * s)
  if self.message then footH = footH + Kit.textHeight("small") * 2 + math.floor(8 * s) end
  local bodyH = H - y - pad - footH

  -- side by side on a wide window, and on a landscape phone too: stacking
  -- there leaves neither half tall enough to use
  local wide = w >= 700 * s or (w >= 520 and w >= H * 1.3)
  if self.page == "box" then
    self:drawBox(x, y, w, bodyH, s)
  elseif self.page and not wide then
    -- stacked, a page (settings, mods, carts, notes) takes the whole body;
    -- its Back / Close goes back to the game list
    self:drawDetail(x, y, w, bodyH, s)
  elseif wide then
    local listW = math.floor(math.min(320 * s, w * 0.34))
    self:drawGameList(x, y, listW, bodyH, s)
    self:drawDetail(x + listW + math.floor(16 * s), y, w - listW - math.floor(16 * s), bodyH, s)
  else
    -- the game list yields height to the detail panel down to two rows
    local listMin = Kit.textHeight("caption") + math.floor(110 * s)
    local listH = math.floor(math.max(listMin,
      math.min(bodyH * 0.42, bodyH - math.floor(10 * s) - self:detailNeed(w, s))))
    self:drawGameList(x, y, w, listH, s)
    self:drawDetail(x, y + listH + math.floor(10 * s), w, bodyH - listH - math.floor(10 * s), s)
  end

  local fy = H - pad - self:footerHeight(w)
  if self.message then
    local color = self.message.kind == "error" and PAL.red or PAL.text
    Kit.textWrapped("small", self.message.text, x, fy - Kit.textHeight("small") * 2
      - math.floor(8 * s), w, color, 2)
  end
  self:drawFooter(x, fy, w, s)
  if self.page == "box" then
    Kit.blockClicks = false
    self:drawBoxOverlays(s)
  end
  Kit.endFrame()
end

return Launcher
