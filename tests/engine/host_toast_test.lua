-- The host's own keys say what they did: quick save, game speed and zoom
-- changed things with nothing on screen to show for it (F1, 1/0, 4 and the
-- touch key bar's SAVE / SPEED / ZOOM).
--   luajit tests/engine/host_toast_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local eq = T.eq

local HostToast = require("src.ui.HostToast")
HostToast.say("SAVED")
eq(HostToast.text(), "SAVED", "a notice is held")
local ok = pcall(HostToast.draw)
T.check(ok, "and draws without error")

-- Gold: the SPEED key / shoulder names the new speed
local Game2 = require("src.core.Game2")
local fake = setmetatable({ options = { speed = 1 }, speedLocked = function() return false end,
  persistOptions = function() end }, { __index = Game2 })
Game2._cycleSpeed(fake, 1)
eq(HostToast.text(), "SPEED 2X", "Gold's speed up says SPEED 2X")
Game2._cycleSpeed(fake, -1)
eq(HostToast.text(), "SPEED NORMAL", "and back down, SPEED NORMAL")

-- FireRed: the same through its own speed path
local Game3 = require("src.core.Game3")
local g3 = setmetatable({ options = {}, speedLocked = function() return false end,
  speedCategory = function() return "overworld" end, writeOptions = function() end }, { __index = Game3 })
Game3._cycleSpeed(g3, 1)
eq(HostToast.text(), "SPEED 2X", "FireRed's speed up says SPEED 2X")

T.finish("host toast")
