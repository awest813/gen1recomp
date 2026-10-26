-- Launcher navigation chrome (src/import/LauncherNav.lua).  No pokered cite:
-- the launcher is port-only chrome.
--
-- Pins the two shapes the nav takes and what each must offer:
--   * a wide window gets the RAIL: every visible cartridge plus every tool
--     as its own row, Save Sync / settings / quit, and a page column beside
--     it that still lays out two columns at the default 1024x768 window;
--   * a phone gets the BARS: the top cluster plus a bottom bar holding the
--     game slot and every tool, all inside the window;
--   * a click on a rail row switches to that page, and the game slot opens
--     the picker when its game is already open;
--   * Ctrl+Tab / Ctrl+Shift+Tab walk the same order the pad shoulders do.
--   luajit tests/engine/launcher_nav_rail_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end
love.graphics.newShader = love.graphics.newShader or function() return {} end

local Kit = require("src.ui.kit.Kit")
local Transition = require("src.ui.kit.Transition")
local RomImporter = require("src.import.RomImporter")
local LauncherView = require("src.import.LauncherView")

local function window(w, h)
  love.graphics.getDimensions = function() return w, h end
  love.graphics.getPixelDimensions = function() return w, h end
end

local realButton, realTime = Kit.button, love.timer.getTime
local now = realTime() + 1
love.timer.getTime = function() return now end
local controls = {}
Kit.button = function(x, y, w, h, label, opts)
  if opts and opts.id then
    controls[opts.id] = { x = x, y = y, w = w, h = h, active = not not opts.active }
  end
  return realButton(x, y, w, h, label, opts)
end

local function draw(imp, click)
  now = now + 0.5
  Transition.clear()
  controls = {}
  imp._clickPt = click and { x = click.x + click.w / 2, y = click.y + click.h / 2 } or nil
  LauncherView.draw(imp)
  local actions = imp._uiActions
  imp._uiActions = {}
  if actions and #actions > 0 then imp:runActions(actions) end
end

local function click(imp, id)
  local r = assert(controls[id], "control drawn: " .. id)
  draw(imp, r)
  draw(imp)
end

local function inside(r, W, H)
  return r.x >= -0.5 and r.y >= -0.5 and r.x + r.w <= W + 0.5 and r.y + r.h <= H + 0.5
end

local function fresh()
  return RomImporter.new(function() end, { launcher = true })
end

-- ------------------------------------------------------------ the rail
for _, size in ipairs({ { 1024, 768 }, { 1280, 720 }, { 1920, 1080 } }) do
  local W, H = size[1], size[2]
  window(W, H)
  local imp = fresh()
  draw(imp)
  local tag = ("%dx%d"):format(W, H)
  eq(imp._navL.mode, "rail", tag .. ": a wide window gets the rail")
  for _, g in ipairs(LauncherView.gameTabs(imp)) do
    check(controls[g.key] ~= nil, tag .. ": the library lists " .. g.id)
  end
  for _, t in ipairs(LauncherView.HEADER_TABS) do
    local r = controls[t.key]
    check(r ~= nil and inside(r, W, H), tag .. ": the rail shows tool " .. t.id)
  end
  for _, id in ipairs({ "gear", "tab-sync", "quit" }) do
    local r = controls[id]
    check(r ~= nil and inside(r, W, H) and r.x < imp._navL.railRight,
      tag .. ": " .. id .. " rides the rail")
  end
  check(controls["tab-game"] == nil, tag .. ": no bottom bar beside the rail")
  check(controls["tab-red"].active, tag .. ": the open game's row is selected")
  local page = imp._navL.page
  check(page.x >= imp._navL.railRight, tag .. ": the page column starts past the rail")
  check(page.twoCol, tag .. ": the page keeps two columns beside the rail")
  check(imp._tabRegionRect.x >= imp._navL.railRight,
    tag .. ": the tab scroller sits in the page column")
end

window(1280, 720)
local imp = fresh()
draw(imp)
click(imp, "tab-blue")
eq(imp.tab, "blue", "a library row opens its game")
check(controls["tab-blue"].active and not controls["tab-red"].active,
  "and the selection follows it")
click(imp, "tab-mods")
eq(imp.tab, "mods", "a tools row opens its page")
check(controls["tab-mods"].active, "and is marked selected")

-- ------------------------------------------------------------- the bars
for _, size in ipairs({ { 360, 640 }, { 390, 844 }, { 600, 900 } }) do
  local W, H = size[1], size[2]
  window(W, H)
  local phone = fresh()
  draw(phone)
  local tag = ("%dx%d"):format(W, H)
  eq(phone._navL.mode, "bar", tag .. ": a narrow window gets the bars")
  local game = controls["tab-game"]
  check(game ~= nil and inside(game, W, H) and game.y > H / 2,
    tag .. ": the game slot sits in the bottom bar")
  for _, t in ipairs(LauncherView.HEADER_TABS) do
    local r = controls[t.key]
    check(r ~= nil and inside(r, W, H) and r.y > H / 2,
      tag .. ": the bottom bar shows " .. t.id)
  end
  for _, id in ipairs({ "gear", "tab-sync", "quit" }) do
    local r = controls[id]
    check(r ~= nil and inside(r, W, H) and r.y < H / 4,
      tag .. ": " .. id .. " rides the top bar")
  end
  check(controls["tab-blue"] == nil, tag .. ": no library rows without the rail")
  check(phone._tabRegionRect.y + phone._tabRegionRect.h <= game.y,
    tag .. ": the page stops above the bottom bar")
end

window(390, 844)
local phone = fresh()
draw(phone)
click(phone, "tab-online")
eq(phone.tab, "online", "a bottom-bar tool opens its page")
click(phone, "tab-game")
eq(phone.tab, "red", "the game slot returns to the open game")
eq(phone._gamePopup, nil, "without opening the picker")
click(phone, "tab-game")
eq(phone._gamePopup, true, "a second tap on its own page opens the picker")
draw(phone)
click(phone, "gamepop-blue")
eq(phone.tab, "blue", "a picker row switches game")
eq(phone._gamePopup, nil, "and closes the picker")

-- ------------------------------------------------------------- keyboard
window(1280, 720)
local kb = fresh()
draw(kb)
local held = {}
local realIsDown = love.keyboard.isDown
love.keyboard.isDown = function(...)
  for _, k in ipairs({ ... }) do if held[k] then return true end end
  return false
end
local order = {}
for _, g in ipairs(LauncherView.gameTabs(kb)) do order[#order + 1] = g.id end
held.lctrl = true
check(LauncherView.keypressed(kb, "tab"), "Ctrl+Tab is handled")
eq(kb.tab, order[2], "Ctrl+Tab walks to the next library entry")
held.lshift = true
LauncherView.keypressed(kb, "tab")
eq(kb.tab, order[1], "Ctrl+Shift+Tab walks back")
held.lshift = nil
LauncherView.keypressed(kb, "pageup")
eq(kb.tab, LauncherView.HEADER_TABS[#LauncherView.HEADER_TABS].id,
  "Ctrl+PageUp from the first game wraps to the last tool")
held.lctrl = nil
check(not LauncherView.keypressed(kb, "tab"), "a bare Tab is left alone")
love.keyboard.isDown = realIsDown

Kit.button, love.timer.getTime = realButton, realTime
T.finish("launcher nav rail")
