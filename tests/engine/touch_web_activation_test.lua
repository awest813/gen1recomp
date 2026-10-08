-- Phone browsers report love.system.getOS() == "Web", not Android/iOS, so the
-- touch overlay starts off in the browser build and the first real touch
-- turns it on (desktop browsers never send touches).
--   luajit tests/engine/touch_web_activation_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local T = require("tests.harness")
local check, eq = T.check, T.eq

local savedGetOS = love.system.getOS
local osName = "Web"
love.system.getOS = function() return osName end

local TouchControls = require("src.core.TouchControls")

TouchControls:init()
eq(TouchControls.active, false, "web starts with the overlay off")
TouchControls:touchpressed("f1", 10, 10)
eq(TouchControls.active, true, "the first touch turns it on")
check(TouchControls.img ~= nil or require("src.core.TouchSkin").active ~= nil,
  "and loads its art")
TouchControls:touchreleased("f1", 10, 10)

-- a player who switched the overlay off keeps it off
TouchControls:init()
TouchControls.enabled = false
TouchControls:touchpressed("f2", 10, 10)
eq(TouchControls.active, false, "a disabled overlay stays off on touch")
TouchControls.enabled = true

-- desktop never self-activates on a touch event
osName = "Linux"
TouchControls:init()
TouchControls:touchpressed("f3", 10, 10)
eq(TouchControls.active, false, "desktop does not self-activate")

love.system.getOS = savedGetOS
T.finish()
