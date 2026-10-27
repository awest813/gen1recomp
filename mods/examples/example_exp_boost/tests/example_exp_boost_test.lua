-- Standalone: luajit mods/examples/example_exp_boost/tests/example_exp_boost_test.lua
-- Drives exp.gain through the runtime bus under each generation's loader.
-- tests/drivers/xgen_gallery_mods.lua measures the same hook against the
-- real engines of Yellow, Gold and FireRed.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")

local function vanilla() return 308 end
local function gain(ctx) return Runtime.call("exp.gain", vanilla, ctx or {}) end

for _, gen in ipairs({ 1, 2, 3 }) do
  local tag = "gen " .. gen .. ": "
  local run = T.sdk.loadMod("mods/examples/example_exp_boost",
    { data = gen == 3 and T.sdk.gen3Data() or nil, generation = gen })
  T.eq(#run.errors, 0, tag .. "loads clean (" .. tostring(run.errors[1]) .. ")")
  T.eq(run.mod and run.mod.state, "loaded", tag .. "runs on this generation")
  T.eq(gain({ isTrainer = false }), 616, tag .. "the default rate doubles a wild award")
  T.eq(gain({ isTrainer = true }), 616, tag .. "and a trainer award")

  local opts = run.loader.modOptions
  opts.example_exp_boost = { rate = "1.5" }
  T.eq(gain({}), 462, tag .. "1.5X rounds down like the engines do")
  opts.example_exp_boost = { rate = "3", trainers = true }
  T.eq(gain({ isTrainer = false }), 308, tag .. "TRAINERS ONLY leaves a wild award alone")
  T.eq(gain({ isTrainer = true }), 924, tag .. "and triples a trainer one")
  T.eq(Runtime.call("exp.gain", function() return 30000 end, { isTrainer = true }), 0xFFFF,
    tag .. "the award stays inside its 16-bit word")
  T.eq(Runtime.call("exp.gain", function() return 0 end, {}), 0,
    tag .. "a zero award stays zero")
  run.release()
end

T.finish("example_exp_boost")
