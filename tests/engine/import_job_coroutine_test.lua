-- src/import/ImportJob.lua's coroutine path: the one the browser build takes
-- (no threads), stepped a slice per frame.  No pokered cite: port-only
-- import plumbing.
--
-- Runs under both interpreters; scripts/ci/lua51_compat.sh runs it under
-- PUC Lua 5.1, which cannot yield through a plain pcall -- the bug that
-- failed every browser import on the first progress report.
--   luajit tests/engine/import_job_coroutine_test.lua
--   lua5.1 tests/engine/import_job_coroutine_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local published, steps = {}, 0
package.loaded["src.import.RomManifest"] = { decode = function() return {} end }
package.loaded["src.import.CacheFs"] = {
  prefix = "base", removeTree = function() end, remove = function() end,
}
package.loaded["src.import.CacheContract"] = {
  MARKER_PATH = "marker",
  publish = function(version) published[#published + 1] = version return true end,
}
local failNext = false
local Extractor = {
  new = function(_, _, progress)
    return { run = function()
      for i = 1, 3 do
        steps = steps + 1
        progress(i, 3, "Stage " .. i)
      end
      if failNext then error("bad bank", 0) end
    end }
  end,
}
package.loaded["src.import.RomExtractor"] = Extractor
package.loaded["src.import.RomExtractorGen2"] = Extractor
package.loaded["src.import.RomExtractorGen3"] = Extractor

local ImportJob = require("src.import.ImportJob")
local CacheFs = package.loaded["src.import.CacheFs"]

local function start(version)
  local job = setmetatable({ version = version, prefix = "cache_" .. version,
    state = "working", progress = 0 }, ImportJob)
  job:_startCoroutine("rom bytes")
  return job
end

local job = start("red")
local states = {}
for _ = 1, 10 do
  states[#states + 1] = job:step(0)
  if job.state ~= "working" then break end
end
eq(job.state, "done", "the coroutine import finishes (" .. _VERSION .. "): " .. tostring(job.error))
check(#states >= 3, "one progress report per step, not all at once")
eq(steps, 3, "the extractor ran to the end")
eq(published[1], "red", "and the cache was published")
eq(CacheFs.prefix, "base", "the cache prefix is restored")

failNext = true
job = start("gold")
for _ = 1, 10 do
  job:step(0)
  if job.state ~= "working" then break end
end
eq(job.state, "error", "an extractor error fails the job")
check(tostring(job.error):find("bad bank", 1, true) ~= nil, "with its message: " .. tostring(job.error))
eq(CacheFs.prefix, "base", "and the cache prefix is still restored")

T.finish("import job coroutine")
