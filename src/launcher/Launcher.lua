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
    listScroll = 0,
    slotScroll = 0,
  }, Launcher)
  self:refresh()
  local first
  for _, v in ipairs(self.games) do
    if self.ready[v] then first = first or v end
  end
  self.selected = (opts.initialGame and self.ready[opts.initialGame]
    and opts.initialGame) or first or self.games[1]
  -- ask the self-updater (src/update/Check.lua) whether a release is out;
  -- it works on a worker thread and is a no-op where it cannot run
  if not opts.noUpdateCheck then
    local okC, Check = pcall(require, "src.update.Check")
    if okC then pcall(Check.start) end
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

function Launcher:slotsFor(version)
  local list = self.slots[version]
  if list then return list end
  local ok, SaveData = pcall(require, "src.core.SaveData")
  list = {}
  if ok then
    local okL, got = pcall(SaveData.listSlots, version)
    if okL and type(got) == "table" then
      for _, s in ipairs(got) do
        if s.exists then list[#list + 1] = s end
      end
    end
  end
  self.slots[version] = list
  if not self.selectedSlot[version] and list[1] then
    local okA, active = pcall(SaveData.activeSlot, version)
    self.selectedSlot[version] = okA and active or list[1].id
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

function Launcher:requestHostPick(kind)
  local sys = hostPicker()
  if not sys then return false end
  local ok, started = pcall(sys.pickFile, kind)
  if not ok or started == false then
    self:say("The file picker could not open.", "error")
    return true
  end
  self.pendingPick = kind
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
      self:importSave(path, name)
      pcall(os.remove, path)
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
    self:say(err, "error")
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
  self.modRows = nil
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
  self.modRows = nil
  if not (ok and done) then
    return self:say("Could not remove " .. tostring(row.name) .. ": "
      .. tostring(ok and err or done), "error")
  end
  self:say(tostring(row.name) .. " was removed.", "info")
end

function Launcher:installMod(data, name)
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, manifest, err = pcall(ModLibrary.installZip, data, name)
  if not ok then manifest, err = nil, manifest end
  self.modRows = nil
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

function Launcher:play(version, slotId)
  local SaveData = require("src.core.SaveData")
  if slotId then
    SaveData.setActiveSlot(version, slotId)
  end
  self.launched = version
  if self.onLaunch then self.onLaunch(version, nil, {}) end
end

function Launcher:newGame(version)
  local SaveData = require("src.core.SaveData")
  local id = SaveData.createSlot(version)
  if not id then return self:say("Could not create a save slot.", "error") end
  self:play(version, id)
end

-- ------------------------------------------------------------ save files

local SAVE_KIND = { label = "Save file", exts = { "sav", "srm", "sa1", "dsv", "sgm" } }

function Launcher:selectedSaveId(version)
  return self.selectedSlot[version or self.selected]
end

-- `source` is a dropped LÖVE file, an absolute path, or raw bytes.
function Launcher:importSave(source, name)
  local v = self.selected
  if not (v and self.ready[v]) then
    return self:say("Import the game's ROM before importing a save for it.", "error")
  end
  local SaveFileIO = require("src.import.SaveFileIO")
  local ok, result = SaveFileIO.importToSlot(source, v)
  self.slots[v] = nil
  if not ok then return self:say("Save import failed: " .. tostring(result), "error") end
  local SaveData = require("src.core.SaveData")
  local okA, active = pcall(SaveData.activeSlot, v)
  if okA and active then self.selectedSlot[v] = active end
  self:say((name and (name .. " ") or "The save ") .. "was imported as a new save.", "info")
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
  local SaveData = require("src.core.SaveData")
  local ok, err = SaveData.deleteSlot(v, id)
  self.slots[v], self.selectedSlot[v] = nil, nil
  if ok == false then return self:say("Could not delete: " .. tostring(err), "error") end
  self:say("Save deleted.", "info")
end

function Launcher:renameSave(name)
  local v, id = self.selected, self:selectedSaveId()
  self.renaming = nil
  if not (v and id) then return end
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local SaveData = require("src.core.SaveData")
  local ok, err = SaveData.renameSlot(v, id, name ~= "" and name or nil)
  self.slots[v] = nil
  if ok == false then return self:say("Could not rename: " .. tostring(err), "error") end
end

-- --------------------------------------------------------------- settings

-- The options this launcher edits, read and written through SaveData so the
-- game sees exactly what was chosen.
function Launcher:options()
  if not self.opts_ then
    local ok, SaveData = pcall(require, "src.core.SaveData")
    local okL, opts = false, nil
    if ok then okL, opts = pcall(SaveData.loadOptions) end
    self.opts_ = (okL and type(opts) == "table") and opts or {}
  end
  return self.opts_
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
  self:pollHostPick()
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

function Launcher:mousepressed(x, y, button)
  if button == 1 or button == nil then self.pressAt = { x = x, y = y } end
end

function Launcher:mousereleased(x, y, button)
  if (button == 1 or button == nil) and self.pressAt then
    self.click = { x = x, y = y }
    self.pressAt = nil
  end
end

function Launcher:mousemoved() end
function Launcher:touchpressed(_, x, y) self.pressAt = { x = x, y = y } end
function Launcher:touchmoved() end
function Launcher:touchreleased(_, x, y)
  if self.pressAt then self.click = { x = x, y = y } end
  self.pressAt = nil
end

function Launcher:wheelmoved(_, dy) self.wheel = (self.wheel or 0) + dy end

function Launcher:keypressed(key)
  if Kit.keypressed(key) then return true end
  if key == "escape" and self.renaming then
    self:queue(function() self.renaming = nil end)
    return true
  end
  return false
end

function Launcher:gamepadpressed(_, button)
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
function Launcher:textinput(text) return Kit.textinput(text) end

local SAVE_EXTS = { sav = true, srm = true, sa1 = true, dsv = true, sgm = true }

local function isSaveName(name)
  local ext = tostring(name or ""):lower():match("%.([%w]+)$")
  return ext ~= nil and SAVE_EXTS[ext] == true
end
Launcher.isSaveName = isSaveName

function Launcher:filedropped(file)
  local fname = file.getFilename and file:getFilename() or ""
  if isSaveName(fname) then
    return self:importSave(file, fname:match("[^/\\]+$") or fname)
  end
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
function Launcher:focus() self:refresh() self.modRows = nil end
function Launcher:savesChanged() self.slots = {} end
function Launcher:resumeAfterOverlay() self:refresh() end
function Launcher:prepareOverlayHandoff() end
function Launcher:ignoreReturningPointer() self.pressAt, self.click = nil, nil end
function Launcher:autoUpdateAll() end

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
    Kit.text("button", info.displayName, x + math.floor(12 * s),
      ry + (rowH - Kit.textHeight("button")) / 2, ink or PAL.text)
    local status, color = statusText(self, v)
    local sw = Kit.textWidth("micro", status)
    Kit.text("micro", status, x + w - Kit.scrollGutter(s) - sw - math.floor(12 * s),
      ry + (rowH - Kit.textHeight("micro")) / 2,
      self.selected == v and (ink or PAL.text) or color)
    if clicked then
      self:queue(function() self.selected = v; self.page = nil; self:say(nil) end)
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
  -- this launcher is opt-in for now (--ui=new); offer the way back
  label("Launcher", cy)
  local classic = opts.launcherUi == "classic"
  local lw = math.floor(math.min(cw * 0.5, 300 * s))
  if Kit.button(cx + cw - lw, cy, lw, rowH, classic and "Keep this one" or "Use classic",
      { id = "launcher-ui", font = "small" }) then
    self:queue(function()
      self:setOption("launcherUi", classic and "new" or "classic")
      self:say(classic and "This launcher stays." or
        "The classic launcher opens the next time PK:GB starts.", "info")
    end)
  end
  cy = cy + rowH + math.floor(10 * s)
  Kit.textWrapped("micro", "More options (colors, zoom, speed, controls) are in "
    .. "the game's own OPTIONS menu.", cx, cy, cw, PAL.faint)
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

function Launcher:drawDetail(x, y, w, h, s)
  if self.page == "settings" then return self:drawSettings(x, y, w, h, s) end
  if self.page == "notes" then return self:drawNotes(x, y, w, h, s) end
  if self.page == "mods" and self.selected and self.ready[self.selected] then
    return self:drawMods(x, y, w, h, s)
  end
  local v = self.selected
  if not v then return end
  local info = GameVersion.info(v)
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  Kit.textBold("title", info.displayName, cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("title") + math.floor(6 * s)
  local status, color = statusText(self, v)
  Kit.text("small", status, cx, cy, color)
  cy = cy + Kit.textHeight("small") + math.floor(16 * s)
  local btnH = math.max(Kit.tapMin(), math.floor(40 * s))

  if self.job and self.job.version == v then
    Kit.text("small", self.job.stage or "Importing", cx, cy, PAL.text)
    cy = cy + Kit.textHeight("small") + math.floor(8 * s)
    Theme.meter(cx, cy, cw, math.floor(10 * s), self.job.progress or 0, PAL.green)
    return
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
    return
  end

  local slots = self:slotsFor(v)
  do
    local mw = math.max(Kit.tapMin(), Kit.textWidth("small", "Mods") + math.floor(32 * s))
    local mh = math.max(Kit.tapMin(), math.floor(32 * s))
    if Kit.button(cx + cw - mw, y + pad, mw, mh, "Mods", { id = "mods", font = "small" }) then
      self:queue(function() self.page = "mods"; self.modScroll = 0 end)
    end
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
  local viewH = math.max(rowH, y + h - pad - footH - cy)
  if #slots == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2), "No saves yet")
  else
    local contentH = #slots * (rowH + gap)
    local maxAt = Kit.scrollExtent(contentH, viewH)
    self.slotScroll = Kit.scrollInput(self.slotScroll, maxAt, cx, cy, cw, viewH)
    local py = Kit.scrollBegin(cx, cy, cw, viewH, self.slotScroll, maxAt)
    for i, slot in ipairs(slots) do
      local ry = py + (i - 1) * (rowH + gap)
      local chosen = self.selectedSlot[v] == slot.id
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
        self:queue(function() self.selectedSlot[v] = slot.id end)
      end
    end
    Kit.scrollEnd(cx, cy, cw, viewH, self.slotScroll, maxAt, PAL.surface)
  end

  -- save tools: import / export / rename / delete, or the rename field
  local ty = y + h - pad - btnH - math.floor(10 * s) - toolsH
  local chosen = self.selectedSlot[v]
  local has = chosen ~= nil and #slots > 0
  if self.renaming == chosen and has then
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
      { id = "save-import", label = "Import .sav", enabled = true,
        run = function() self:pickSave() end },
      { id = "save-export", label = "Export", enabled = has,
        run = function() self:exportSave() end },
      { id = "save-rename", label = "Rename", enabled = has,
        run = function()
          self.renaming = chosen
          local slot
          for _, sl in ipairs(slots) do if sl.id == chosen then slot = sl end end
          self.renameText = slot and (slot.label or slot.name) or ""
          Kit.setFocus("rename-field")
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
      { id = "continue", kind = "primary", enabled = chosen ~= nil and #slots > 0 }) then
    self:queue(function() self:play(v, chosen) end)
  end
  if Kit.button(cx + cw - half, by, half, btnH, "New game",
      { id = "newgame", kind = "accent" }) then
    self:queue(function() self:newGame(v) end)
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
      self.page = self.page ~= "settings" and "settings" or nil
    end)
  end
  local nw = math.max(Kit.tapMin(), Kit.textWidth("small", "What's new") + math.floor(28 * s))
  local titleRight = x + Kit.textWidth("headline", Version.NAME or "PK:GB") + hgap
  if rx - hgap - nw >= titleRight then
    rx = rx - hgap - nw
    if Kit.button(rx, by, nw, bh, self.page == "notes" and "Close" or "What's new",
        { id = "notes", font = "small", active = self.page == "notes" }) then
      self:queue(function()
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

  local wide = w >= 700 * s
  if wide then
    local listW = math.floor(math.min(320 * s, w * 0.34))
    self:drawGameList(x, y, listW, bodyH, s)
    self:drawDetail(x + listW + math.floor(16 * s), y, w - listW - math.floor(16 * s), bodyH, s)
  else
    local listH = math.floor(bodyH * 0.42)
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
  Kit.endFrame()
end

return Launcher
