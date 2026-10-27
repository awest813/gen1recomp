-- Standalone: luajit mods/examples/example_lucky_ball/tests/example_lucky_ball_test.lua
-- Drives catch.rate through the runtime bus with a scripted vanilla throw.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")

-- a vanilla throw that answers from a script: false, false, true, ...
local function scripted(results)
  local calls = 0
  return function()
    calls = calls + 1
    local caught = results[calls]
    return caught, caught and 4 or calls
  end, function() return calls end
end

for _, gen in ipairs({ 1, 2, 3 }) do
  local tag = "gen " .. gen .. ": "
  local run = T.sdk.loadMod("mods/examples/example_lucky_ball",
    { data = gen == 3 and T.sdk.gen3Data() or nil, generation = gen })
  T.eq(#run.errors, 0, tag .. "loads clean (" .. tostring(run.errors[1]) .. ")")

  local throw, calls = scripted({ true })
  local caught, detail = Runtime.call("catch.rate", throw, "POKE_BALL", {}, {}, {})
  T.eq(caught, true, tag .. "a catch on the first roll stands")
  T.eq(detail, 4, tag .. "with its own detail")
  T.eq(calls(), 1, tag .. "and no second roll is spent")

  throw, calls = scripted({ false, true })
  caught = Runtime.call("catch.rate", throw, "POKE_BALL", {}, {}, {})
  T.eq(caught, true, tag .. "a miss gets one more roll")
  T.eq(calls(), 2, tag .. "exactly one more")

  throw, calls = scripted({ false, false, true })
  caught, detail = Runtime.call("catch.rate", throw, "POKE_BALL", {}, {}, {})
  T.eq(caught, false, tag .. "two misses is a miss at the default setting")
  T.eq(detail, 2, tag .. "reporting the last roll's shakes")
  T.eq(calls(), 2, tag .. "and no third roll")

  run.loader.modOptions.example_lucky_ball = { tries = "3" }
  throw, calls = scripted({ false, false, true })
  caught = Runtime.call("catch.rate", throw, "POKE_BALL", {}, {}, {})
  T.eq(caught, true, tag .. "ROLLS PER BALL 3 allows a third")
  T.eq(calls(), 3, tag .. "and stops there")
  run.release()
end

T.finish("example_lucky_ball")
