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
local created, active = {}, {}
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
  activeSlot = function() return "slot1" end,
  setActiveSlot = function(version, id) active[version] = id return true end,
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

T.finish("pkgb launcher")
