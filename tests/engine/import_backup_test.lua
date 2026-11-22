-- Importing a game again keeps the copy that works until the new one is
-- ready: the old tree is renamed aside, put back when the import fails or
-- is cancelled (or the app quits part way), and deleted once the new copy
-- is published.  Runs on a real folder: the rename is the point.
--   luajit tests/engine/import_backup_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- a love.filesystem over a real temporary save directory
local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p '" .. root .. "'")
local function real(rel) return root .. "/" .. rel end
local function sh(cmd) local p = io.popen(cmd); local out = p:read("*a"); p:close(); return out end
local function isDir(path) return sh("test -d '" .. path .. "' && echo y"):match("y") ~= nil end
local function write(rel, text)
  local dir = real(rel):match("^(.*)/[^/]+$")
  os.execute("mkdir -p '" .. dir .. "'")
  local f = assert(io.open(real(rel), "wb")); f:write(text); f:close()
end
local function exists(rel)
  if isDir(real(rel)) then return true end
  local f = io.open(real(rel), "rb")
  if f then f:close() return true end
  return false
end
local realFs = {
  getSaveDirectory = function() return root end,
  getInfo = function(rel)
    if isDir(real(rel)) then return { type = "directory" } end
    local f = io.open(real(rel), "rb")
    if f then f:close() return { type = "file" } end
  end,
  getDirectoryItems = function(rel)
    local out = {}
    for name in sh("ls -1A '" .. real(rel) .. "' 2>/dev/null"):gmatch("[^\n]+") do out[#out + 1] = name end
    return out
  end,
  remove = function(rel) return os.remove(real(rel)) ~= nil end,
  read = function(rel)
    local f = io.open(real(rel), "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end,
  write = function(rel, data) write(rel, data) return true end,
  createDirectory = function(rel) os.execute("mkdir -p '" .. real(rel) .. "'") return true end,
}
love.filesystem = setmetatable(realFs, { __index = love.filesystem })

local CacheFs = require("src.import.CacheFs")
local portable = false
CacheFs.root = function() return portable and root or nil end
CacheFs.remove = function(rel) os.remove(real((CacheFs.prefix or "") .. rel)) end
CacheFs.read = function(rel) return realFs.read((CacheFs.prefix or "") .. rel) end
local ImportJob = require("src.import.ImportJob")
local MARKER = require("src.import.CacheContract").MARKER_PATH

local function freshGame()
  os.execute("rm -rf '" .. real("yellow") .. "'")
  write("yellow/" .. MARKER, "ok")
  write("yellow/data/generated/maps.lua", "old maps")
  write("yellow/assets/generated/tiles.png", "old tiles")
end

-- ---- the copy is moved aside, and put back over a half-built one
do
  freshGame()
  local backup = ImportJob._backupCache("yellow/")
  check(backup ~= nil, "a ready game is backed up")
  check(not exists("yellow/" .. MARKER), "the marker moves first")
  check(exists("yellow/data/generated.previous/maps.lua"), "the data moves aside whole")
  write("yellow/data/generated/half.lua", "half built")
  local ok = ImportJob._restoreBackup("yellow/", backup)
  check(ok, "the backup goes back")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "with the old data")
  check(not exists("yellow/data/generated/half.lua"), "and none of the half-built one")
  check(exists("yellow/" .. MARKER), "and the game is ready again")
  check(not exists("yellow/data/generated.previous"), "leaving no backup behind")
end

-- ---- a finished import deletes the backup
do
  freshGame()
  local backup = ImportJob._backupCache("yellow/")
  write("yellow/data/generated/maps.lua", "new maps")
  ImportJob._dropBackup("yellow/", backup)
  check(not exists("yellow/data/generated.previous/maps.lua"), "the old data is gone once the new copy is in")
  check(not exists("yellow/" .. MARKER .. ".previous"), "and so is its marker")
end

-- ---- nothing ready, nothing kept
do
  os.execute("rm -rf '" .. real("yellow") .. "'")
  write("yellow/data/generated/maps.lua", "unfinished")
  eq(ImportJob._backupCache("yellow/"), nil, "an unfinished tree is not worth keeping")
end

-- ---- Cancel stops the import and puts the old copy back
do
  freshGame()
  local job = setmetatable({ version = "yellow", prefix = "yellow/", state = "working",
    gameName = "Pokemon Yellow", ownsTree = true,
    worker = coroutine.create(function() while true do coroutine.yield() end end) }, ImportJob)
  job.backup = ImportJob._backupCache("yellow/")
  write("yellow/data/generated/half.lua", "half built")
  check(job:cancel(), "a running import can be cancelled")
  eq(job:step(0.001), "error", "the next step stops it")
  eq(job.detail, ImportJob.CANCELLED, "as a cancel, not a failure")
  check(job.restored, "the previous copy is restored")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "and plays as before")
