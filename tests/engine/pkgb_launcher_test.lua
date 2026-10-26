-- The PK:GB launcher (src/launcher/Launcher.lua) and its import job
-- (src/import/ImportJob.lua), headless.  No pokered cite: port-only chrome.
--
-- Pins what a player relies on: every game is listed, the required credit
-- is on screen at every window size, a bad file is refused with a reason,
-- Continue plays the chosen save and New game makes a fresh one, and clicks
-- only queue work until update() runs it.
--   luajit tests/engine/pkgb_launcher_test.lua

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
}, { __index = require("src.import.CacheContract") })

local Launcher = require("src.launcher.Launcher")

local launched = {}
local function fresh()
  launched = {}
  return Launcher.new(function(version) launched[#launched + 1] = version end)
end

local function window(w, h)
  love.graphics.getDimensions = function() return w, h end
  love.graphics.getPixelDimensions = function() return w, h end
end

local realPrint = love.graphics.print
local function drawText(l)
  local seen = {}
  love.graphics.print = function(str, ...)
    seen[#seen + 1] = tostring(str)
    return realPrint(str, ...)
  end
  local ok, err = pcall(l.draw, l)
  love.graphics.print = realPrint
  check(ok, "the launcher draws: " .. tostring(err))
  return table.concat(seen, "\n")
end

-- ------------------------------------------------------------- library
local l = fresh()
local inOrder = {}
for _, v in ipairs(GameVersion.ORDER) do inOrder[v] = true end
local allKnown = true
for _, v in ipairs(l.games) do allKnown = allKnown and inOrder[v] == true end
check(allKnown, "every listed game is a supported GameVersion")
check(#l.games >= 10, "every supported game is listed (" .. #l.games .. ")")
eq(l.selected, "gold", "an imported game is selected first")
check(l.ready.gold and not l.ready.red, "readiness comes from the cache contract")

local slots = l:slotsFor("gold")
eq(#slots, 2, "only saves that exist are offered")
eq(l.selectedSlot.gold, "slot1", "the active save is preselected")

-- ------------------------------------------------- credit at every size
for _, size in ipairs({ { 1280, 720 }, { 1024, 768 }, { 800, 600 },
    { 390, 844 }, { 360, 640 } }) do
  window(size[1], size[2])
  local text = drawText(fresh())
  local tag = size[1] .. "x" .. size[2]
  check(text:find("BOIS CLUB", 1, true) ~= nil
      and text:find("github.com/bryanthaboi/gen1recomp", 1, true) ~= nil,
    tag .. ": the license-required credit is on screen")
  check(text:find("Pokemon Gold", 1, true) ~= nil, tag .. ": the game list draws")
  check(text:find("Continue", 1, true) ~= nil and text:find("New game", 1, true) ~= nil,
    tag .. ": Continue and New game are offered for an imported game")
end
eq(Launcher.CREDIT, "Based on the Pokemon Gen 1 Recompilation Project by "
  .. "BOIS CLUB GAMES, LLC (https://github.com/bryanthaboi/gen1recomp)",
  "the credit is the exact wording LICENSE.MD requires")

-- --------------------------------------------- a game not yet imported
window(1280, 720)
l = fresh()
l.selected = "red"
local text = drawText(l)
check(text:find("Import ROM", 1, true) ~= nil, "a missing game offers Import ROM")
check(text:find("Continue", 1, true) == nil, "and no Continue")

-- ------------------------------------------------------- bad files
l = fresh()
l:importData("not a rom", "notes.txt")
check(l.message and l.message.kind == "error", "a wrong-size file is refused")
check(l.message.text:find("MiB", 1, true) ~= nil, "with the size explained")
eq(l.job, nil, "and no import starts")
local _, err = ImportJob.verify("", "empty.gb")
check(err ~= nil, "an empty file is refused")
local _, err2 = ImportJob.verify(nil, "x.gb")
check(err2 ~= nil, "an unreadable file is refused")

-- ------------------------------------------------------------ play
l = fresh()
l.selectedSlot.gold = "slot2"
l:play("gold", "slot2")
eq(active.gold, "slot2", "Continue makes the chosen save active")
eq(launched[1], "gold", "and launches that game")

l = fresh()
l:newGame("gold")
eq(#created, 1, "New game creates a save slot")
eq(active.gold, created[1].id, "makes it active")
eq(launched[1], "gold", "and launches")

-- ------------------------------------- clicks queue; update() runs them
window(1280, 720)
l = fresh()
local Kit = require("src.ui.kit.Kit")
local rects = {}
local realButton = Kit.button
Kit.button = function(x, y, w, h, label, opts)
  if opts and opts.id then rects[opts.id] = { x = x + w / 2, y = y + h / 2 } end
  return realButton(x, y, w, h, label, opts)
end
l:draw()
check(rects.newgame ~= nil, "New game has a button")
l:mousepressed(rects.newgame.x, rects.newgame.y, 1)
l:mousereleased(rects.newgame.x, rects.newgame.y, 1)
local before = #created
l:draw()
eq(#created, before, "a click does nothing inside draw")
l:update(0)
eq(#created, before + 1, "update() runs the queued New game")
eq(launched[#launched], "gold", "which launches the game")
Kit.button = realButton

-- ------------------------------------------------------- save files
l = fresh()
l.selectedSlot.gold = "slot2"
l:deleteSave()
eq(#deleted, 0, "the first Delete only arms")
check(l.message and l.message.kind == "error", "and warns")
l:deleteSave()
eq(deleted[1], "gold:slot2", "the second Delete removes that save")

l = fresh()
l.selectedSlot.gold = "slot1"
l:deleteSave()
l:queue(function() end)
l:update(0)
l:deleteSave()
eq(#deleted, 1, "any other action in between disarms Delete")

l = fresh()
l.selectedSlot.gold = "slot2"
l:renameSave("  Nuzlocke run  ")
eq(renamed[1].id, "slot2", "Rename targets the selected save")
eq(renamed[1].name, "Nuzlocke run", "with the name trimmed")
l:renameSave("   ")
eq(renamed[2].name, nil, "a blank name clears the label")

l = fresh()
l.selectedSlot.gold = "slot2"
l:exportSave()
eq(exported[1].slot, "slot2", "Export writes the selected save, not just the active one")
check(l.message.text:find("slot2.sav", 1, true) ~= nil, "and says where it went")

l = fresh()
local dropped = { getFilename = function() return "/home/me/Gold.sav" end }
l:filedropped(dropped)
eq(imported[1] and imported[1].source, dropped, "a dropped .sav is imported as a save")
eq(imported[1].version, "gold", "into the selected game")
eq(l.selectedSlot.gold, "slot7", "and the new save is selected")
check(Launcher.isSaveName("x.SRM") and not Launcher.isSaveName("x.gbc"),
  "save files are told from ROMs by extension")
l.selected = "red"
l:importSave("bytes", "Red.sav")
eq(#imported, 1, "a save for a game without its ROM is refused")

-- -------------------------------------------------------------- settings
-- (listing games runs SecretGames' unlock check, which may itself write the
-- options; start this section from a known options table)
l = fresh()
savedOptions, saves = { musicVol = 5, sfxVol = 7, videoMode = "windowed" }, 0
l.opts_ = nil
eq(l:options().musicVol, 5, "settings read the saved options")
l:setOption("musicVol", 6)
eq(savedOptions.musicVol, 6, "a change is written straight to the options")
eq(saves, 1, "once")
local applied
package.loaded["src.core.VideoMode"] = { apply = function(m) applied = m end,
  fixedDisplay = function() return false end,
  normalize = function(m) return m == "borderless" and m or "windowed" end }
l:setOption("videoMode", "borderless")
eq(applied, "borderless", "the display mode applies to the live window")
window(1280, 720)
l.page = "settings"
local stext = drawText(l)
check(stext:find("Music volume", 1, true) and stext:find("Sound volume", 1, true)
  and stext:find("Fullscreen", 1, true), "the settings page draws its rows")
check(stext:find("BOIS CLUB", 1, true) ~= nil, "with the credit still on screen")
l:queue(function() end)
local rects2 = {}
local realButton2 = Kit.button
Kit.button = function(x, y, w, h, label, opts)
  if opts and opts.id then rects2[opts.id] = { x = x + w / 2, y = y + h / 2 } end
  return realButton2(x, y, w, h, label, opts)
end
l:draw()
Kit.button = realButton2
check(rects2["musicVol-up"] and rects2["sfxVol-down"] and rects2["video-mode"],
  "every setting has a control")

T.finish("pkgb launcher")
