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

T.finish("launcher pad audit")
