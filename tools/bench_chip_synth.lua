-- ChipSynth throughput benchmark: renders the ROM-free workloads in
-- tests/engine/_chip_synth_fixtures.lua and reports milliseconds of CPU per
-- second of audio, plus a hash of the exact PCM doubles so an optimization
-- can be checked for bit-identical output.
--
--   luajit tools/bench_chip_synth.lua [seconds] [repeats] [case ...]
--   lua5.1 tools/bench_chip_synth.lua ...
--
-- The browser build runs the synth on PUC Lua 5.1 (no JIT) on the main
-- thread, so the lua5.1 column is the one that costs frame time there.
-- PUC Lua has no `bit` built in; LOVE bundles LuaBitOp, so point
-- BENCH_BIT_CPATH at a directory holding a LuaBitOp-compatible bit.so.
-- Without one a pure-Lua fallback is used, which inflates the lua5.1
-- numbers (it says so) but still hashes identically.
package.path = "./?.lua;./?/init.lua;" .. package.path

local function pureBit()
  -- LuaBitOp semantics (signed 32-bit results) for the operand ranges the
  -- synth uses; slow, only so the benchmark runs without a native module
  local TWO32, TWO31 = 4294967296, 2147483648
  local function u(x) return math.floor(x + 0.5) % TWO32 end
  local function s(x) x = x % TWO32; if x >= TWO31 then return x - TWO32 end return x end
  local function op(a, b, keep)
    local r, place = 0, 1
    for _ = 1, 32 do
      local x, y = a % 2, b % 2
      if keep(x, y) then r = r + place end
      a, b, place = (a - x) / 2, (b - y) / 2, place * 2
    end
    return r
  end
  local function fold(keep)
    return function(a, ...)
      local r = u(a)
      for i = 1, select("#", ...) do r = op(r, u(select(i, ...)), keep) end
      return s(r)
    end
  end
  local M = {}
  M.band = fold(function(x, y) return x == 1 and y == 1 end)
  M.bor = fold(function(x, y) return x == 1 or y == 1 end)
  M.bxor = fold(function(x, y) return x ~= y end)
  function M.bnot(a) return s(TWO32 - 1 - u(a)) end
  function M.tobit(a) return s(u(a)) end
  function M.lshift(a, n) return s(u(a) * 2 ^ (n % 32)) end
  function M.rshift(a, n) return s(math.floor(u(a) / 2 ^ (n % 32))) end
  function M.arshift(a, n) return s(math.floor(s(u(a)) / 2 ^ (n % 32))) end
  return M
end

local bitNote = "native"
if not pcall(require, "bit") then
  local dir = os.getenv("BENCH_BIT_CPATH")
  if dir then package.cpath = dir .. "/?.so;" .. package.cpath end
  if not (dir and pcall(require, "bit")) then
    package.loaded.bit = pureBit()
    bitNote = "pure-Lua fallback (lua5.1 numbers inflated)"
  else
    bitNote = "native (" .. dir .. ")"
  end
end

love = require("tests.love_stub")
-- BENCH_CHIPSYNTH=<file> benches another copy of ChipSynth.lua (say, one
-- `git show`n from an older revision) on the same workloads
if os.getenv("BENCH_CHIPSYNTH") then
  package.loaded["src.core.ChipSynth"] = dofile(os.getenv("BENCH_CHIPSYNTH"))
end
local Fixtures = require("tests.engine._chip_synth_fixtures")
local ChipSynth = require("src.core.ChipSynth")
Fixtures.installCapture()

local seconds = tonumber(arg[1]) or 10
local repeats = tonumber(arg[2]) or 3
local only = {}
for i = 3, #arg do only[arg[i]] = true end

local interpreter = (type(jit) == "table" and jit.version) or _VERSION
print(("ChipSynth bench: %s, %d Hz, %gs of audio per case, best of %d; bit: %s")
  :format(interpreter, ChipSynth.SAMPLE_RATE, seconds, repeats, bitNote))
print(("%-26s %10s %10s  %s"):format("case", "ms/audio-s", "samples", "pcm hash"))

local totalMs, totalSeconds = 0, 0
for _, case in ipairs(Fixtures.cases) do
  if next(only) == nil or only[case.name] then
    local best, hashHex, samples, rate
    for _ = 1, repeats do
      Fixtures.resetSynth()
      local hash = Fixtures.newHash()
      local buffers = {}
      collectgarbage("collect")
      local start = os.clock()
      samples, rate = case.run(seconds, function(sd) buffers[#buffers + 1] = sd end)
      local elapsed = os.clock() - start
      for _, sd in ipairs(buffers) do hash:addSoundData(sd) end
      if hashHex and hashHex ~= hash:hex() then
        error(case.name .. ": PCM differs between repeats")
      end
      hashHex = hash:hex()
      if not best or elapsed < best then best = elapsed end
    end
    -- a case may render at its own synth rate (it says which)
    local audioSeconds = samples / (rate or ChipSynth.SAMPLE_RATE)
    local msPerSecond = best * 1000 / audioSeconds
    totalMs = totalMs + best * 1000
    totalSeconds = totalSeconds + audioSeconds
    print(("%-26s %10.2f %10d  %s"):format(case.name, msPerSecond, samples, hashHex))
  end
end
print(("%-26s %10.2f"):format("all cases", totalMs / totalSeconds))
