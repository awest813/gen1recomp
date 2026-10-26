-- One ROM import, from file bytes to a published cache, with no UI attached.
--
-- verify(data, name) unwraps a .zip/.7z, checks the size and the SHA-1
-- against GameVersion's accepted dumps, and names the game.  start() clears
-- that game's old cache and runs the extractor -- on a worker thread where
-- the host has working threads, as a coroutine stepped from step() where it
-- does not (the browser build, POKEPORT_NO_THREAD=1).  The completion marker
-- is written last, on this thread, so CacheContract.isReady() never sees a
-- half-filled tree.
--
-- Any front end can drive this: call step() once a frame and read
-- job.state ("working" / "done" / "error"), job.stage, job.progress and
-- job.error.

local GameVersion = require("src.core.GameVersion")
local CacheContract = require("src.import.CacheContract")

local ImportJob = {}
ImportJob.__index = ImportJob

ImportJob.ROM_BYTES = { [1048576] = 1, [2097152] = 2, [16777216] = 3 }

local function sha1(data)
  local digest = love.data.hash("sha1", data)
  if type(digest) == "userdata" and digest.getString then
    digest = digest:getString()
  end
  return love.data.encode("string", "hex", digest)
end
ImportJob.sha1 = sha1

local function isRomName(name)
  return type(name) == "string" and name:lower():match("%.gb[ac]?$") ~= nil
end

local function acceptedSize(n) return ImportJob.ROM_BYTES[n] ~= nil end

