package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")
local T = require("tests.harness")
local Kit = require("src.ui.kit.Kit")
local Prompt = require("src.import.BoxPrompt")
local Tools = require("src.import.BoxTools")
local Launcher = require("src.launcher.Launcher")
local Transition = require("src.ui.kit.Transition")
local Store = require("src.box.Store")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end
love.graphics.newShader = love.graphics.newShader or function() return {} end

local function window(w, h)
  love.graphics.getDimensions = function() return w, h end
  love.graphics.getPixelDimensions = function() return w, h end
end
-- the launcher hosts the Box: prompt text reaches the prompt through its
-- field on the next frame, and Enter / Escape run on the next update
local function frame(imp) Transition.clear(); imp:draw(); imp:update(0) end
local function typeText(imp, text) imp:textinput(text); frame(imp) end
local function press(imp, key) imp:keypressed(key); frame(imp) end

window(1360, 860)
local imp = Launcher.new(function() end, { noUpdateCheck = true })
imp:openBox()
local saved
local s = { service = { state = Store.new(), preset = function(_, name, refs)
  saved = { name = name, refs = refs }; return true
end }, selectedBox = { ["1:1"] = { box = 1, slot = 1 } }, toolsOpen = true, toolsPage = "Teams" }
local controls = {}
Kit.layout(1360, 860)
Tools.draw(imp, s, 0, 0, 1000, { s = 1, btnH = 38 }, {
  button = function(_, _, _, _, _, id, _, action) controls[id] = action end,
  selected = function() return { { box = 1, slot = 1 } } end,
  perform = function(_, fn) return fn() end,
})
controls["tools-save-team"]()
T.check(imp._boxPrompt ~= nil, "desktop team button opens a visible text modal")
T.eq(Kit.VirtualKeyboard.active, false, "desktop does not depend on handheld keyboard")
typeText(imp, "Starter team")
press(imp, "return")
T.eq(saved and saved.name, "Starter team", "physical keyboard saves the team name through its UI action")
T.same(saved and saved.refs, { { box = 1, slot = 1 } }, "named team keeps the selected record references")
T.eq(imp._boxPrompt, nil, "confirmed prompt closes")
press(imp, "return")
T.eq(saved and saved.name, "Starter team", "closed prompt cannot repeat its callback")

local result, calls = nil, 0
local function callback(value) result = value; calls = calls + 1 end
Prompt.open(imp, "Local tags", "", 3, callback)
typeText(imp, "éABCD")
T.eq(imp._boxPrompt.text, "éAB", "prompt cap counts UTF-8 characters")
press(imp, "backspace")
T.eq(imp._boxPrompt.text, "éA", "backspace removes one complete character")
press(imp, "backspace"); press(imp, "backspace")
T.eq(imp._boxPrompt.text, "", "backspace removes accented character without leaving invalid bytes")
typeText(imp, "tag")
press(imp, "escape")
T.eq(calls, 0, "Escape cancels without applying tags")
T.eq(imp._boxPrompt, nil, "Escape removes the modal")

Prompt.open(imp, "Stage name", "Garden", 64, callback)
imp._boxState = { service = { state = Store.new() }, sources = {}, sourceIndex = 1,
  box = 1, pcBox = 1, query = "", sort = "slot", pcRows = {}, selectedBox = {}, selectedPC = {} }
for _, size in ipairs({ { 390, 844 }, { 1360, 860 } }) do
  window(size[1], size[2])
  T.check(pcall(imp.draw, imp), "naming modal renders at " .. size[1] .. " pixel width")
  T.check(imp.message == nil or imp.message.kind ~= "error",
    "and the Box draws without an error at " .. size[1] .. ": " .. tostring(imp.message and imp.message.text))
end
-- a click on the header's Settings button under the prompt's scrim is not taken
local settingsRect
local realButton = Kit.button
Kit.button = function(x, y, w, h, label, opts)
  if opts and opts.id == "settings" then settingsRect = { x = x, y = y, w = w, h = h } end
  return realButton(x, y, w, h, label, opts)
end
frame(imp)
Kit.button = realButton
T.check(settingsRect ~= nil, "the header draws under the prompt")
if settingsRect then
  imp.click = { x = settingsRect.x + settingsRect.w / 2, y = settingsRect.y + settingsRect.h / 2 }
  frame(imp)
end
T.eq(imp.page, "box", "prompt shields underlying launcher controls")
T.check(imp._boxPrompt ~= nil, "and stays open")
T.eq(calls, 0, "a shielded click does not touch the prompt")
-- the shielded click blurred the field; the player taps back into it
imp:_armTextInput()
frame(imp)
Transition.clear()
imp:gamepadpressed(nil, "b"); frame(imp)
T.eq(imp._boxPrompt, nil, "controller B cancels the prompt")
T.eq(calls, 0, "controller cancellation leaves the stage unchanged")
Prompt.open(imp, "Box name", "Names", 32, callback)
Prompt.close(imp, true)
T.eq(result, "Names", "modal Save uses the same confirmation callback")
T.eq(calls, 1, "Save invokes the callback once")
Prompt.open(imp, "Box name", "Discard", 32, callback)
imp:closeBox()
T.eq(imp._boxPrompt, nil, "leaving Box cancels a pending name edit")
T.eq(calls, 1, "leaving Box cannot commit an edit")
T.finish()