end

-- ---- the app quit part way: the next launch puts the old copy back
do
  freshGame()
  ImportJob._backupCache("yellow/")
  write("yellow/data/generated/half.lua", "half built")
  write("yellow/" .. ImportJob.LOCK_PATH, "0 1")
  local realInterrupted = ImportJob.interrupted
  ImportJob.interrupted = function() return true end
  check(ImportJob.recover("yellow"), "an interrupted import is recovered")
  ImportJob.interrupted = realInterrupted
  check(exists("yellow/" .. MARKER), "the game is ready again")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "with its old data")
  check(not exists("yellow/" .. ImportJob.LOCK_PATH), "and no stale lock")
end

-- ---- a portable install (the cache in the game folder): again and again
-- (its tree clearing leaves folders, which a rename onto then failed)
do
  portable = true
  freshGame()
  write("yellow/data/generated/gba/sub.lua", "sub")
  for round = 1, 2 do
    local backup = ImportJob._backupCache("yellow/")
    check(backup ~= nil, "portable backup works on round " .. round)
    write("yellow/data/generated/gba/half.lua", "half built")
    check(ImportJob._restoreBackup("yellow/", backup), "and is restored on round " .. round)
    eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "with the old data, round " .. round)
    check(not exists("yellow/data/generated/gba/half.lua"), "and none of the half-built one, round " .. round)
  end
  local backup = ImportJob._backupCache("yellow/")
  ImportJob._dropBackup("yellow/", backup)
  check(not exists("yellow/data/generated.previous"), "a dropped backup leaves no empty folders")
  portable = false
end

-- ---- a crash between the renames: the tree not yet moved is kept
do
  freshGame()
  local base = root .. "/yellow/"
  os.rename(base .. MARKER, base .. MARKER .. ".previous")
  os.rename(base .. "data/generated", base .. "data/generated.previous")
  write("yellow/" .. ImportJob.LOCK_PATH, "0 1")
  local realInterrupted = ImportJob.interrupted
  ImportJob.interrupted = function() return true end
  check(ImportJob.recover("yellow"), "the half-made backup is recovered")
  ImportJob.interrupted = realInterrupted
  eq(realFs.read("yellow/assets/generated/tiles.png"), "old tiles", "the tree it never moved is still there")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "and the moved one is back")
end

-- ---- a tree the old copy never had: the failed import made it, so it goes
local function dataOnlyGame()
  os.execute("rm -rf '" .. real("yellow") .. "'")
  write("yellow/" .. MARKER, "ok")
  write("yellow/data/generated/maps.lua", "old maps")
end
do
  dataOnlyGame()
  local backup = ImportJob._backupCache("yellow/")
  write("yellow/assets/generated/half.png", "half built")
  check(ImportJob._restoreBackup("yellow/", backup), "a failed import with a new tree is undone")
  check(not exists("yellow/assets/generated"), "the tree the old copy never had is removed")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "and the old data is back")
  check(not exists("yellow/" .. MARKER .. ".previous.trees"), "leaving no tree list behind")
end

-- ---- the same after a crash: the list written before the renames tells
-- a tree the import made from one the renames never reached
do
  dataOnlyGame()
  ImportJob._backupCache("yellow/")
  write("yellow/data/generated/half.lua", "half built")
  write("yellow/assets/generated/half.png", "half built")
  write("yellow/" .. ImportJob.LOCK_PATH, "0 1")
  local realInterrupted = ImportJob.interrupted
  ImportJob.interrupted = function() return true end
  check(ImportJob.recover("yellow"), "an interrupted import that made a new tree is recovered")
  ImportJob.interrupted = realInterrupted
  check(not exists("yellow/assets/generated"), "the new tree is removed")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "the old data is back")
  check(not exists("yellow/data/generated/half.lua"), "without the half-built data")
  check(exists("yellow/" .. MARKER), "and the game is ready again")
end

-- ---- a crash between the renames, with the list: the unmoved tree stays
do
  freshGame()
  local base = root .. "/yellow/"
  local f = assert(io.open(base .. MARKER .. ".previous.trees", "wb"))
  f:write("data/generated\nassets/generated\n"); f:close()
  os.rename(base .. MARKER, base .. MARKER .. ".previous")
  os.rename(base .. "data/generated", base .. "data/generated.previous")
  write("yellow/" .. ImportJob.LOCK_PATH, "0 1")
  local realInterrupted = ImportJob.interrupted
  ImportJob.interrupted = function() return true end
  check(ImportJob.recover("yellow"), "a half-made backup with its list is recovered")
  ImportJob.interrupted = realInterrupted
  eq(realFs.read("yellow/assets/generated/tiles.png"), "old tiles", "the unmoved tree is kept")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "and the moved one is back")
