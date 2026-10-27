-- Standalone: luajit mods/examples/example_quiet_alarm/tests/example_quiet_alarm_test.lua
-- Drives battle.low_health_alarm through the runtime bus.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")

for _, gen in ipairs({ 1, 2, 3 }) do
  local tag = "gen " .. gen .. ": "
  local run = T.sdk.loadMod("mods/examples/example_quiet_alarm",
    { data = gen == 3 and T.sdk.gen3Data() or nil, generation = gen })
  T.eq(#run.errors, 0, tag .. "loads clean (" .. tostring(run.errors[1]) .. ")")
  local seen
  local function vanilla(ctx) seen = ctx.on end
  Runtime.call("battle.low_health_alarm", vanilla, { on = true, battle = {} })
  T.eq(seen, false, tag .. "a red bar no longer starts the alarm")
  Runtime.call("battle.low_health_alarm", vanilla, { on = false, battle = {} })
  T.eq(seen, false, tag .. "and a healthy bar still stops it")
  run.release()
end

T.finish("example_quiet_alarm")
