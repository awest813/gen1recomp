-- Browser audio feed cost (src/core/ChipAudio.lua, no worker thread): the
-- main-thread prewarm and the synchronous music fill must not churn the
-- PUC Lua heap, and must queue exactly the PCM they did before.
--   * a main-thread prewarm job reuses the previous job's sample table
--     instead of growing a fresh one (~500 KB of dead arrays per 1 s effect)
--   luajit tests/engine/chip_audio_web_feed_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")
love.system = love.system or {}
local savedGetOS = love.system.getOS
love.system.getOS = function() return "Web" end

local Platform = require("src.core.Platform")
Platform._resetForTests()
check(not Platform.hasThreads(), "faked web host has no threads")

local now = 0
local savedTimer = love.timer
love.timer = { getTime = function() now = now + 0.0001; return now end }

-- SoundData that hashes the exact doubles setSample stores (frexp is exact
-- and allocates nothing, so the hashing adds no garbage of its own)
local frexp = math.frexp
local TWO32 = 4294967296
local SD = {}
SD.__index = SD
function SD:setSample(index, a, b)
  local value = b == nil and a or b
  local m, e = frexp(value)
  m = m * 9007199254740992
  local lo = m % TWO32
  local h = self.hash
  h = (h * 65599 + lo + index) % TWO32
  self.hash = (h * 65599 + (m - lo) / TWO32 + e + 2048) % TWO32
end
function SD:getSampleCount() return self.samples end
function SD:getChannelCount() return self.channels end
function SD:getSampleRate() return self.rate end
function SD:getBitDepth() return 16 end
function SD:getDuration() return self.samples / self.rate end
local soundDatas = 0
local savedNewSoundData = love.sound.newSoundData
love.sound.newSoundData = function(samples, rate, _, channels)
  soundDatas = soundDatas + 1
  return setmetatable({ samples = samples, rate = rate,
    channels = channels or 1, hash = 0 }, SD)
end

local Source = {}
Source.__index = Source
function Source:play() self.playing = true return true end
function Source:stop() self.playing = false end
function Source:pause() self.playing = false end
function Source:isPlaying() return self.playing == true end
function Source:setVolume(v) self.volume = v end
function Source:getVolume() return self.volume or 1 end
function Source:setPitch() end
function Source:setLooping() end
function Source:release() end
local savedAudio = love.audio
love.audio = {
  newSource = function(sd) return setmetatable({ sd = sd }, Source) end,
  getActiveSourceCount = function() return 0 end,
}

local ChipSynth = require("src.core.ChipSynth")
local ChipAsm = require("src.audio.ChipAsm")
local ChipAudio = require("src.core.ChipAudio")
ChipSynth.setChannelVolumes({ 1, 1, 1, 1 })
ChipSynth.setChannelPitches({ 1, 1, 1, 1 })
ChipSynth.setStereo(false)

local data = { audio = {} }
-- ~1 s at 44100 Hz
local sfx = ChipAsm.sfx{ channels = {
  { hw = 1, program = {
    { squareNote = { len = 8, volume = 15, fade = 1, frequency = 0x600 } },
    { squareNote = { len = 16, volume = 12, fade = 3, frequency = 0x700 } },
    { squareNote = { len = 16, volume = 12, fade = 3, frequency = 0x680 } },
    { squareNote = { len = 16, volume = 12, fade = 2, frequency = 0x640 } },
  } },
  { hw = 4, program = {
    { noiseNote = { len = 16, volume = 14, fade = 2, parameter = 0x33 } },
    { noiseNote = { len = 16, volume = 12, fade = 3, parameter = 0x51 } },
  } },
} }

local function sfxOptions(pitch)
  return { frequencyOffset = pitch, frameTicks = 0x100 }
end

-- KB allocated while `fn` runs, with the collector held off
local function allocated(fn)
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  fn()
  local kb = collectgarbage("count") - before
  collectgarbage("restart")
  return kb
end

local function pumpUntilIdle()
  local ticks = 0
  while ChipAudio._effectStateForTest().mainJobs > 0 and ticks < 5000 do
    ChipAudio.pumpPrewarm(0.002)
    ticks = ticks + 1
  end
  return ticks
end

-- ---------------------------------------------------------------- prewarm jobs
do
  -- the first job grows its own table (and leaves it behind as the spare)
  check(ChipAudio.prewarmSfx(data, "FEED", 1, nil, sfx), "first prewarm queued")
  local firstKB = allocated(pumpUntilIdle)
  local reference = ChipSynth.renderEffectData(data, sfx, sfxOptions(2))
  check(reference and reference:getSampleCount() > 30000,
    "the fixture effect is long enough to matter (" ..
    tostring(reference and reference:getSampleCount()) .. " samples)")

  check(ChipAudio.prewarmSfx(data, "FEED", 2, nil, sfx), "second prewarm queued")
  local secondKB = allocated(pumpUntilIdle)
  check(secondKB < 64,
    ("a later prewarm reuses the sample table (%.1f KB, first %.1f KB)")
      :format(secondKB, firstKB))
  check(firstKB > secondKB * 4, "and the first one really was the expensive one")

  local src = ChipAudio.newSfx(data, "FEED", 2, nil, sfx)
  check(src and src.sd, "the prewarmed effect plays")
  if src and src.sd and reference then
    eq(src.sd:getSampleCount(), reference:getSampleCount(), "same length")
    eq(src.sd.hash, reference.hash, "sample-identical to renderEffectData")
  end

  -- a play that lands mid-prewarm finishes the job on the borrowed table
  check(ChipAudio.prewarmSfx(data, "FEED", 3, nil, sfx), "third prewarm queued")
  ChipAudio.pumpPrewarm(0.0003)
  check(ChipAudio._effectStateForTest().mainJobs == 1, "still running")
  local mid = ChipAudio.newSfx(data, "FEED", 3, nil, sfx)
  local midReference = ChipSynth.renderEffectData(data, sfx, sfxOptions(3))
  check(mid and mid.sd and midReference and mid.sd.hash == midReference.hash,
    "a play finishing a borrowed-table job matches renderEffectData")

  -- two queued jobs: only one borrows; both stay exact
  check(ChipAudio.prewarmSfx(data, "FEED", 4, nil, sfx), "queue a")
  check(ChipAudio.prewarmSfx(data, "FEED", 5, nil, sfx), "queue b")
  ChipAudio.pumpPrewarm(0.0003)
  local b = ChipAudio.newSfx(data, "FEED", 5, nil, sfx)
  pumpUntilIdle()
  local a = ChipAudio.newSfx(data, "FEED", 4, nil, sfx)
  local refA = ChipSynth.renderEffectData(data, sfx, sfxOptions(4))
  local refB = ChipSynth.renderEffectData(data, sfx, sfxOptions(5))
  check(a and a.sd and a.sd.hash == refA.hash, "interleaved job a is exact")
  check(b and b.sd and b.sd.hash == refB.hash, "interleaved job b is exact")
end

love.audio, love.timer = savedAudio, savedTimer
love.sound.newSoundData = savedNewSoundData
love.system.getOS = savedGetOS
Platform._resetForTests()
T.finish()
