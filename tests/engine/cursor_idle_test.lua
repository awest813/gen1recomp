-- The mouse pointer hides during play once it sits still, and comes back on
-- any motion or click; outside a game it is always shown.
--   luajit tests/engine/cursor_idle_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local check = T.check

local shown = true
love.mouse = love.mouse or {}
love.mouse.setVisible = function(on) shown = on end
local CursorIdle = require("src.core.CursorIdle")

CursorIdle.update(1, true)
check(shown, "still shown after a second of play")
CursorIdle.update(2, true)
check(not shown, "hidden once it has sat still")
CursorIdle.moved()
check(shown, "back the moment the mouse moves")
CursorIdle.update(3, true)
check(not shown, "and hidden again after another pause")
CursorIdle.update(0.1, false)
check(shown, "shown whenever no game owns the window (the launcher)")
CursorIdle.update(10, false)
check(shown, "and it stays shown there")
T.finish("cursor idle")
