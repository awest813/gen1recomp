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
CacheFs.root = function() return nil end
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

os.execute("rm -rf '" .. root .. "'")
T.finish("import backup")