end

-- ---- a crash during the restore itself, at each step: the next launch
-- finishes it (the lock is still there, as the job held it throughout)
local function crashedRestore(step)
  freshGame()
  local base = root .. "/yellow/"
  ImportJob._backupCache("yellow/")
  write("yellow/data/generated/half.lua", "half built")
  write("yellow/assets/generated/half.png", "half built")
  write("yellow/" .. ImportJob.LOCK_PATH, "0 1")
  -- the restore runs as far as `step`, then the app dies
  ImportJob._wipeTree("yellow/", "data/generated")
  if step >= 2 then os.rename(base .. "data/generated.previous", base .. "data/generated") end
  if step >= 3 then
    ImportJob._wipeTree("yellow/", "assets/generated")
    os.rename(base .. "assets/generated.previous", base .. "assets/generated")
  end
  check(ImportJob.recover("yellow"), "a restore cut off at step " .. step .. " is finished")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "step " .. step .. ": the old data is back")
  eq(realFs.read("yellow/assets/generated/tiles.png"), "old tiles", "step " .. step .. ": and the old assets")
  check(not exists("yellow/assets/generated/half.png"), "step " .. step .. ": without the half-built assets")
  check(exists("yellow/" .. MARKER), "step " .. step .. ": the game is ready again")
  check(not exists("yellow/" .. MARKER .. ".previous"), "step " .. step .. ": the backup marker is used up")
  check(not exists("yellow/" .. ImportJob.LOCK_PATH), "step " .. step .. ": and the lock is gone")
end
for step = 1, 3 do crashedRestore(step) end

-- ---- a restore that fails outright (a rename refused) ends the job and
-- drops its lock; the old copy still comes back on the next try
do
  freshGame()
  local job = setmetatable({ version = "yellow", prefix = "yellow/", state = "working",
    gameName = "Pokemon Yellow", ownsTree = true, lockedAt = os.time() }, ImportJob)
  write("yellow/" .. ImportJob.LOCK_PATH, "0 1")
  job.backup = ImportJob._backupCache("yellow/")
  write("yellow/data/generated/half.lua", "half built")
  local realRename = os.rename
  os.rename = function(from, to)
    if from:match("data/generated%.previous$") then return nil, "refused" end
    return realRename(from, to)
  end
  job:fail("disk full")
  os.rename = realRename
  eq(job.restored, false, "the failed restore is reported")
  check(not exists("yellow/" .. ImportJob.LOCK_PATH), "the job's lock is gone")
  check(exists("yellow/data/generated.previous/maps.lua"), "the old data is still kept aside")
  check(ImportJob.recover("yellow"), "and the next try puts it back, with no lock")
  eq(realFs.read("yellow/data/generated/maps.lua"), "old maps", "with the old data")
  eq(realFs.read("yellow/assets/generated/tiles.png"), "old tiles", "and the old assets")
  check(exists("yellow/" .. MARKER), "ready to play")
end

-- ---- a finished import that quit before deleting its backup: the new
-- copy stays, and the backup is deleted
do
  freshGame()
  ImportJob._backupCache("yellow/")
  write("yellow/data/generated/maps.lua", "new maps")
  write("yellow/assets/generated/tiles.png", "new tiles")
  write("yellow/" .. MARKER, "ok")
  write("yellow/" .. ImportJob.LOCK_PATH, "0 1")
  eq(ImportJob.recover("yellow"), false, "a finished import is not rolled back")
  eq(realFs.read("yellow/data/generated/maps.lua"), "new maps", "the new data stays")
  check(not exists("yellow/data/generated.previous"), "the leftover backup is deleted")
  check(not exists("yellow/assets/generated.previous"), "all of it")
  check(not exists("yellow/" .. MARKER .. ".previous"), "with its marker")
  check(not exists("yellow/" .. MARKER .. ".previous.trees"), "and its list")
end

-- ---- another process importing the game right now is left alone
do
  freshGame()
  ImportJob._backupCache("yellow/")
  write("yellow/" .. ImportJob.LOCK_PATH, os.time() .. " ")
  eq(ImportJob.recover("yellow"), false, "a live import elsewhere is not touched")
  check(exists("yellow/data/generated.previous/maps.lua"), "its backup stays")
  os.remove(real("yellow/" .. ImportJob.LOCK_PATH))
end

os.execute("rm -rf '" .. root .. "'")
T.finish("import backup")
