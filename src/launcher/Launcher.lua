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

function Launcher:queue(fn)
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

function Launcher:pickRom()
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

function Launcher:quit()
  local okP, Platform = pcall(require, "src.core.Platform")
  if okP and Platform.systemQuit and Platform.systemQuit() then return end
  love.event.quit()
end

-- ------------------------------------------------------------- host hooks

function Launcher:update(dt)
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

local NAV = { up = "up", down = "down", left = "left", right = "right",
  dpup = "up", dpdown = "down", dpleft = "left", dpright = "right" }

function Launcher:keypressed(key)
  if NAV[key] then Kit.navigate(NAV[key]) return true end
  if key == "return" or key == "kpenter" or key == "space" then
    Kit.activateFocused()
    return true
  end
  if key == "escape" then self:queue(function() self:quit() end) return true end
  return false
end

function Launcher:gamepadpressed(_, button)
  if NAV[button] then Kit.navigate(NAV[button]) return true end
  if button == "a" or button == "start" then Kit.activateFocused() return true end
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
function Launcher:textinput() end

function Launcher:filedropped(file)
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
function Launcher:focus() self:refresh() end
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
      self:queue(function() self.selected = v; self:say(nil) end)
    end
  end
  Kit.scrollEnd(x, top, w, viewH, self.listScroll, maxAt)
end

function Launcher:drawDetail(x, y, w, h, s)
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
  Kit.caption(cx, cy, "SAVES", PAL.caption)
  cy = cy + Kit.textHeight("caption") + math.floor(8 * s)
  local rowH = math.max(Kit.tapMin(), math.floor(44 * s))
  local gap = math.floor(4 * s)
  local footH = btnH + math.floor(12 * s)
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

  local by = y + h - pad - btnH
  local half = math.floor((cw - math.floor(10 * s)) / 2)
  local chosen = self.selectedSlot[v]
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
  if Kit.button(x + w - qw, y + (hh - Kit.tapMin()) / 2, qw,
      math.max(Kit.tapMin(), math.floor(34 * s)), "Quit", { id = "quit" }) then
    self:queue(function() self:quit() end)
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
