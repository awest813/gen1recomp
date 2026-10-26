-- ROM-free ChipSynth workloads shared by the golden-PCM suite
-- (tests/engine/chip_synth_golden_test.lua) and the synth benchmark
-- (tools/bench_chip_synth.lua).  Each case drives one public render path --
-- streamed music buffers (soundData / renderInto) and one-shot effects
-- (renderEffectData) -- over programs that between them reach every branch
-- of the per-sample loop: duty and duty patterns, vibrato, pitch slides,
-- perfect pitch, rising and falling envelopes, wave instruments and levels,
-- drums and their ringing tails across rests, noise in both LFSR widths,
-- the SFX sweep, cry pitch/length, Gen 1 pan, Gen 2 tracks with SOUND on
-- and off.
--
-- The PCM is hashed from the raw doubles the synth hands to setSample, so a
-- hash match means every sample is bit-identical, not just its int16.

local ChipAsm = require("src.audio.ChipAsm")
local ChipSynth = require("src.core.ChipSynth")

local Fixtures = {}

-- -------- Gen 1 programs (ChipAsm)

-- 32-nibble wave tables in the ROM's own 0-15 units
local function waveTable(fn)
  local values = {}
  for index = 0, 31 do values[index + 1] = fn(index) % 16 end
  return values
end

local GEN1_WAVES = {
  waveTable(function(i) return i < 16 and i or 31 - i end),
  waveTable(function(i) return math.floor(i / 2) end),
  waveTable(function(i) return i % 8 < 4 and 15 or 0 end),
  waveTable(function(i) return (i * 7) % 16 end),
  waveTable(function(i) return 8 + math.floor(7 * math.sin(i / 32 * 2 * math.pi)) end),
}

local function gen1Song()
  return ChipAsm.song{
    tempo = 0x90,
    waves = GEN1_WAVES,
    channels = {
      { hw = 1, program = {
        { duty = 2 },
        { notetype = { speed = 12, volume = 13, fade = 3 } },
        { octave = 4 },
        { label = "body" },
        { pan = 0xFF },
        { vibrato = { delay = 6, depth = 3, rate = 2 } },
        { note = "C", len = 8 }, { note = "E", len = 6 }, { note = "G", len = 4 },
        { duty = 1 },
        { notetype = { speed = 6, volume = 9, fade = -2 } },
        { note = "A#", len = 12 },
        { rest = 2 },
        { perfectPitch = true },
        { octave = 5 },
        { note = "D", len = 4 }, { note = "F#", len = 4 },
        { perfectPitch = true },
        { vibrato = { delay = 0, depth = 0, rate = 0 } },
        { pan = 0x5A },
        { notetype = { speed = 12, volume = 15, fade = 7 } },
        { note = "B", len = 16 },
        { octave = 4 },
        { loop = { count = 0, to = "body" } },
      } },
      { hw = 2, program = {
        { dutyPattern = { 0, 1, 2, 3 } },
        { notetype = { speed = 12, volume = 10, fade = 2 } },
        { octave = 3 },
        { label = "body" },
        { note = "G", len = 4 },
        { slide = { len = 2, octave = 4, note = "C" } },
        { note = "A", len = 12 },
        { duty = 3 },
        { notetype = { speed = 8, volume = 6, fade = -5 } },
        { note = "E", len = 10 },
        { rest = 3 },
        { dutyPattern = { 3, 3, 0, 1 } },
        { notetype = { speed = 12, volume = 12, fade = 0 } },
        { slide = { len = 1, octave = 3, note = "D" } },
        { note = "F", len = 8 },
        { loop = { count = 0, to = "body" } },
      } },
      { hw = 3, program = {
        { notetype = { speed = 12, waveLevel = 1, waveInstrument = 0 } },
        { octave = 3 },
        { label = "body" },
        { note = "C", len = 8 }, { note = "G", len = 8 },
        { notetype = { speed = 12, waveLevel = 2, waveInstrument = 2 } },
        { vibrato = { delay = 4, depth = 2, rate = 1 } },
        { note = "D#", len = 12 },
        { notetype = { speed = 6, waveLevel = 3, waveInstrument = 4 } },
        { note = "F", len = 6 }, { rest = 4 },
        { notetype = { speed = 12, waveLevel = 1, waveInstrument = 3 } },
        { vibrato = { delay = 0, depth = 0, rate = 0 } },
        { note = "A", len = 16 },
        { loop = { count = 0, to = "body" } },
      } },
      { hw = 4, program = {
        { notetype = { speed = 12 } },
        { label = "body" },
        { drum = 1, len = 4 }, { drum = 2, len = 4 },
        { drum = 3, len = 2 }, { rest = 2 },
        { drum = 12, len = 4 }, { rest = 8 },
        { drum = 4, len = 4 }, { drum = 5, len = 4 },
        { loop = { count = 0, to = "body" } },
      } },
    },
    drums = {
      [1] = { { len = 1, volume = 13, fade = 1, parameter = 0x10 },
              { len = 2, volume = 10, fade = 2, parameter = 0x21 } },
      [2] = { { len = 2, volume = 15, fade = 3, parameter = 0x5B } },
      [3] = { { len = 1, volume = 12, fade = 1, parameter = 0x33 } },
      [4] = { { len = 4, volume = 14, fade = 4, parameter = 0x6C } },
      [5] = { { len = 1, volume = 9, fade = -1, parameter = 0x02 },
              { len = 1, volume = 11, fade = 2, parameter = 0x45 } },
      [12] = { { len = 3, volume = 15, fade = 2, parameter = 0x4F } },
    },
  }
