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
-- job.error.  job.error is always a sentence a player can act on; the
-- technical cause (a Lua error, an OS message) is kept in job.detail and
-- written to the log.  job.progress never moves backwards.
--
-- POKEPORT_IMPORT_TIMING=1 prints every stage change with its time, and a
-- per-stage summary when the import ends.

local GameVersion = require("src.core.GameVersion")
local CacheContract = require("src.import.CacheContract")
local RomIdentify = require("src.import.RomIdentify")

local ImportJob = {}
ImportJob.__index = ImportJob

ImportJob.ROM_BYTES = { [1048576] = 1, [2097152] = 2, [16777216] = 3 }
-- A backup-unit ("copier") header some dumps carry in front of the ROM.
ImportJob.COPIER_HEADER = 512
-- Overdumps: a dumper that read past the end of the cartridge, mirroring or
-- padding the image up to the next power of two.
ImportJob.OVERDUMP_BYTES = { [4194304] = true, [8388608] = true, [33554432] = true }
-- A lock older than this belongs to an import that was killed, not one that
-- is still running (a running one refreshes it every LOCK_REFRESH seconds).
ImportJob.LOCK_PATH = "rom-cache.importing"
ImportJob.LOCK_REFRESH = 5
ImportJob.LOCK_STALE = 20

local TIMING = os.getenv("POKEPORT_IMPORT_TIMING") == "1"

local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

local function hexSha1(data)
  local digest = love.data.hash("sha1", data)
  if type(digest) == "userdata" and digest.getString then
    digest = digest:getString()
  end
  return love.data.encode("string", "hex", digest)
end

-- verify() may hash the same bytes twice (once to pick an archive entry, once
-- to accept it); 16 MiB of SHA-1 is worth remembering for one call.
local lastData, lastHash
local function sha1(data)
  if data == lastData and lastHash then return lastHash end
  local hash = hexSha1(data)
  lastData, lastHash = data, hash
  return hash
end
ImportJob.sha1 = sha1

local function isRomName(name)
  return type(name) == "string" and name:lower():match("%.gb[ac]?$") ~= nil
end

local function acceptedSize(n) return ImportJob.ROM_BYTES[n] ~= nil end

-- Sizes worth reading out of an archive: a ROM, a ROM behind a copier
-- header, or an overdump normalize() can trim.
local function plausibleSize(n)
  return acceptedSize(n) or acceptedSize(n - ImportJob.COPIER_HEADER)
    or ImportJob.OVERDUMP_BYTES[n] == true
end

