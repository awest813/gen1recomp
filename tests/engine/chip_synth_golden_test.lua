-- ChipSynth PCM is pinned bit-for-bit: every fixture workload in
-- _chip_synth_fixtures.lua (Gen 1/2 music in mono, stereo and live SOUND /
-- mixer changes, a lower synth rate, SFX and cries) must hash to the value
-- the straightforward per-sample synth produced before it was optimized for
-- PUC Lua.  The hash covers the exact doubles handed to setSample, so any
-- reordering of float math, a missed cache invalidation or an off-by-one
-- step edge shows up here even when it would round to the same int16.
--
-- A deliberate change to what the synth outputs re-pins these with:
--   luajit tools/bench_chip_synth.lua 1.5 1
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq

love = require("tests.love_stub")

local Fixtures = require("tests.engine._chip_synth_fixtures")
local ChipSynth = require("src.core.ChipSynth")

local SECONDS = 1.5
local GOLDEN = {
  ["gen1-music-stereo"] = "7b9ec57a",
  ["gen1-music-mono"] = "5bfce47d",
  ["gen2-music-sound-mono"] = "0eaecbe0",
  ["gen2-music-sound-stereo"] = "aa73c384",
  ["gen1-music-mixer"] = "4633db2a",
  ["gen2-music-sound-toggle"] = "94eaf346",
  ["gen1-music-22050"] = "f50cde7c",
  ["gen1-sfx"] = "d43647c8",
  ["gen1-cry"] = "420fe47c",
  ["gen2-cry"] = "c60963cc",
}

Fixtures.installCapture()

local seen = 0
for _, case in ipairs(Fixtures.cases) do
  seen = seen + 1
  Fixtures.resetSynth()
  local hash = Fixtures.newHash()
  local sounding = 0
  case.run(SECONDS, function(sd)
    hash:addSoundData(sd)
    for _, value in ipairs(sd.values) do
      if value > 1e-3 or value < -1e-3 then sounding = sounding + 1 end
    end
  end)
  check(GOLDEN[case.name] ~= nil, case.name .. " has a pinned hash")
  eq(hash:hex(), GOLDEN[case.name], case.name .. " PCM is bit-identical")
  check(sounding > hash.count / 4,
    case.name .. " is mostly sounding, not a hash of silence")
end
eq(seen, 10, "every fixture workload ran")
eq(ChipSynth.SAMPLE_RATE, 44100, "the 22050 case restores the synth rate")

T.finish("chip synth golden pcm")