end

local function gen1Sfx()
  return ChipAsm.sfx{ channels = {
    { hw = 1, program = {
      { pitchSweep = { pace = 2, subtract = false, shift = 3 } },
      { squareNote = { len = 8, volume = 15, fade = 1, frequency = 0x600 } },
      { pitchSweep = { pace = 1, subtract = true, shift = 2 } },
      { squareNote = { len = 12, volume = 12, fade = 3, frequency = 0x700 } },
      { pitchSweep = { pace = 0, subtract = false, shift = 0 } },
      { squareNote = { len = 6, volume = 10, fade = -2, frequency = 0x6C0 } },
    } },
    { hw = 2, program = {
      { duty = 1 },
      { squareNote = { len = 4, volume = 13, fade = 2, frequency = 0x680 } },
      { squareNote = { len = 10, volume = 11, fade = 1, frequency = 0x720 } },
      { executeMusic = true },
      { notetype = { speed = 4, volume = 12, fade = 2 } },
      { octave = 5 },
      { note = "C", len = 4 }, { note = "G", len = 6 },
    } },
    { hw = 4, program = {
      { noiseNote = { len = 16, volume = 14, fade = 2, parameter = 0x33 } },
      { noiseNote = { len = 6, volume = 15, fade = 1, parameter = 0x08 } },
      { noiseNote = { len = 10, volume = 12, fade = 3, parameter = 0x51 } },
      { noiseNote = { len = 4, volume = 15, fade = 1, parameter = 0x00 } },
    } },
  } }
end

local function gen1Cry()
  return ChipAsm.sfx{ channels = {
    { hw = 1, program = {
      { duty = 2 },
      { squareNote = { len = 4, volume = 15, fade = 7, frequency = 0x700 } },
      { squareNote = { len = 8, volume = 14, fade = 2, frequency = 0x6E0 } },
      { squareNote = { len = 6, volume = 10, fade = 1, frequency = 0x740 } },
    } },
    { hw = 2, program = {
      { duty = 0 },
      { squareNote = { len = 4, volume = 12, fade = 7, frequency = 0x6A1 } },
      { squareNote = { len = 10, volume = 11, fade = 2, frequency = 0x680 } },
    } },
    { hw = 4, program = {
      { noiseNote = { len = 3, volume = 14, fade = 1, parameter = 0x2C } },
      { noiseNote = { len = 8, volume = 10, fade = 2, parameter = 0x44 } },
    } },
  } }
end

-- -------- Gen 2 programs (raw bytecode; ChipAsm only speaks Gen 1)
-- A channel is a list of bytes, { label = name } markers and "@name"
-- two-byte references, mounted as pseudo-bank 0 at 0x4000 like ChipAsm's.

