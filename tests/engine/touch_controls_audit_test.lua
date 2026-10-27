-- Touch controls, the controls audit: Gold's layout editor reads and writes
-- the shared touchControls Gold draws from; a re-init under a finger (the
-- in-game TOUCH LAYOUT row opens on the press) releases that button; a
-- custom skin's hotkey buttons reach Gold and never a finished session; and
-- FireRed's key bar leaves out COLOR, which it has no hotkey for.
--   luajit tests/engine/touch_controls_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq
local Input = require("src.core.Input")
local TC = require("src.core.TouchControls")
local SaveData = require("src.core.SaveData")
local GV = require("src.core.GameVersion")

-- ---- Gold's editor works on the touchControls Gold loads
do
  SaveData.saveOptions(SaveData.defaultOptions())
  local Editor = require("src.ui.TouchControlsEditor")
  local gold
  for v in pairs(GV.VERSIONS) do if GV.generation(v) == 2 then gold = v end end
  Editor.load({ version = gold })
  TC:setControlCenter("a", 10, 10)
  Editor.keypressed("escape") -- Done
  local file = SaveData.loadOptions()
  eq(file.gold and file.gold.touchControls, nil, "no copy is left in Gold's block")
  local loaded = require("src.core.gen2.Save").loadOptions().touchControls
  local layout = loaded and loaded.layouts and loaded.layouts[TC.orientation]
  check(layout and layout.positions and layout.positions.a ~= nil, "Gold loads the moved A")
  Editor.load({ version = gold })
  local a = TC:config().layouts[TC.orientation].positions
  check(a and a.a ~= nil, "and reopening the editor shows it where it was put")
  Editor.keypressed("escape")
end

-- ---- a re-init under a held finger lets go of the button
do
  Input:init(false)
  TC:init(); TC.active = true; TC.img = {}
  TC:applyOptions({ generation = 2 })
  local L = TC:layout()
  TC:touchpressed(7, L.a.cx, L.a.cy)
  Input:step()
  check(Input:isDown("a"), "the overlay A is down")
  TC:init()
  Input:step()
  check(not Input:isDown("a"), "init releases it")
  TC.active = true; TC.img = {}
  TC:applyOptions({ generation = 2 })
  L = TC:layout()
  TC:touchpressed(8, L.a.cx, L.a.cy)
  Input:step()
  check(Input:wasPressed("a"), "so the next tap on A is a press")
  TC:touchreleased(8, L.a.cx, L.a.cy)
end

-- ---- skin hotkeys: init forgets the last game's handler; Gold has one
do
  local calls = 0
  TC:setHotkeyHandler(function() calls = calls + 1 end)
  TC:init()
  eq(TC.hotkeyHandler, nil, "a new session starts without the old session's handler")
  local Game2 = require("src.core.Game2")
  local g = setmetatable({ speedOverride = nil }, { __index = Game2 })
  Game2.touchSkinHotkey(g, "fast_forward_hold", true)
  eq(g.speedOverride, Game2.SKIN_FAST_FORWARD, "Gold fast-forwards while the skin button is held")
  Game2.touchSkinHotkey(g, "fast_forward_hold", false)
  eq(g.speedOverride, nil, "and stops when it is let go")
end

-- ---- FireRed's key bar has no COLOR
do
  TC:init()
  TC:applyOptions({ generation = 3 })
  local labels = {}
  for _, ctl in ipairs(TC:hotbarItems()) do labels[ctl.label] = true end
  check(labels.SAVE and labels.SPEED, "FireRed's key bar has SAVE and SPEED")
  check(not labels.COLOR, "but not COLOR, which does nothing there")
  TC:applyOptions({ generation = 1 })
  labels = {}
  for _, ctl in ipairs(TC:hotbarItems()) do labels[ctl.label] = true end
  check(labels.COLOR, "Red keeps COLOR")
end

-- ---- Arrange will not drop one button on top of another
do
  local Editor = require("src.ui.TouchControlsEditor")
  love.mouse = love.mouse or {}
  love.mouse.isDown = love.mouse.isDown or function() return true end
  Editor.load({ version = "gold" })
  local L = TC:layout()
  local sx, sy = L.start.cx, L.start.cy
  local ax, ay = L.a.cx, L.a.cy
  Editor.mousepressed(sx, sy, 1)
  Editor.mousemoved(ax, ay)
  Editor.mousereleased(ax, ay, 1)
  L = TC:layout()
  check(math.abs(L.start.cx - sx) < 1 and math.abs(L.start.cy - sy) < 1, "START dropped on A goes back")
  check(Editor.exportMsg and Editor.exportMsg:find("cover another button", 1, true), "and the editor says why")
  -- a clear spot is fine
  local W, H = love.graphics.getDimensions()
  Editor.mousepressed(L.start.cx, L.start.cy, 1)
  Editor.mousemoved(W * 0.5, H * 0.55)
  Editor.mousereleased(W * 0.5, H * 0.55, 1)
  L = TC:layout()
  check(math.abs(L.start.cx - W * 0.5) < 2, "a drop in open space stays")
  Editor.keypressed("escape")
end

T.finish("touch controls audit")
