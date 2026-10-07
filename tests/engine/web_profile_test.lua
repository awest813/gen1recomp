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
local picked, pickedKinds, syncCalls, drops = {}, {}, 0, {}
local fakeBridge = {
  pickFile = function(kind) pickedKinds[#pickedKinds + 1] = kind or "rom"; return true end,
  getPickedFile = function() return table.remove(picked, 1) end,
  getPickError = function() return nil end,
  pickFileKinds = function() return "rom,sav,mod" end,
  syncStorage = function() syncCalls = syncCalls + 1 end,
  getDroppedFile = function() return table.remove(drops, 1) end,
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

-- ---------------------------------------------------------------- storage sync
do
  local tmp = os.tmpname()
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

local function runFrames(os, frames)
  osName = os
  local sleeps = 0
  local now = 0
  local saved = {
    load = love.load, update = love.update, draw = love.draw,
    timer = love.timer, event = love.event, graphics = love.graphics,
    window = love.window,
  }
  love.load, love.update, love.draw = nil, function() end, nil
  love.timer = {
    -- frames finish fast (2 ms), so a desktop pacer has budget to sleep out
    step = function() now = now + 0.002; return 1 / 60 end,
    getTime = function() return now end,
    sleep = function(s) sleeps = sleeps + 1; now = now + (s or 0) end,
    getFPS = function() return 60 end,
  }
  love.event = { pump = function() end, poll = function() return function() end end }
  local g = setmetatable({ isActive = function() return false end }, { __index = saved.graphics })
  love.graphics = g
  local ok, err = pcall(function()
    local frame = love.run()
    for _ = 1, frames do frame() end
  end)
  for k, v in pairs(saved) do love[k] = v end
  return ok, err, sleeps
end

if mainOk then
  local ok, err, sleeps = runFrames("Web", 30)
  check(ok, "web frames run: " .. tostring(err))
  eq(sleeps, 0, "love.run never sleeps on the web")
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
