-- Browser (no worker thread) audio path: docs/proposals/web-port.md phase 3.
--   * ChipSynth.newEffectJob renders exactly renderEffectData's PCM, sliced
--   * ChipAudio's main-thread prewarm fills the effect cache a few ms per
--     update, and newSfx then takes it instead of rendering on the play frame
--   * web music prefills one 2048-sample buffer instead of 4 x 8192
--   luajit tests/engine/chip_audio_web_test.lua
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

-- a clock the prewarm budget can read
local now = 0
local savedTimer = love.timer
love.timer = { getTime = function() now = now + 0.0001; return now end }

-- sources: static ones remember their SoundData, queueable ones their queue
local Source = {}
Source.__index = Source
function Source:play() self.playing = true return true end
function Source:stop() self.playing = false end
function Source:pause() self.playing = false end
function Source:isPlaying() return self.playing == true end
function Source:setVolume(v) self.volume = v end
function Source:getVolume() return self.volume or 1 end
function Source:setPitch() end
function Source:getPitch() return 1 end
function Source:setLooping() end
function Source:release() end
function Source:getDuration() return self.sd and self.sd:getDuration() or 0 end
function Source:queue(sd) self.queued[#self.queued + 1] = sd; self.free = self.free - 1; return true end
function Source:getFreeBufferCount() return self.free end
local savedAudio = love.audio
love.audio = {
  newSource = function(sd) return setmetatable({ sd = sd }, Source) end,
  newQueueableSource = function(_, _, _, count)
    return setmetatable({ queued = {}, free = count or 32 }, Source)
  end,
  getActiveSourceCount = function() return 0 end,
}

local ChipSynth = require("src.core.ChipSynth")
local ChipAsm = require("src.audio.ChipAsm")
local ChipAudio = require("src.core.ChipAudio")
ChipSynth.setChannelVolumes({ 1, 1, 1, 1 })
ChipSynth.setChannelPitches({ 1, 1, 1, 1 })
if ChipSynth._setBulkWritesForTest then ChipSynth._setBulkWritesForTest(false) end

local data = { audio = {} }
local sfx = ChipAsm.sfx{ channels = {
  { hw = 1, program = {
    { squareNote = { len = 8, volume = 15, fade = 1, frequency = 0x600 } },
    { squareNote = { len = 16, volume = 12, fade = 3, frequency = 0x700 } },
  } },
  { hw = 4, program = {
    { noiseNote = { len = 16, volume = 14, fade = 2, parameter = 0x33 } },
  } },
} }

local function samples(sd)
  local out = {}
  for i = 0, sd:getSampleCount() - 1 do
    out[#out + 1] = sd:getSample(i, 1)
    out[#out + 1] = sd:getSample(i, 2)
  end
  return out
end

-- ---------------------------------------------------------------- job == render
do
  local whole = ChipSynth.renderEffectData(data, sfx, { frequencyOffset = 0, frameTicks = 0x100 })
  check(whole ~= nil, "the fixture effect renders")
  local job = ChipSynth.newEffectJob(data, sfx, { frequencyOffset = 0, frameTicks = 0x100 })
  local steps = 0
  while not job:step(97) do steps = steps + 1 end
  check(steps > 10, "the job really ran in slices (" .. steps .. ")")
  check(job.result ~= nil, "the job produced a buffer")
  if whole and job.result then
    eq(job.result:getSampleCount(), whole:getSampleCount(), "same length")
    local a, b = samples(whole), samples(job.result)
    local same = #a == #b
    for i = 1, #a do if a[i] ~= b[i] then same = false break end end
    check(same, "sample-identical to renderEffectData")
  end
  local tiny = ChipSynth.newEffectJob(data, nil, {})
  eq(tiny, nil, "no header, no job")
end

-- ---------------------------------------------------------------- main-thread prewarm
do
  local renders = 0
  local realRender = ChipSynth.renderEffectData
  ChipSynth.renderEffectData = function(...) renders = renders + 1; return realRender(...) end

  check(ChipAudio.prewarmSfx(data, "TEST", nil, nil, sfx), "prewarm queues on the main thread")
  check(ChipAudio.prewarmSfx(data, "TEST", nil, nil, sfx), "a second prewarm of the same effect dedups")
  eq(ChipAudio._effectStateForTest().mainJobs, 1, "one main-thread job queued")
  local ticks, state = 0, nil
  repeat
    now = now + 1 / 60 -- one real frame per update (the pump runs once a frame)
    ChipAudio.update()
    ticks = ticks + 1
    state = ChipAudio._effectStateForTest()
  until state.ready > 0 or ticks > 500
  eq(state.ready, 1, "the prewarm finished into the effect cache")
  eq(state.mainJobs, 0, "and left the main-thread queue")
  check(ticks > 1 and ticks < 500, "the prewarm spread over several updates (" .. ticks .. ")")
  local src = ChipAudio.newSfx(data, "TEST", nil, nil, sfx)
  check(src ~= nil and src.sd ~= nil, "newSfx returns a source")
  eq(renders, 0, "newSfx took the prewarmed PCM instead of rendering")

  -- a play that lands while its prewarm is still running finishes that job
  check(ChipAudio.prewarmSfx(data, "TEST", 3, nil, sfx), "prewarm a pitched variant")
  ChipAudio.update()
  local src2 = ChipAudio.newSfx(data, "TEST", 3, nil, sfx)
  check(src2 ~= nil and src2.sd ~= nil, "a play mid-prewarm still gets a source")
  eq(renders, 0, "and finishes the in-flight job rather than re-rendering")

  ChipSynth.renderEffectData = realRender
end

-- pumpPrewarm: a load screen can finish the queue synchronously
do
  check(ChipAudio.prewarmSfx(data, "TEST", 7, nil, sfx), "queue another variant")
  eq(ChipAudio._effectStateForTest().mainJobs, 1, "queued, not rendered")
  local before = ChipAudio._effectStateForTest().ready
  eq(ChipAudio.pumpPrewarm(10), 0, "pumpPrewarm drains the queue within its budget")
  eq(ChipAudio._effectStateForTest().ready, before + 1, "and the result is cached")
  eq(ChipAudio.pumpPrewarm(10), 0, "an empty queue is a no-op")
end

-- ---------------------------------------------------------------- web music prefill
do
  local song = ChipAsm.song{
    tempo = 0x100,
    channels = { { hw = 1, program = {
      { duty = 2 }, { notetype = { speed = 12, volume = 12, fade = 0 } }, { octave = 4 },
      { label = "body" }, { note = "C", len = 8 }, { loop = { count = 0, to = "body" } },
    } } },
  }
  local source = ChipAudio.playMusic(data, song, true)
  check(source ~= nil, "web music starts on the synchronous path")
  if source then
    eq(#source.queued, 1, "one buffer prefilled at song start")
    eq(source.queued[1] and source.queued[1]:getSampleCount(), 2048, "a 2048-sample buffer")
    -- catch-up ticks inside one real frame: only the low-water rescue fills
    local frozen = now
    love.timer = { getTime = function() return frozen end }
    for _ = 1, 12 do ChipAudio.update() end
    eq(#source.queued, 2, "12 catch-up ticks in one frame fill only to the low-water mark")
    -- one tick per real frame: each adds a slice, so the queue keeps growing
    for _ = 1, 12 do
      frozen = frozen + 1 / 60
      ChipAudio.update()
    end
    check(#source.queued >= 5, "a slice per frame keeps the queue growing (" .. #source.queued .. ")")
  end
  ChipAudio.stopMusic()
end

if ChipSynth._setBulkWritesForTest then ChipSynth._setBulkWritesForTest(true) end
love.audio, love.timer = savedAudio, savedTimer
love.system.getOS = savedGetOS
Platform._resetForTests()
T.finish()