-- The game a ROM image is, or nil plus a reason a player can act on.
-- `visible(version)` (optional) hides games the front end does not offer.
function ImportJob.verify(data, displayName, visible)
  if type(data) ~= "string" or data == "" then
    return nil, "The selected file could not be read."
  end
  local RomArchive = require("src.import.RomArchive")
  local kind = RomArchive.kind(data)
  if kind then
    if #data > RomArchive.MAX_ARCHIVE_BYTES then
      return nil, ("That .%s is %.1f MiB, too large to hold one cartridge.")
        :format(kind, #data / 1048576)
    end
    local bytes, entry = RomArchive.unwrap(data, displayName, {
      isRomName = isRomName,
      acceptedSize = acceptedSize,
      prefer = function(candidate)
        return GameVersion.forSha1(sha1(candidate)) ~= nil
      end,
    })
    if not bytes then return nil, entry end
    data = bytes
    displayName = displayName and (displayName .. " / " .. entry) or entry
  end
  if not acceptedSize(#data) then
    return nil, ("That file is %.2f MiB. A Game Boy ROM is 1 MiB, a Game Boy "
      .. "Color ROM 2 MiB, a Game Boy Advance ROM 16 MiB."):format(#data / 1048576)
  end
  local hash = sha1(data)
  local version = GameVersion.forSha1(hash)
  if version and visible and not visible(version) then version = nil end
  if not version then
    return nil, ("Unsupported ROM (SHA-1 %s). Only the clean US releases "
      .. "listed in the README are accepted; patched or trimmed dumps never "
      .. "verify."):format(hash)
  end
  return { version = version, sha1 = hash, data = data,
           displayName = displayName }
end

-- Drop a game's previous cache before refilling it.
local function clearCache(prefix)
  local CacheFs = require("src.import.CacheFs")
  local saved = CacheFs.prefix
  CacheFs.prefix = prefix
  local ok, err = pcall(function()
    CacheFs.removeTree("data/generated")
    CacheFs.removeTree("assets/generated")
    CacheFs.remove(CacheContract.MARKER_PATH)
  end)
  CacheFs.prefix = saved
  return ok, err
end

local function extractorFor(version)
  local gen = GameVersion.generation(version)
  if gen == 3 then return require("src.import.RomExtractorGen3") end
  if gen == 2 then return require("src.import.RomExtractorGen2") end
  return require("src.import.RomExtractor")
end

local function threadsUsable()
  if os.getenv("POKEPORT_NO_THREAD") == "1" then return false end
  if not (love.thread and love.thread.newThread) then return false end
  local okP, Platform = pcall(require, "src.core.Platform")
  return not okP or not Platform.hasThreads or Platform.hasThreads()
end

-- Begin importing a verified ROM (the table verify() returned).
function ImportJob.start(rom)
  local info = GameVersion.info(rom.version)
  local job = setmetatable({
    version = rom.version, sha1 = rom.sha1, displayName = rom.displayName,
    prefix = info.cachePrefix, state = "working",
    stage = "Preparing game data", progress = 0,
  }, ImportJob)
  local ok, err = clearCache(job.prefix)
  if not ok then return job:fail(err) end
  if threadsUsable() and job:_startThread(rom.data) then return job end
  job:_startCoroutine(rom.data)
  return job
end

function ImportJob:fail(err)
  self.state, self.error = "error", tostring(err)
  self.thread, self.worker = nil, nil
  return self
end

function ImportJob:_startThread(data)
  local ok, thread = pcall(love.thread.newThread, "src/import/ExtractThread.lua")
  if not ok or not thread then return false end
  local tag = tostring(self):match("0x%x+") or tostring(os.time())
  local progressName, resultName = "import_progress_" .. tag, "import_result_" .. tag
  self.progressChannel = love.thread.getChannel(progressName)
  self.resultChannel = love.thread.getChannel(resultName)
  self.progressChannel:clear()
  self.resultChannel:clear()
  local started, result = pcall(thread.start, thread, self.version, self.prefix,
    data, progressName, resultName, self.sha1)
  if not started or result == false then return false end
  self.thread = thread
  return true
end

function ImportJob:_startCoroutine(data)
  local job = self
  self.worker = coroutine.create(function()
    local CacheFs = require("src.import.CacheFs")
    local saved = CacheFs.prefix
    CacheFs.prefix = job.prefix
    local manifest = require("src.import.RomManifest").decode(job.version)
    local extractor = extractorFor(job.version).new(data, manifest,
      function(progress, total, stage)
        job.stage, job.progress = stage, progress / math.max(1, total)
        coroutine.yield()
      end, job.sha1)
    local ok, err = pcall(extractor.run, extractor)
    CacheFs.prefix = saved
    if not ok then error(err, 0) end
  end)
end

function ImportJob:_finish()
  local CacheFs = require("src.import.CacheFs")
  local saved = CacheFs.prefix
  CacheFs.prefix = self.prefix
  local ok, err = CacheContract.publish(self.version, CacheFs, self.sha1)
  CacheFs.prefix = saved
  if not ok then return self:fail("could not finish the game data: " .. tostring(err)) end
  local SaveConvert = package.loaded["src.save_convert.SaveConvert"]
  if GameVersion.generation(self.version) == 2 and SaveConvert
      and SaveConvert.invalidateGen2Data then
    SaveConvert.invalidateGen2Data(self.version)
  end
  self.state, self.progress, self.stage = "done", 1, "Ready"
  self.thread, self.worker = nil, nil
  return self
end

-- Advance the job; `budget` seconds of extractor time for the coroutine path.
function ImportJob:step(budget)
  if self.state ~= "working" then return self.state end
  if self.thread then
    local msg = self.progressChannel:pop()
    while msg do
      self.stage = msg.stage or self.stage
      self.progress = (msg.progress or 0) / math.max(1, msg.total or 1)
      msg = self.progressChannel:pop()
    end
    local res = self.resultChannel:pop()
    if not res then
      local threadError = self.thread.getError and self.thread:getError()
      if threadError then self:fail(threadError) end
      return self.state
    end
    if not res.ok then return self:fail(res.error).state end
    return self:_finish().state
  end
  if self.worker then
    local clock = love.timer and love.timer.getTime
    local deadline = clock and (clock() + (budget or 0.008))
    repeat
      local ok, err = coroutine.resume(self.worker)
      if not ok then return self:fail(err).state end
      if coroutine.status(self.worker) == "dead" then
        return self:_finish().state
      end
    until not deadline or clock() >= deadline
  end
  return self.state
end

return ImportJob
