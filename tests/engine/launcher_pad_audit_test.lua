-- The launcher with only a gamepad, the controls audit: a control that
-- disables itself under the ring (volume "-" at 0) hands it to its row
-- neighbour, not the side rail; Back lands on the row that opened the
-- page; B closes the save Rename row; one press on a pad whose d-pad is
-- also a hat moves the file browser one step; Start does not launch past an
-- open "..." menu; and a held d-pad repeats.
--   luajit tests/engine/launcher_pad_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end
love.graphics.newShader = love.graphics.newShader or function() return {} end

local T = require("tests.harness")
local check, eq = T.check, T.eq

local GameVersion = require("src.core.GameVersion")
local ImportJob = require("src.import.ImportJob")

-- SaveData seam: two Gold saves, slot creation recorded.
local created, active, deleted, renamed = {}, {}, {}, {}
local savedOptions, saves = { musicVol = 5, sfxVol = 7, videoMode = "windowed" }, 0
local imported, exported = {}, {}
package.loaded["src.import.SaveFileIO"] = {
  importToSlot = function(source, version)
    imported[#imported + 1] = { source = source, version = version }
    active[version] = "slot7"
    return true
  end,
  exportActiveSlot = function(version)
    exported[#exported + 1] = { version = version, slot = active[version] }
    return true, "/exports/" .. version .. "/" .. tostring(active[version]) .. ".sav"
  end,
}
package.loaded["src.core.SaveData"] = {
  listSlots = function(version)
    if version ~= "gold" then return {} end
    return {
      { id = "slot1", exists = true, name = "GOLD",
        meta = { timeText = "3:15", badges = 2, dexCount = 31 } },
      { id = "slot2", exists = true, name = "KRIS",
        meta = { timeText = "0:42", badges = 0, dexCount = 4 } },
      { id = "slot3", exists = false },
    }
  end,
  activeSlot = function(version) return active[version] or "slot1" end,
  setActiveSlot = function(version, id) active[version] = id return true end,
  loadOptions = function() return savedOptions end,
  saveOptions = function(opts) savedOptions = opts; saves = saves + 1 return true end,
  deleteSlot = function(version, id) deleted[#deleted + 1] = version .. ":" .. id return true end,
  renameSlot = function(version, id, name) renamed[#renamed + 1] = { id = id, name = name } return true end,
  createSlot = function(version)
    local id = "slot" .. (10 + #created)
    created[#created + 1] = { version = version, id = id }
    return id
  end,
}
-- Only Gold is imported.
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(version) return version == "gold" end,
  isImported = function(version) return version == "gold" end,
}, { __index = require("src.import.CacheContract") })


local Launcher = require("src.launcher.Launcher")
local Kit = require("src.ui.kit.Kit")
love.graphics.getDimensions = function() return 1280, 720 end
love.graphics.getPixelDimensions = function() return 1280, 720 end
local launched = 0
local l = Launcher.new(function() launched = launched + 1 end)
local function frame(n) for _ = 1, (n or 1) do l:draw(); l:update(1 / 60) end end
local function pad(b) l:gamepadpressed(nil, b); frame(2) end
frame(15)

-- ---- a disabled "-" hands the ring to its "+", not to the rail
l.page = "settings"; frame(12)
l:setOption("musicVol", 1); frame(2)
Kit.setFocus("musicVol-down"); frame(2)
pad("a")
eq(l:options().musicVol, 0, "A on - takes the volume to 0")
eq(Kit.focusId, "musicVol-up", "the ring moves to the same row's +")
pad("a")
eq(l.page, "settings", "so a second A stays on Settings")

-- ---- Back from a sub-page lands on the row that opened it
Kit.setFocus("sync"); frame(2)
pad("a"); frame(12)
eq(l.page, "sync", "A on Save sync opens it")
pad("b"); frame(12)
eq(l.page, "settings", "B goes back")
eq(Kit.focusId, "sync", "with the ring on the Save sync row")

-- ---- B closes the save Rename row
l.page = nil; frame(12)
for _ = 1, 6 do if Kit.focusId == "save-menu-slot1" then break end pad("dpright") end
pad("a")
for _ = 1, 6 do if Kit.focusId == "save-rename" then break end pad("dpdown") end
pad("a")
eq(l.renaming, "slot1", "Rename opens the row")
pad("b")
eq(l.renaming, nil, "one B closes it")
eq(l.page, nil, "without leaving the Games page")

-- ---- Start with a save's "..." menu open does not launch
for _ = 1, 6 do if Kit.focusId == "save-menu-slot1" then break end pad("dpright") end
pad("a")
check(l.saveMenu ~= nil, "the ... menu is open")
pad("start")
eq(launched, 0, "Start does not launch past it")
pad("b")

-- ---- a hat that is the same d-pad moves one step
local js = { isGamepad = function() return true end, getName = function() return "Xbox" end,
             isGamepadDown = function() return true end }
local FB = Kit.FileBrowser
FB.active = true; FB.entries = {}
for i = 1, 20 do FB.entries[i] = { name = "f" .. i, path = "/f" .. i } end
FB.selectedIdx = 1; FB.page = 1
l:gamepadpressed(js, "dpdown"); l:joystickhat(js, 1, "d")
eq(FB.selectedIdx, 2, "one press, one step")

-- ---- and a held d-pad repeats until it is let go
l:stickRepeat(0.41)
eq(FB.selectedIdx, 3, "held past 0.4 s it steps again")
l:stickRepeat(0.12)
eq(FB.selectedIdx, 4, "then every 0.12 s")
l:gamepadreleased(js, "dpdown")
l:stickRepeat(0.5)
eq(FB.selectedIdx, 4, "and stops on release")
l:gamepadpressed(js, "dpdown")
js.isGamepadDown = function() return false end
l:stickRepeat(0.5)
eq(FB.selectedIdx, 5, "a release the launcher missed (the button is up) does not repeat")
FB.active = false

-- ---- A from the pad on a text field opens the on-screen keyboard, even off
-- a handheld (a Steam Deck, a desktop with a controller)
l.page = "settings"; frame(12)
local field
for i = 1, Kit._navPrevN do
  local id = tostring(Kit._nav[i].id)
  if id:match("relay") or id:match("name") then field = Kit._nav[i].id break end
end
if check(field ~= nil, "Settings has a text field") then
  Kit.setFocus(field); frame(2)
  pad("a")
  check(Kit.VirtualKeyboard.active, "A on it opens the on-screen keyboard")
  Kit.VirtualKeyboard.text = "typed"
  Kit.VirtualKeyboard.close(false); frame(2)
  check(not Kit.VirtualKeyboard.active, "cancel closes it")
  eq(Kit.focus, nil, "and the field ends with it")
  -- a tap on the keyboard (touch on a Steam Deck) is not a click away
  Kit.setFocus(field); frame(2)
  pad("a")
  check(Kit.VirtualKeyboard.active, "the keyboard is up again")
  l:mousepressed(5, 5, 1); l:mousereleased(5, 5, 1); frame(2)
  eq(Kit.focus, field, "a click while it is up keeps the field focused")
  Kit.VirtualKeyboard.close(true); frame(2)
  eq(Kit.focus, nil, "and Done still ends the field")
end

-- ---- a save's "..." menu opened from the pad puts the ring on its first item
l.page = nil; frame(12)
Kit.setFocus("save-menu-slot1"); frame(2)
pad("a"); frame(2)
eq(Kit.focusId, "save-rename", "the ring lands on Rename, the menu's first item")
pad("b"); frame(2)

-- ---- a shoulder press shows the ring on the section it moved to
pad("rightshoulder"); frame(4)
check(tostring(Kit.focusId):match("^nav%-") ~= nil and Kit._ringShown,
  "the ring is on the new section's rail button (" .. tostring(Kit.focusId) .. ")")
-- (the stubbed Box cannot open here, so the section itself stays put)
eq(Kit.focusId, "nav-box", "Games then RB: the ring is on Box")

-- ---- Down goes row by row: Mod tools' Back, Safe mode, then the Turn all row
l.selected = "gold"; l.page = "modtools"; frame(12)
Kit.setFocus("modtools-back"); frame(2)
l:keypressed("down"); frame(2)
eq(Kit.focusId, "safe-mode", "Down from Back reaches the Safe mode switch")
l:keypressed("down"); frame(2)
eq(Kit.focusId, "mods-all-on", "then the Turn all row, not the bottom row")
l.page = nil; frame(12)

-- ---- switching sections is not a Back, and a held d-pad stops at another button
l.page = "settings"; frame(12)
Kit.setFocus("nav-online"); frame(2)
pad("a"); frame(12)
Kit.setFocus("nav-settings"); frame(2)
pad("a"); frame(12)
eq(l.page, "settings", "Online then Settings from the rail")
eq(Kit.focusId, "nav-settings", "leaves the ring on Settings, not back on Online")
local held = { isGamepad = function() return true end, getName = function() return "Xbox" end,
               isGamepadDown = function() return true end }
l:gamepadpressed(held, "dpdown")
pad("leftshoulder"); frame(30)
eq(Kit.focusId, "nav-online", "a shoulder press ends a d-pad repeat; the ring stays on Online")
l:gamepadreleased(held, "dpdown")

-- ---- a held arrow key repeats too, and stops when the key is up
do
  local down = {}
  local realIsDown = love.keyboard.isDown
  love.keyboard.isDown = function(k) return down[k] == true end
  local FB2 = Kit.FileBrowser
  FB2.active = true; FB2.entries = {}
  for i = 1, 20 do FB2.entries[i] = { name = "f" .. i, path = "/f" .. i } end
  FB2.selectedIdx = 1; FB2.page = 1
  down.down = true
  l:keypressed("down")
  eq(FB2.selectedIdx, 2, "one press, one step")
  l:stickRepeat(0.41)
  eq(FB2.selectedIdx, 3, "held, it repeats")
  down.down = nil
  l:stickRepeat(0.5)
  eq(FB2.selectedIdx, 3, "let go, it stops")
  FB2.active = false
  love.keyboard.isDown = realIsDown
end

-- ---- Right from the rail enters Settings at its first control
l.page = "settings"; frame(12)
Kit.setFocus("nav-settings"); frame(2)
pad("dpright"); frame(2)
local first
for i = 1, Kit._navPrevN do
  local n = Kit._nav[i]
  if not tostring(n.id):match("^nav%-") and (not first or n.y < first.y or (n.y == first.y and n.x < first.x)) then
    first = n
  end
end
eq(Kit.focusId, first and first.id, "the top control, not the one level with the rail button")

-- ---- a PIN field opened from the pad gets the number pad and its limit
do
  local VK = Kit.VirtualKeyboard
  Kit.beginFrame(0, 0, false, 0)
  Kit._activateId, Kit._padActivate = "pin-probe", true
  Kit.textfield("pin-probe", 10, 10, 120, 30, "", "PIN", { digits = true, maxLen = 4 })
  check(VK.active, "A on a PIN field opens the keyboard")
  eq(VK.mode, 4, "on its number pad")
  eq(VK.maxLen, 4, "limited to four digits")
  VK.close(false)
  Kit.endFrame()
end

-- ---- Settings > Keys and buttons lists the hotkeys, and Back returns to its row
l.page = "settings"; frame(12)
Kit.setFocus("keys"); frame(2)
pad("a"); frame(12)
eq(l.page, "keys", "Show opens the keys page")
eq(l:section(), "settings", "under Settings")
local KeysPage = require("src.launcher.KeysPage")
local listed = {}
for _, sec in ipairs(KeysPage.SECTIONS) do
  for _, row in ipairs(sec[2]) do listed[row[1]] = row[2] end
end
eq(listed["F1 / F2"], "Quick save / quick load", "the quick save keys are listed")
pad("b"); frame(12)
eq(l.page, "settings", "B goes back to Settings")
eq(Kit.focusId, "keys", "with the ring on the row that opened it")

-- ---- plugging a controller in or out says so
do
  local xbox = { getName = function() return "Xbox Controller" end, isGamepad = function() return true end }
  l:joystickChanged(xbox, true)
  check(l.message and l.message.text == "Xbox Controller connected.", "a connected controller is named")
  l:joystickChanged(xbox, false)
  check(l.message and l.message.text == "Xbox Controller disconnected." and l.message.kind == "notice",
    "and its disconnection is a heads-up")
  l.message = nil
  local GM = require("src.core.GamepadMap")
  local real = GM.isAccelerometer
  GM.isAccelerometer = function() return true end
  l:joystickChanged(xbox, true)
  eq(l.message, nil, "an accelerometer is not news")
  GM.isAccelerometer = real
  -- a pad already plugged in when the launcher opened is reported as
  -- "added" just after start: no toast for that
  l.message = nil
  local deck = { getName = function() return "Steam Deck Controller" end, getID = function() return 41 end }
  l._padsAtStart = { [41] = true }
  l:joystickChanged(deck, true)
  eq(l.message, nil, "a pad present at start is not announced")
  l:joystickChanged(deck, false)
  l:joystickChanged(deck, true)
  check(l.message and l.message.text == "Steam Deck Controller connected.", "but plugging it back in is")
end

-- ---- a game picked by code stays picked while the ring sits still
do
  l.page = nil; frame(12)
  Kit.setFocus("game-gold"); frame(2)
  local other
  for v in pairs(require("src.core.GameVersion").VERSIONS) do
    if v ~= "gold" and l.games and (l.ready[v] or true) then other = v break end
  end
  l:selectGame(other); frame(3)
  eq(l.selected, other, "an import or inbox save's pick is not undone by the ring on Gold")
end

-- ---- Quit from the pad asks twice; leaving it disarms
do
  local quits = 0
  local realQuit = l.quit
  l.quit = function() quits = quits + 1 end
  l.page = nil; frame(12)
  Kit.setFocus("nav-quit"); frame(2)
  pad("a"); frame(2)
  eq(quits, 0, "the first A only asks")
  check(l.message and l.message.text:find("Quit again", 1, true), "and says so")
  pad("a"); frame(2)
  eq(quits, 1, "the second closes")
  Kit.setFocus("nav-quit"); frame(2)
  pad("a"); frame(2)
  pad("dpup"); frame(2)
  Kit.setFocus("nav-quit"); frame(2)
  pad("a"); frame(2)
  eq(quits, 1, "moving off it disarms, so coming back asks again")
  l.quit = realQuit
end

-- ---- the ring on a game row picks that game
l.page = nil; frame(12)
Kit.setFocus("game-gold"); frame(2)
pad("dpdown"); frame(2)
local moved = tostring(Kit.focusId):match("^game%-(.+)$")
if moved and require("src.core.GameVersion").VERSIONS[moved] then
  eq(l.selected, moved, "moving down the list selects the game under the ring")
end

-- ---- Page Down / Home walk the ring a screenful / to the top
do
  l.page = "settings"; frame(12)
  Kit.setFocus("nav-settings"); frame(2)
  pad("dpright"); frame(2)
  local top = Kit.focusId
  local function yOf(id)
    for i = 1, Kit._navPrevN do if Kit._nav[i].id == id then return Kit._nav[i].y end end
  end
  local y0 = yOf(top)
  l:keypressed("pagedown"); frame(10)
  check(yOf(Kit.focusId) and y0 and yOf(Kit.focusId) > y0, "Page Down moves the ring down the page")
  l:keypressed("home"); frame(70)
  eq(Kit.focusId, top, "Home walks it back to the first control")
end

-- ---- a finger drag scrolls the game list and is not a tap
do
  l.page = nil; l.listScroll = 0; frame(12)
  local before = l.selected
  l:touchpressed("f", 400, 600)
  for yy = 580, 300, -20 do l:touchmoved("f", 400, yy); frame(1) end
  l:touchreleased("f", 400, 300); frame(3)
  check((l.listScroll or 0) > 0, "dragging up scrolls the list down")
  eq(l.selected, before, "and the lift does not pick a game")
end

T.finish("launcher pad audit")