-- The images `data` may hold, most likely first: the file as it is, the file
-- without a copier header, or the start of an overdump.  Each is only a
-- candidate; the SHA-1 still has to match an accepted dump.
local function normalize(data)
  local out = {}
  local n = #data
  if acceptedSize(n) then out[#out + 1] = { bytes = data } end
  if acceptedSize(n - ImportJob.COPIER_HEADER) then
    out[#out + 1] = { bytes = data:sub(ImportJob.COPIER_HEADER + 1),
      note = "a 512-byte copier header was removed" }
  end
  if acceptedSize(n) or ImportJob.OVERDUMP_BYTES[n] then
    for size in pairs(ImportJob.ROM_BYTES) do
      if size < n then
        out[#out + 1] = { bytes = data:sub(1, size), size = size,
          note = "the overdump was trimmed to " .. RomIdentify.formatBytes(size) }
      end
    end
  end
  -- larger trims first: a 32 MiB file is a 16 MiB cart before a 1 MiB one
  table.sort(out, function(a, b)
    if (a.size == nil) ~= (b.size == nil) then return a.size == nil end
    return (a.size or 0) > (b.size or 0)
  end)
  return out
end

local function versionFor(hash, visible)
  local version = GameVersion.forSha1(hash)
  if version and visible and not visible(version) then return nil end
  return version
end

-- The game a ROM image is, or nil plus a reason a player can act on.
-- `visible(version)` (optional) hides games the front end does not offer.
function ImportJob.verify(data, displayName, visible)
  if type(data) ~= "string" then
    return nil, "The selected file could not be read. Check that it still "
      .. "exists and that PK:GB may open it, then choose it again."
  end
  if data == "" then
    return nil, RomIdentify.explain(data, displayName)
  end
  local RomArchive = require("src.import.RomArchive")
  local kind = RomArchive.kind(data)
  if kind then
    if #data > RomArchive.MAX_ARCHIVE_BYTES then
      return nil, ("That .%s is %s, too large to hold one cartridge. Extract "
        .. "the ROM from it and choose the .gb, .gbc or .gba file instead.")
        :format(kind, RomIdentify.formatBytes(#data))
    end
    local bytes, entry = RomArchive.unwrap(data, displayName, {
      isRomName = isRomName,
      acceptedSize = plausibleSize,
      formatBytes = RomIdentify.formatBytes,
      prefer = function(candidate)
        for _, image in ipairs(normalize(candidate)) do
          if versionFor(sha1(image.bytes), visible) then return true end
        end
        return false
      end,
    })
    if not bytes then return nil, entry end
    data = bytes
    displayName = displayName and (displayName .. " / " .. entry) or entry
  end
  local images = normalize(data)
  for _, image in ipairs(images) do
    local hash = sha1(image.bytes)
    local version = versionFor(hash, visible)
    if version then
      return { version = version, sha1 = hash, data = image.bytes,
               displayName = displayName, note = image.note }
    end
  end
  if #images == 0 then
    return nil, RomIdentify.explainSize(#data, data, displayName)
  end
  local first = images[1].bytes
  return nil, RomIdentify.explain(first, displayName, sha1(first), {
    supported = function(game)
      return GameVersion.VERSIONS[game] ~= nil and (not visible or visible(game))
    end,
  })
end

-- ------------------------------------------------------------ messages

-- The first line of a Lua error without its "src/x.lua:12: " locations.
-- A multi-line report ("Parallel extraction error:\n<task>: <cause>") gives
-- its first concrete line.
local function shortCause(err)
  local text = ""
  for line in (tostring(err or "unknown error") .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("%S") and not line:match(":%s*$") then text = line break end
  end
  if text == "" then text = tostring(err or "unknown error") end
  text = text:gsub("[%w_%./\\%-]+%.lua:%d+: ", ""):gsub("^%s+", "")
  if #text > 160 then text = text:sub(1, 157) .. "..." end
  return text
end

local DISK_FULL = { "no space", "disk full", "not enough space", "enospc",
  "quota", "out of space", "device full" }
local NO_ACCESS = { "permission denied", "access is denied", "read%-only",
  "eacces", "erofs", "not permitted" }

local function mentions(text, needles)
  for _, needle in ipairs(needles) do
    if text:find(needle) then return true end
  end
  return false
end

-- A sentence for the player from whatever went wrong.  `name` is the game's
-- display name.
function ImportJob.explainFailure(err, name)
  local raw = tostring(err or "")
  local lower = raw:lower()
  name = name or "the game"
  if mentions(lower, DISK_FULL) then
    return ("There is not enough free disk space to save %s's game data. "
      .. "Free up some space (about 100 MB) and import the ROM again."):format(name)
  end
  if mentions(lower, NO_ACCESS) then
    return ("PK:GB is not allowed to write %s's game data folder. Make sure "
      .. "the folder is not read-only, then import the ROM again."):format(name)
  end
  if lower:find("could not write", 1, true) or lower:find("write failed", 1, true)
      or lower:find("close failed", 1, true) then
    return ("PK:GB could not save %s's game data. Check that the disk has "
      .. "free space (about 100 MB) and that the game folder is not "
      .. "read-only, then import the ROM again."):format(name)
  end
  if lower:find("out of memory", 1, true) or lower:find("not enough memory", 1, true) then
    return ("Your device ran out of memory while importing %s. Close other "
      .. "apps and import the ROM again."):format(name)
  end
  return ("PK:GB could not build %s's game data from this ROM (%s). Import it "
    .. "again; if that fails too, please report it with the log."):format(name, shortCause(raw))
end

-- ------------------------------------------------------------ the cache

local function withPrefix(prefix, fn)
  local CacheFs = require("src.import.CacheFs")
  local saved = CacheFs.prefix
  CacheFs.prefix = prefix
  local ok, a, b = pcall(fn, CacheFs)
  CacheFs.prefix = saved
  if not ok then return false, a end
  return true, a, b
end

-- Drop a game's previous cache before refilling it.  The marker goes first:
-- an import killed halfway through clearing must not leave a "complete"
-- marker over a half-emptied tree.
local function clearCache(prefix)
  return withPrefix(prefix, function(CacheFs)
    CacheFs.remove(CacheContract.MARKER_PATH)
    local clear = CacheFs.clearTree or CacheFs.removeTree
    clear("data/generated")
    clear("assets/generated")
  end)
end

-- Another process importing this game right now (two windows, or a second
-- copy of the app), going by the lock it refreshes while it runs.
local function lockedElsewhere(prefix)
  local ok, raw = withPrefix(prefix, function(CacheFs)
    return CacheFs.read and CacheFs.read(ImportJob.LOCK_PATH)
  end)
  if not ok or type(raw) ~= "string" then return false end
  local stamp = tonumber(raw:match("^(%d+)"))
  return stamp ~= nil and math.abs(os.time() - stamp) < ImportJob.LOCK_STALE
end

function ImportJob:_lock()
  self.lockedAt = os.time()
  withPrefix(self.prefix, function(CacheFs)
    return CacheFs.write(ImportJob.LOCK_PATH, tostring(self.lockedAt) .. "\n")
  end)
end

function ImportJob:_unlock()
  if not self.lockedAt then return end
  self.lockedAt = nil
  withPrefix(self.prefix, function(CacheFs) CacheFs.remove(ImportJob.LOCK_PATH) end)
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

-- Imports running in this process, by cache prefix.
local running = {}
ImportJob._running = running

-- Begin importing a verified ROM (the table verify() returned).
function ImportJob.start(rom)
  local info = GameVersion.info(rom.version)
  local job = setmetatable({
    version = rom.version, sha1 = rom.sha1, displayName = rom.displayName,
    prefix = info.cachePrefix, state = "working", gameName = info.displayName,
    stage = "Getting ready", progress = 0, startedAt = now(), timings = {},
  }, ImportJob)
  if running[job.prefix] and running[job.prefix].state == "working" then
    return job:fail(("%s is already being imported. Wait for that import to "
      .. "finish."):format(info.displayName), "duplicate import")
  end
  if lockedElsewhere(job.prefix) then
    return job:fail(("Another PK:GB window is importing %s right now. Wait for "
      .. "it to finish, or close it and try again."):format(info.displayName),
      "import lock held")
  end
  running[job.prefix] = job
  job:_lock()
  job:_mark("Clearing the old game data")
  local ok, err = clearCache(job.prefix)
  if not ok then return job:fail(err) end
  if threadsUsable() and job:_startThread(rom.data) then return job end
  job:_startCoroutine(rom.data)
  return job
end

-- Fail the job.  `err` is either a finished sentence (with `detail` the
-- technical cause) or a raw error, which is turned into a sentence.
function ImportJob:fail(err, detail)
  if detail == nil then
    detail = tostring(err)
    err = ImportJob.explainFailure(err, self.gameName or self.version)
  end
  self.state, self.error, self.detail = "error", tostring(err), tostring(detail)
  self.thread, self.worker = nil, nil
  if running[self.prefix] == self then running[self.prefix] = nil end
  self:_unlock()
  pcall(function()
    require("src.core.Logger").error("import of %s failed: %s",
      tostring(self.version), tostring(self.detail))
  end)
  if TIMING then self:_report() end
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

-- The coroutine shares CacheFs.prefix with everything else this frame runs,
-- so the job's prefix is only in place while the coroutine itself runs:
-- step() swaps it in before each resume and back out after each yield.
-- Holding it across a yield sent the launcher's own cache reads (and a
-- second job's writes) into this game's folder.
function ImportJob:_startCoroutine(data)
  local job = self
  self.worker = coroutine.create(function()
    local manifest = require("src.import.RomManifest").decode(job.version)
    local extractor = extractorFor(job.version).new(data, manifest,
      function(progress, total, stage)
        job:_progress(progress / math.max(1, total), stage)
        coroutine.yield()
      end, job.sha1)
    -- the progress callback yields: PUC Lua 5.1 (the browser build) cannot
    -- yield through a plain pcall, so use the yield-safe one
    local ok, err = require("src.core.LuaCompat").coPcall(extractor.run, extractor)
    if not ok then error(err, 0) end
  end)
end

-- ------------------------------------------------------------ progress

-- Extractor stage names that mean nothing to a player, and what to show.
local STAGE_WORDS = {
  { "^Initializing Markers", "Getting ready" },
  { "^Markers Ready", "Getting ready" },
  { "^Finalizing (.+)", "Finishing up" },
  { "^Std scripts", "Scripts" },
  { "^Remaining data %(stubs%)", "Finishing up" },
  { "^World Maps: open_rom", "World maps" },
  { "^World Maps: census", "World maps" },
  { "^World Maps: native_pack", "World maps" },
  { "^World Maps: done", "World maps" },
  { "^World Maps: (%a+)", "World maps: %1" },
  { "^Scripts & OW: (.+)", "Scripts and characters" },
  { "^Audio & Intro: Initializing", "Music and intro" },
  { "^Game Data: (.+)", "%1" },
  { "^Extracting$", "Building game data" },
}

-- Make a stage caption readable: known technical names are replaced, and
-- snake_case or "(12/200)" counters are tidied.
function ImportJob.stageText(stage)
  if type(stage) ~= "string" or stage == "" then return nil end
  local text = stage
  for _, row in ipairs(STAGE_WORDS) do
    local replaced, n = text:gsub(row[1], row[2], 1)
    if n > 0 then text = replaced break end
  end
  text = text:gsub("(%a)_(%a)", "%1 %2")
  text = text:gsub("^%l", string.upper)
  return text
end

function ImportJob:_mark(stage)
  local t = now()
  self.timings = self.timings or {}
  if self.lastStage and self.lastStageAt then
    local name = self.lastStage
    self.timings[name] = (self.timings[name] or 0) + (t - self.lastStageAt)
  end
  if stage ~= self.lastStage then
    if TIMING then
      print(("[import timing] %7.3fs %5.1f%%  %s"):format(t - (self.startedAt or t),
        (self.progress or 0) * 100, tostring(stage)))
    end
    self.lastStage = stage
  end
  self.lastStageAt = t
end

-- Record extractor progress: a fraction 0..1 and the raw stage name.
function ImportJob:_progress(fraction, stage)
  fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
  -- a parallel extractor's tasks finish out of order; the bar only goes on
  if fraction > (self.progress or 0) then self.progress = fraction end
  local text = ImportJob.stageText(stage)
  if text then
    self.stage = text
    -- the per-stage timing keys on the extractor's own name, minus counters
    self:_mark((stage:gsub("%s*%(%d+/%d+%)$", "")))
  end
end

-- The slowest stages, for POKEPORT_IMPORT_TIMING=1.
function ImportJob:_report()
  self:_mark(self.state)
  local rows = {}
  for name, secs in pairs(self.timings or {}) do rows[#rows + 1] = { name, secs } end
  table.sort(rows, function(a, b) return a[2] > b[2] end)
  print(("[import timing] %s %s in %.2fs; slowest stages:"):format(
    tostring(self.version), tostring(self.state), now() - (self.startedAt or now())))
  for i = 1, math.min(#rows, 12) do
    print(("[import timing]   %6.3fs  %s"):format(rows[i][2], rows[i][1]))
  end
end

function ImportJob:_finish()
  self:_mark("Saving")
  self.stage = "Saving"
  local CacheFs = require("src.import.CacheFs")
  local saved = CacheFs.prefix
  CacheFs.prefix = self.prefix
  local okP, ok, err = pcall(function()
    return CacheContract.publish(self.version, CacheFs, self.sha1)
  end)
  CacheFs.prefix = saved
  if not okP then ok, err = false, ok end
  if not ok then return self:fail("could not finish the game data: " .. tostring(err)) end
  local SaveConvert = package.loaded["src.save_convert.SaveConvert"]
  if GameVersion.generation(self.version) == 2 and SaveConvert
      and SaveConvert.invalidateGen2Data then
    SaveConvert.invalidateGen2Data(self.version)
  end
  self.state, self.progress, self.stage = "done", 1, "Ready"
  self.thread, self.worker = nil, nil
  if running[self.prefix] == self then running[self.prefix] = nil end
  self:_unlock()
  if TIMING then self:_report() end
  return self
end

-- Advance the job; `budget` seconds of extractor time for the coroutine path.
function ImportJob:step(budget)
  if self.state ~= "working" then return self.state end
  if self.lockedAt and os.time() - self.lockedAt >= ImportJob.LOCK_REFRESH then
    self:_lock()
  end
  if self.thread then
    local msg = self.progressChannel:pop()
    while msg do
      self:_progress((msg.progress or 0) / math.max(1, msg.total or 1), msg.stage)
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
    local CacheFs = require("src.import.CacheFs")
    repeat
      local saved = CacheFs.prefix
      CacheFs.prefix = self.prefix
      local ok, err = coroutine.resume(self.worker)
      CacheFs.prefix = saved
      if not ok then return self:fail(err).state end
      if coroutine.status(self.worker) == "dead" then
        return self:_finish().state
      end
    until not deadline or clock() >= deadline
  end
  return self.state
end

return ImportJob