local function gen2Blob(streams)
  local labels, size = {}, 0
  for _, stream in ipairs(streams) do
    for _, item in ipairs(stream) do
      if type(item) == "table" then
        labels[item.label] = 0x4000 + size
      else
        size = size + (type(item) == "string" and 2 or 1)
      end
    end
  end
  local bytes = {}
  for _, stream in ipairs(streams) do
    for _, item in ipairs(stream) do
      if type(item) == "string" then
        local address = assert(labels[item:sub(2)], item)
        bytes[#bytes + 1] = string.char(address % 0x100)
        bytes[#bytes + 1] = string.char(math.floor(address / 0x100))
      elseif type(item) == "number" then
        bytes[#bytes + 1] = string.char(item)
      end
    end
  end
  return table.concat(bytes), labels
end

local function gen2Header(numbers, streams, extra)
  local blob, labels = gen2Blob(streams)
  local channels = {}
  for index, number in ipairs(numbers) do
    channels[index] = { number = number, address = labels["ch" .. index] }
  end
  local header = { generation = 2, chip = {
    blob = blob, channels = channels, waves = extra and extra.waves,
  } }
  return header, labels
end

local GEN2_WAVES = {
  waveTable(function(i) return i < 16 and i or 31 - i end),
  waveTable(function(i) return i % 16 end),
  waveTable(function(i) return i % 4 < 2 and 13 or 2 end),
}

local function gen2Song()
  local header, labels = gen2Header({ 1, 2, 3, 4 }, {
    {
      { label = "ch1" },
      0xDA, 0x00, 0xA0,             -- tempo
      0xDB, 0x02,                   -- duty_cycle 2
      0xD8, 0x0C, 0xB3,             -- note_type 12, vol 11 fade 3
      0xD3,                         -- octave 5
      0xEF, 0x1E,                   -- stereo_panning: ch1 left only when STEREO
      { label = "loop1" },
      0xE1, 0x08, 0x24,             -- vibrato delay 8, depth 2 rate 4
      0x13, 0x55, 0x87,             -- C 4, E 6, G 8
      0xDE, 0x1B,                   -- duty_cycle_pattern 0,1,2,3
      0xD9, 0x02,                   -- transpose +2
      0x3B, 0x05,                   -- D 12, rest 6
      0xD9, 0x00,
      0xE6, 0x00, 0x03,             -- pitch_offset +3
      0xA7,                         -- A 8
      0xE6, 0x00, 0x00,
      0xDC, 0x6A,                   -- volume_envelope 6, fade -2
      0xC5,                         -- B 6
      0xE1, 0x00, 0x00,             -- vibrato off
      0xFE, "@sub1",                -- sound_call
      0xFD, 0x00, "@loop1",         -- sound_loop forever
      { label = "sub1" },
      0xD4, 0x5F, 0xD3, 0xFF,       -- octave 4, F 16, octave 5, ret
    },
    {
      { label = "ch2" },
      0xDB, 0x01,
      0xD8, 0x0C, 0x92,             -- note_type 12, vol 9 fade 2
      0xD4,                         -- octave 4
      0xEF, 0xE2,                   -- stereo_panning: ch2 right only when STEREO
      { label = "loop2" },
      0x87, 0xE0, 0x03, 0x41,       -- G 8, pitch_slide len 3 -> octave 4 C#
      0x9B,                         -- A 12
      0xDC, 0xF0,                   -- volume_envelope 15 flat
      0x56, 0x06,
      0xE9, 0x02,                   -- tempo_relative +2 (wraps over the loop)
      0xE9, 0xFE,                   -- and back
      0xFD, 0x00, "@loop2",
    },
    {
      { label = "ch3" },
      0xD8, 0x0C, 0x10,             -- note_type 12, wave level 1, instrument 0
      0xD5,                         -- octave 3
      { label = "loop3" },
      0x17, 0x87,
      0xDC, 0x22,                   -- wave level 2, instrument 2
      0xE1, 0x04, 0x31,
      0x3B,
      0xDC, 0x31,                   -- wave level 3, instrument 1
      0xE1, 0x00, 0x00,
      0xA5, 0x03,
      0xFD, 0x00, "@loop3",
    },
    {
      { label = "ch4" },
      0xD8, 0x0C,                   -- drum_speed 12
      0xE3, 0x00,                   -- toggle_noise kit 0
      { label = "loop4" },
      0x13, 0x23, 0x01, 0x33, 0x03, 0x43, 0x53, 0x13,
      0xFD, 0x00, "@loop4",
    },
    {
      { label = "kits" }, "@kit0",
      { label = "kit0" },
      "@drum1", "@drum1", "@drum2", "@drum3", "@drum4", "@drum5",
      { label = "drum1" }, 0x20, 0xC1, 0x10, 0x21, 0xA2, 0x23, 0xFF,
      { label = "drum2" }, 0x21, 0xF3, 0x5B, 0xFF,
      { label = "drum3" }, 0x20, 0xB1, 0x0A, 0xFF,
      { label = "drum4" }, 0x23, 0xE4, 0x6C, 0xFF,
      { label = "drum5" }, 0x20, 0x99, 0x02, 0x20, 0xB2, 0x46, 0xFF,
    },
  }, { waves = GEN2_WAVES })
  local data = { audio = {
    generation = 2,
    drumkits = { bank = 0, address = labels.kits },
  } }
  return data, header
end

local function gen2Cry()
  -- ParseSFXOrCry rows: length byte, envelope, frequency word / noise param
  local header = gen2Header({ 5, 6, 8 }, {
    {
      { label = "ch1" },
      0xDB, 0x02,
      0x04, 0xF7, 0x00, 0x07,
      0x08, 0xE2, 0xE0, 0x06,
      0x06, 0xA1, 0x40, 0x07,
      0xFF,
    },
    {
      { label = "ch2" },
      0xDB, 0x00,
      0x04, 0xC7, 0xA1, 0x06,
      0x0A, 0xB2, 0x80, 0x06,
      0xFF,
    },
    {
      { label = "ch3" },
      0x03, 0xE1, 0x2C,
      0x08, 0xA2, 0x44,
      0xFF,
    },
  })
  return { audio = { generation = 2 } }, header
end

-- -------- cases

-- streamed music: whole buffers through soundData plus one ragged
-- renderInto slice, the way ChipAudio's sync fallback fills its staging.
-- extra.rate renders at another synth rate; extra.between(n, engine) runs
-- after buffer n (live mixer / SOUND changes) and extra.chunk sizes buffers.
local function musicCase(name, build, channels, stereo, extra)
  extra = extra or {}
  return {
    name = name,
    kind = "music",
    run = function(seconds, sink)
      ChipSynth.setStereo(stereo)
      local rate = ChipSynth.SAMPLE_RATE
      if extra.rate then ChipSynth.setSampleRate(extra.rate) end
      local data, header = build()
      local engine = ChipSynth.newEngine(data, header, { allowLoops = true })
      local renderRate = ChipSynth.SAMPLE_RATE
      local total = math.floor(seconds * renderRate)
      local rendered, buffers = 0, 0
      while rendered < total do
        local count = math.min(extra.chunk or 8192, total - rendered)
        if rendered == 0 and count > 1000 then
          local sd = ChipSynth.newBuffer(count, channels)
          ChipSynth.renderInto(engine, sd, 0, 777, channels)
          ChipSynth.renderInto(engine, sd, 777, count - 777, channels)
          sink(sd)
        else
          sink(ChipSynth.soundData(engine, count, channels))
        end
        rendered = rendered + count
        buffers = buffers + 1
        if extra.between then extra.between(buffers, engine) end
      end
      ChipSynth.setSampleRate(rate)
      Fixtures.resetSynth()
      return rendered, renderRate
    end,
  }
end

-- live mixer changes between buffers: pitch and volume per channel, mute
local MIXES = {
  { { 1, 1, 1, 1 }, { 2, 0.5, 1, 1.5 } },
  { { 0.5, 1, 0, 2 }, { 1, 1, 0.75, 2 } },
  { { 1, 1, 1, 1 }, { 1, 1, 1, 1 } },
  { { 1.25, 0.8, 1, 0.3 }, { 0.5, 2, 2, 0.25 } },
}

local function remix(buffers)
  local mix = MIXES[buffers % #MIXES + 1]
  ChipSynth.setChannelVolumes(mix[1])
  ChipSynth.setChannelPitches(mix[2])
end

-- one-shot effects, repeated (each with its own options) to fill `seconds`
local function effectCase(name, build, optionSets)
  return {
    name = name,
    kind = "effect",
    run = function(seconds, sink)
      local total = math.floor(seconds * ChipSynth.SAMPLE_RATE)
      local rendered, round = 0, 0
      while rendered < total do
        for _, options in ipairs(optionSets) do
          local data, header = build()
          local copy = {}
          for key, value in pairs(options) do copy[key] = value end
          local sd = assert(ChipSynth.renderEffectData(data, header, copy))
          sink(sd)
          rendered = rendered + sd:getSampleCount()
        end
        round = round + 1
        assert(round < 1000, name .. " renders nothing")
      end
      return rendered
    end,
  }
end

local function gen1Data() return { audio = {} } end

Fixtures.cases = {
  musicCase("gen1-music-stereo", function() return gen1Data(), gen1Song() end, 2, false),
  musicCase("gen1-music-mono", function() return gen1Data(), gen1Song() end, 1, false),
  musicCase("gen2-music-sound-mono", gen2Song, 2, false),
  musicCase("gen2-music-sound-stereo", gen2Song, 2, true),
  musicCase("gen1-music-mixer", function() return gen1Data(), gen1Song() end, 2, false,
    { chunk = 3000, between = remix }),
  musicCase("gen2-music-sound-toggle", gen2Song, 2, false, {
    chunk = 4096,
    between = function(buffers, engine)
      ChipSynth.setStereo(buffers % 3 == 1)
      ChipSynth.applyStereo(engine)
      remix(buffers)
    end,
  }),
  musicCase("gen1-music-22050", function() return gen1Data(), gen1Song() end, 2, false,
    { rate = 22050 }),
  effectCase("gen1-sfx", function() return gen1Data(), gen1Sfx() end, {
    {}, { frequencyOffset = 0x20 }, { frequencyOffset = -0x10, frameTicks = 0xC0 },
  }),
  effectCase("gen1-cry", function() return gen1Data(), gen1Cry() end, {
    { frequencyOffset = 0x40, cryLength = 0x60 },
    { frequencyOffset = 0xF0, cryLength = 0x100 - 0x80 },
  }),
  effectCase("gen2-cry", gen2Cry, {
    { frequencyOffset = 0x30, cryLength = 0x120 },
    { frequencyOffset = 0xFFE0, cryLength = 0x200 },
  }),
}

-- -------- PCM capture + hash

-- a SoundData stand-in that keeps the exact doubles setSample receives
-- (no getFFIPointer, so every interpreter takes the same setSample path)
local Capture = {}
Capture.__index = Capture
function Capture:setSample(index, a, b)
  if b == nil then
    self.values[index * self.channels + 1] = a
  else
    self.values[index * self.channels + a] = b
  end
end
function Capture:getSampleCount() return self.samples end
function Capture:getChannelCount() return self.channels end
function Capture:getSampleRate() return self.rate end
function Capture:getBitDepth() return 16 end

function Fixtures.installCapture()
  love.sound = love.sound or {}
  love.sound.newSoundData = function(samples, rate, _, channels)
    return setmetatable({ samples = samples, rate = rate,
      channels = channels or 1, values = {} }, Capture)
  end
end

local frexp = math.frexp
local TWO32 = 4294967296

-- order-sensitive hash over the exact bits of every double: frexp splits a
-- double into a 53-bit integer mantissa and an exponent, both exact
function Fixtures.newHash()
  local hash = { value = 0, count = 0 }
  function hash:addSoundData(sd)
    local values = sd.values
    local h = self.value
    local n = sd.samples * sd.channels
    for index = 1, n do
      local m, e = frexp(values[index])
      m = m * 9007199254740992
      local lo = m % TWO32
      h = (h * 65599 + lo) % TWO32
      h = (h * 65599 + (m - lo) / TWO32 + e + 2048) % TWO32
    end
    self.value = h
    self.count = self.count + n
  end
  function hash:hex() return ("%08x"):format(self.value) end
  return hash
end

function Fixtures.resetSynth()
  ChipSynth.setStereo(false)
  ChipSynth.setChannelVolumes({ 1, 1, 1, 1 })
  ChipSynth.setChannelPitches({ 1, 1, 1, 1 })
end

return Fixtures
