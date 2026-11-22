-- Sync review fixes outside the engine: a game's options write (an in-game
-- save) no longer puts the sync bookkeeping back to how it was when the
-- game started, and deleting a save in the launcher tells sync, so it does
-- not come back on the next sync.
--   luajit tests/engine/sync_review_fixes_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end

local T = require("tests.harness")

-- ---- the game's options copy does not carry an old saveSync
do
  local SaveData = require("src.core.SaveData")
  local SyncState = require("src.sync.SyncState")
  local opts = SaveData.loadOptions()
  local state = SyncState.defaults()
  SyncState.setRev(state, "red/abc", 7, 500)
  opts.saveSync = state
  SaveData.saveOptions(opts)
  -- the game loads its copy here...
  local gameCopy = SaveData.loadOptions()
  -- ...and the engine syncs while it runs
  SyncState.update(function(s) SyncState.setRev(s, "red/abc", 10, 900) end)
  -- an in-game save writes the game's whole copy
  SaveData.saveLiveOptions({ options = gameCopy })
  local after = SyncState.load()
  T.eq(SyncState.rev(after, "red/abc"), 10, "the engine's newer revision survives an in-game save")
end

-- ---- a launcher delete reaches sync
do
  local noted = {}
  package.loaded["src.sync.SyncEngine"] = {
    _shared = { noteSaveDeleted = function(_, key) noted[#noted + 1] = key end },
    shared = function() return nil end,
  }
  local deleted = {}
  package.loaded["src.core.SaveData"] = setmetatable({
    listSlots = function() return { { id = "slot1", exists = true, name = "RED" } } end,
    activeSlot = function() return "slot1" end,
    slotPlaythroughId = function(_, id) return id == "slot1" and "abc" or nil end,
    deleteSlot = function(v, id) deleted[#deleted + 1] = v .. ":" .. id return true end,
    loadOptions = function() return {} end, saveOptions = function() return true end,
  }, { __index = require("src.core.SaveData") })
  package.loaded["src.import.CacheContract"] = setmetatable({
    isReady = function(v) return v == "red" end,
    isImported = function(v) return v == "red" end,
  }, { __index = require("src.import.CacheContract") })
  package.loaded["src.launcher.Launcher"] = nil
  local Launcher = require("src.launcher.Launcher")
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  l:selectGame("red")
  l:deleteSave()
  l:deleteSave()
  T.eq(deleted[1], "red:slot1", "the save is deleted")
  T.eq(noted[1], "red/abc", "and sync is told, by its playthrough")
end

T.finish("sync review fixes")
