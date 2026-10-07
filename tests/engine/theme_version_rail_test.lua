-- Theme.versionRail: `x % 1` is exactly 1.0 for a tiny negative x, which put
-- the colour index one past the end and crashed the launcher (seen first in
-- the browser build, where love.timer values differ; latent everywhere).
--   luajit tests/engine/theme_version_rail_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")

local fills = 0
local savedGraphics, savedTimer = love.graphics, love.timer
love.graphics = setmetatable({
  setColor = function() end,
  rectangle = function() fills = fills + 1 end,
}, { __index = savedGraphics })
-- phase = now / 24 lands a hair past 1/7, so for px = 1, w = 7:
-- px / w - phase is a tiny negative and (that % 1) == 1.0
local NOW = 3.4285714285714293
love.timer = { getTime = function() return NOW end }
check(((1 / 7 - (NOW % 24) / 24) % 1) == 1, "the test hits the % 1 == 1.0 edge")

package.loaded["src.ui.kit.Theme"] = nil
local Theme = require("src.ui.kit.Theme")
local colors = { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 } }
local ok, err = pcall(Theme.versionRail, 0, 0, 7, 2, colors)
check(ok, "versionRail survives the wrap edge: " .. tostring(err))
eq(fills, 7, "one strip per pixel column")

love.graphics, love.timer = savedGraphics, savedTimer
T.finish()
