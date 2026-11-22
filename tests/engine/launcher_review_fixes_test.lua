-- Launcher review fixes: a closed "Import ROM again" dialog leaves no force
-- behind for a later drop; deleting a save closes its menu, so Start and B
-- work again; the file browser reopens at the top of its list; and the Box
-- page's toast stays under the file browser and takes no presses there.
--   luajit tests/engine/launcher_review_fixes_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end

local T = require("tests.harness")
local check, eq = T.check, T.eq

local ready = { gold = true, red = true }
local slots = { gold = { { id = "slot1", name = "Mine", exists = true } } }
package.loaded["src.core.SaveData"] = {
  listSlots = function(v) return slots[v] or {} end,
  activeSlot = function(v) return slots[v] and slots[v][1] and slots[v][1].id or nil end,
  setActiveSlot = function() return true end,
  deleteSlot = function(v, id)
    for i, s in ipairs(slots[v] or {}) do if s.id == id then table.remove(slots[v], i) end end
    return true
  end,
  loadOptions = function() return {} end, saveOptions = function() return true end,
  defaultOptions = function() return {} end,
}
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(v) return ready[v] == true end,
  isImported = function(v) return ready[v] == true end,
}, { __index = require("src.import.CacheContract") })

local ImportJob = require("src.import.ImportJob")
ImportJob.interrupted = function() return false end
ImportJob.verify = function(data)
  local v = tostring(data):match("^ROM:(%a+)$")
  if v then return { version = v } end
  return nil, "That file is not a ROM."
end
local starts = {}
ImportJob.start = function(rom)
  starts[#starts + 1] = rom.version
  return { state = "working", version = rom.version, step = function(j) return j.state end }
end

-- a desktop with a system dialog, which the player closes
local dialogAnswer = nil
package.loaded["src.core.FilePicker"] = setmetatable({
  available = function() return true end,
  hasDialog = function() return true end,
  open = function() return dialogAnswer end,
  read = function(path) return "ROM:red", nil, path end,
  basename = function(p) return (tostring(p):match("[^/]+$")) end,
}, { __index = require("src.core.FilePicker") })

local Launcher = require("src.launcher.Launcher")
local Kit = require("src.ui.kit.Kit")
love.graphics.getDimensions = function() return 1280, 720 end
love.graphics.getPixelDimensions = function() return 1280, 720 end

-- ---- a closed Import ROM again dialog leaves nothing for the next drop
do
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  dialogAnswer = nil
  l:pickRom(true)
  l:importData("ROM:red", "red.gb")
  eq(#starts, 0, "a later drop of a ready game does not import over it")
  check(l.message and l.message.text:find("already imported", 1, true), "it says the game is ready")
  -- the dialog's own pick does replace it
  dialogAnswer = "/roms/red.gb"
  l:pickRom(true)
  l:update(0)
  eq(starts[#starts], "red", "Import ROM again with a file chosen imports it")
  starts = {}
end

-- ---- deleting a save closes its menu
do
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  l:selectGame("gold")
  l.saveMenu = "slot1"
  l:deleteSave()
  eq(l.saveMenu, "slot1", "the first press only arms Delete, the menu stays")
  l:deleteSave()
  eq(#slots.gold, 0, "the second deletes the save")
  eq(l.saveMenu, nil, "and closes its menu")
  check(not l:closeGamesPopup(), "so B has no menu left to swallow it")
end

-- ---- the file browser opens at the top of its list
do
  local FileBrowser = Kit.FileBrowser
  FileBrowser.open({ title = "x", mode = "rom", initialPath = "/" })
  FileBrowser.scroll, FileBrowser.pathError = 400, "Nothing called x was found."
  FileBrowser.active = false
  FileBrowser.open({ title = "y", mode = "sav", initialPath = "/" })
  eq(FileBrowser.scroll, 0, "a new browse starts scrolled to the top")
  eq(FileBrowser.pathError, nil, "with no complaint left from the last one")
  FileBrowser.active = false
end

-- ---- the Box toast stays under the file browser
do
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  local BoxUI = require("src.import.BoxUI")
  local realToast = BoxUI.drawToast
  local order, blocked = {}, nil
  BoxUI.drawToast = function() order[#order + 1] = "box"; blocked = Kit.blockClicks end
  local realDraw = Kit.FileBrowser.draw
  Kit.FileBrowser.draw = function() order[#order + 1] = "browser" end
  l.page = "box"
  Kit.FileBrowser.active = true
  pcall(l.draw, l)
  Kit.FileBrowser.active = false
  Kit.FileBrowser.draw, BoxUI.drawToast = realDraw, realToast
  local at = {}
  for i, what in ipairs(order) do at[what] = at[what] or i end
  check(at.box and at.browser and at.box < at.browser, "the Box toast is drawn under the browser")
  eq(blocked, true, "and takes no presses while the browser is open")
end

T.finish("launcher review fixes")
