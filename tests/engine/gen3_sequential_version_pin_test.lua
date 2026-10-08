-- RomExtractorGen3:run pins GameVersion to the ROM's version for the whole
-- run.  The extract modules resolve the layout family through
-- GameVersion.get() (src/import/gba/family.lua); worker threads set it
-- themselves (extract_worker.lua), but the sequential fallback -- the only
-- path where threads are unavailable, as in the browser -- ran with the
-- launcher's game active, so an Emerald import from the Red tab picked the
-- FRLG family and failed in map_catalog (FRLG_MAP_TO_FR is nil for Emerald).
--   luajit tests/engine/gen3_sequential_version_pin_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local eq, check = T.eq, T.check

local GameVersion = require("src.core.GameVersion")
local Family = require("src.import.gba.family")
local CacheFs = require("src.import.CacheFs")
local Extractor = require("src.import.RomExtractorGen3")

local EMERALD_SHA1 = "f3ae088181bf583e55daf962a92bb46f4f1d07b7"
CacheFs.exists = function() return true end
CacheFs.write = function() return true end

local function extractor(task)
  local ext = setmetatable({
    version = "emerald",
    romSha1 = EMERALD_SHA1,
    plan = { sequential = { "probe" } },
    _lastPct = 0,
  }, Extractor)
  ext.writeRequiredMarkers = function() end
  ext.report = function() end
  ext.runParallel = function() return false, "no threads" end
  ext.runTask = task
  return ext
end

do
  GameVersion.set("red")
  local seen, family
  local ext = extractor(function()
    seen, family = GameVersion.get(), Family.active().game
    return true
  end)
  local result = ext:run()
  eq(seen, "emerald", "the sequential stage runs with the ROM's version active")
  eq(family, "emerald", "and resolves the Emerald layout family, not FRLG")
  eq(GameVersion.get(), "red", "the launcher's version is restored afterwards")
  check(result and result.romSha1 == EMERALD_SHA1, "run still returns its result")
end

do
  GameVersion.set("blue")
  local ext = extractor(function() return false, "fixture failure" end)
  local ok, err = pcall(ext.run, ext)
  check(not ok and tostring(err):find("fixture failure", 1, true),
    "a failing stage still raises its error")
  eq(GameVersion.get(), "blue", "and the version is restored on failure too")
end

-- the importer runs run() inside a coroutine that yields progress; under
-- PUC Lua 5.1 a yield cannot cross pcall, so the yields must pass through
do
  GameVersion.set("red")
  local resumedAs
  local ext = extractor(function()
    local reply = coroutine.yield("progress", nil, 3)
    resumedAs = GameVersion.get()
    return reply == "go"
  end)
  local co = coroutine.create(function() return ext:run() end)
  local ok, a, b, c = coroutine.resume(co)
  check(ok and a == "progress" and b == nil and c == 3,
    "a stage's yield reaches the importer's coroutine, nils included")
  eq(GameVersion.get(), "red", "while suspended the launcher's version is back")
  local ok2, result = coroutine.resume(co, "go")
  check(ok2 and result and result.romSha1 == EMERALD_SHA1,
    "resuming finishes the run with the importer's reply delivered")
  eq(resumedAs, "emerald", "and the body runs pinned again after the resume")
  eq(GameVersion.get(), "red", "and restores the version")
end

-- the extract stages report progress from under their own pcalls: on PUC
-- 5.1 that yield only works because run() swaps in a yield-safe pcall
do
  GameVersion.set("red")
  local realPcall = pcall
  local ext = extractor(function()
    local ok, reply = pcall(function() return coroutine.yield("tick") end)
    return ok and reply == "go"
  end)
  local co = coroutine.create(function() return ext:run() end)
  local ok, a = coroutine.resume(co)
  check(ok and a == "tick", "a yield from under a stage's pcall reaches the importer")
  check(pcall == realPcall, "the real pcall is back while the import is suspended")
  local ok2, result = coroutine.resume(co, "go")
  check(ok2 and result and result.romSha1 == EMERALD_SHA1, "and the stage finishes")
  check(pcall == realPcall, "and after it")
end

T.finish()
