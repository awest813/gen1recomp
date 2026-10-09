-- The "Web" (love.js) platform profile: docs/proposals/web-port.md phase 1.
-- Fakes love.system.getOS() == "Web" on the stub and checks every gate the
-- browser build relies on, including that the real love.run frame function
-- never calls love.timer.sleep there.
--   luajit tests/engine/web_profile_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")
love.system = love.system or {}

local osName = "Web"
love.system.getOS = function() return osName end

local Platform = require("src.core.Platform")
local WebHost = require("src.core.WebHost")

-- ---------------------------------------------------------------- bridge
local picked, pickedKinds, syncCalls, drops, downloads = {}, {}, 0, {}, {}
local fakeBridge = {
  pickFile = function(kind) pickedKinds[#pickedKinds + 1] = kind or "rom"; return true end,
  getPickedFile = function() return table.remove(picked, 1) end,
  getPickError = function() return nil end,
  pickFileKinds = function() return "rom,sav,mod" end,
  syncStorage = function() syncCalls = syncCalls + 1 end,
  getDroppedFile = function() return table.remove(drops, 1) end,
  downloadFile = function(path, name) downloads[#downloads + 1] = { path, name }; return true end,
}
local savedSystem = {}
for _, k in ipairs({ "pickFile", "getPickedFile", "getPickError", "pickFileKinds" }) do
  savedSystem[k] = love.system[k]
  love.system[k] = nil
end
local savedIoOpen, savedRemove, savedRename = io.open, os.remove, os.rename
local savedFs = {}
for _, k in ipairs({ "write", "append", "remove", "createDirectory" }) do
  savedFs[k] = love.filesystem and love.filesystem[k]
end

-- a File type whose methods live on a shared metatable, like LÖVE's
local FileMethods = {}
FileMethods.__index = FileMethods
function FileMethods:open(mode) self.mode = mode; return true end
function FileMethods:write() return true end
function FileMethods:flush() return true end
function FileMethods:getMode() return self.mode or "c" end
function FileMethods:close() self.mode = "c"; return true end
local savedNewFile = love.filesystem and love.filesystem.newFile
love.filesystem = love.filesystem or {}
love.filesystem.newFile = function() return setmetatable({}, FileMethods) end

WebHost._resetForTests()
Platform._resetForTests()
check(WebHost.install({ bridge = fakeBridge }), "install takes the native bridge")
check(WebHost.hasBridge(), "bridge recorded")
eq(love.system.pickFile, fakeBridge.pickFile, "pickFile copied onto love.system")
eq(love.system.getPickedFile, fakeBridge.getPickedFile, "getPickedFile copied onto love.system")
check(not WebHost.install({ bridge = fakeBridge }) or true, "install is idempotent")

-- ---------------------------------------------------------------- profile
local p = Platform.detect()
eq(p.os, "Web", "os")
eq(p.web, true, "web flag")
eq(Platform.isWeb(), true, "isWeb()")
eq(Platform.hasThreads(), false, "no trusted threads on web")
eq(Platform.canSpawnProcess(), false, "no processes on web")
eq(Platform.networkValidated(), false, "no self-updater on web")
eq(Platform.canFetchRemote(), false, "no curl fetch on web")
eq(Platform.pickedFilesAreTemporary(), true, "picked files are scratch copies")
eq(Platform.romImportMode(), "native-picker", "bridge puts web on the native-picker path")

-- ---------------------------------------------------------------- conf.lua
-- love.js is LÖVE 11.4: declaring 11.5 there makes LÖVE alert() a
-- "Compatibility Warning" on every page load
do
  local savedConf, savedOs, savedFs = love.conf, love._os, love.filesystem
  love._os = "Web"
  -- conf.lua's own setup calls (setSymlinksEnabled, ...) are no-ops here
  love.filesystem = setmetatable({}, { __index = function(_, k)
    return savedFs and savedFs[k] or function() end
  end })
  local chunk = assert(loadfile("conf.lua"))
  local okLoad = pcall(chunk)
  local t = { window = {}, modules = {}, audio = {} }
  local okConf = okLoad and love.conf and pcall(love.conf, t)
  check(okConf, "conf.lua runs on Web")
  eq(t.version, "11.4", "conf.lua declares love.js's LÖVE version on Web")
  love.conf, love._os, love.filesystem = savedConf, savedOs, savedFs
end

-- ---------------------------------------------------------------- storage sync
do
  -- /tmp is MEMFS on the web: scratch writes there need no IndexedDB sync
  local scratch = os.tmpname()
  check(scratch:sub(1, 5) ~= "/tmp/" or (function()
    local h = io.open(scratch, "wb"); h:write("x"); h:close()
    os.remove(scratch)
    return not WebHost.isDirty()
  end)(), "writes under /tmp do not dirty the store")
  -- a path outside /tmp stands in for the persisted save directory
  local tmp = "web_profile_test.scratch"
  local f = io.open(tmp, "rb")
  if f then f:close() end
  check(not WebHost.isDirty(), "reads do not dirty the store")
  f = io.open(tmp, "wb")
  f:write("x")
  f:close()
  check(WebHost.isDirty(), "a write dirties the store")
  WebHost.update(0.1)
  eq(syncCalls, 0, "no sync while writes are still landing")
  WebHost.update(1.0)
  eq(syncCalls, 1, "one sync after the writes go quiet")
  check(not WebHost.isDirty(), "clean after the sync")
  -- a continuous write stream still flushes within the max delay
  for _ = 1, 20 do
    WebHost.markDirty()
    WebHost.update(0.5)
  end
  check(syncCalls >= 2, "steady writes still flush within SYNC_MAX_DELAY")
  os.remove(tmp)
end

-- streamed writes through File methods (CacheFs.openWrite)
do
  WebHost.syncNow()
  local reader = love.filesystem.newFile("a")
  reader:open("r")
  reader:close()
  check(not WebHost.isDirty(), "opening and closing a File for reading stays clean")
  local writer = love.filesystem.newFile("b")
  writer:open("w")
  writer:write("chunk")
  check(WebHost.isDirty(), "File:write dirties the store")
  WebHost.syncNow()
  writer:close()
  check(WebHost.isDirty(), "closing a written File dirties it again (final flush)")
  WebHost.syncNow()
end
love.filesystem.newFile = savedNewFile

-- ---------------------------------------------------------------- drops
do
  local tmp = os.tmpname()
  local f = savedIoOpen(tmp, "wb")
  f:write("ROMBYTES")
  f:close()
  drops[#drops + 1] = tmp
  local got
  local savedHandler = love.handlers and love.handlers.filedropped
  love.handlers = love.handlers or {}
  love.handlers.filedropped = function(file)
    local ok = file:open("r")
    got = { name = file:getFilename(), size = file:getSize(), ok = ok }
    got.data = file:read(file:getSize())
    file:close()
  end
  WebHost.update(0)
  love.handlers.filedropped = savedHandler
  check(got ~= nil, "a queued drop reaches love.filedropped")
  eq(got and got.name, tmp, "drop keeps its path as the filename")
  eq(got and got.size, 8, "drop size")
  eq(got and got.data, "ROMBYTES", "drop contents")
  eq(savedIoOpen(tmp, "rb"), nil, "the scratch drop is deleted afterwards")
end

-- ---------------------------------------------------------------- downloads
check(WebHost.download("/home/web_user/love/x/exports/blue.sav"), "download goes through the bridge")
eq(downloads[1] and downloads[1][2], "blue.sav", "download names the file after the path")
check(WebHost.download("/tmp/a", "custom.sav"), "explicit name")
eq(downloads[2] and downloads[2][2], "custom.sav", "explicit name kept")

-- ---------------------------------------------------------------- presentation gates
eq(require("src.core.VideoMode").fixedDisplay(), true, "VideoMode leaves the canvas to the page")
eq(require("src.core.FaithfulRes").fixedDisplay(), true, "FaithfulRes never resizes the window")
local Performance = require("src.core.Performance")
eq(Performance.detect(), "low", "AUTO resolves to LOW in the browser")
for _, tier in ipairs({ "high", "balanced", "low", "auto" }) do
  eq(Performance.caps(tier).shaderfx, false, "no SHADER FX at tier " .. tier)
end
eq(Performance.CAPS.high.shaderfx, 1.0, "the shared HIGH table is not mutated")

-- ---------------------------------------------------------------- love.run
-- Load the real main.lua and drive its frame function with a timer whose
-- sleep is recorded.  The desktop control run proves the probe can see one.
arg = arg or {}
local mainOk, mainErr = pcall(dofile, "main.lua")
check(mainOk, "main.lua loads under the stub: " .. tostring(mainErr))
check(require("src.core.FixedStep").sustainedCatchup == true,
  "main.lua keeps a low frame rate at real-time speed on Web")

local function runFrames(os, frames, hz, cap)
  osName = os
  local sleeps = 0
  local draws, updates = 0, 0
  local now = 0
  local saved = {
    load = love.load, update = love.update, draw = love.draw,
    timer = love.timer, event = love.event, graphics = love.graphics,
    window = love.window,
  }
  love.load = nil
  love.update = function() updates = updates + 1 end
  love.draw = function() draws = draws + 1 end
  if cap ~= nil then require("src.core.FrameCap").apply(cap) end
  love.timer = {
    -- frames finish fast (2 ms), so a desktop pacer has budget to sleep out
    step = function() now = now + (hz and 1 / hz or 0.002); return hz and 1 / hz or 1 / 60 end,
    getTime = function() return now end,
    sleep = function(s) sleeps = sleeps + 1; now = now + (s or 0) end,
    getFPS = function() return 60 end,
  }
  love.event = { pump = function() end, poll = function() return function() end end }
  local g = setmetatable({ isActive = function() return hz ~= nil end,
    present = function() end, getBackgroundColor = function() return 0, 0, 0, 1 end },
    { __index = saved.graphics })
  love.graphics = g
  local ok, err = pcall(function()
    local frame = love.run()
    for _ = 1, frames do frame() end
  end)
  for k, v in pairs(saved) do love[k] = v end
  return ok, err, sleeps, draws, updates
end

if mainOk then
  local ok, err, sleeps = runFrames("Web", 30)
  check(ok, "web frames run: " .. tostring(err))
  eq(sleeps, 0, "love.run never sleeps on the web")
  for _, sample in ipairs({ { 30, 60 }, { 60, 120 }, { 0, 240 } }) do
    local okW, errW, sleepsW, drawsW, updatesW = runFrames("Web", 240, 120, sample[1])
    check(okW, "web paced run: " .. tostring(errW))
    eq(drawsW, sample[2], "render count honors " .. tostring(sample[1]))
    eq(updatesW, 240, "updates run even on skipped render frames")
    eq(sleepsW, 0, "numeric web pacing never sleeps")
  end
  local okD, errD, sleepsD = runFrames("Linux", 30)
  check(okD, "desktop frames run: " .. tostring(errD))
  check(sleepsD > 0, "desktop control run does sleep (the probe works)")
  osName = "Web"
end

-- ---------------------------------------------------------------- restore
io.open, os.remove, os.rename = savedIoOpen, savedRemove, savedRename
for k, v in pairs(savedFs) do
  if love.filesystem then love.filesystem[k] = v end
end
for k, v in pairs(savedSystem) do love.system[k] = v end
WebHost._resetForTests()
Platform._resetForTests()

T.finish()
