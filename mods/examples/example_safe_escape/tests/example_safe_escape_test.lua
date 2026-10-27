-- Standalone: luajit mods/examples/example_safe_escape/tests/example_safe_escape_test.lua
-- Drives battle.run through the runtime bus with a vanilla roll that fails.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")

local function fails() return false end
local function run(ctx) return Runtime.call("battle.run", fails, ctx) end

for _, gen in ipairs({ 1, 2, 3 }) do
  local tag = "gen " .. gen .. ": "
  local loaded = T.sdk.loadMod("mods/examples/example_safe_escape",
    { data = gen == 3 and T.sdk.gen3Data() or nil, generation = gen })
  T.eq(#loaded.errors, 0, tag .. "loads clean (" .. tostring(loaded.errors[1]) .. ")")
  T.eq(run({ battle = {}, pSpd = 10, eSpd = 200, attempts = 1 }), true,
    tag .. "a slow lead always gets away")
  T.eq(run({ battle = { double = true } }), false, tag .. "a double battle keeps its vanilla answer")
  T.eq(run({ battle = { pyramid = true } }), false, tag .. "the Battle Pyramid keeps its vanilla answer")
  T.eq(run({ battle = {}, battler = { side = "enemy" } }), false,
    tag .. "a wild mon trying to leave keeps its own odds")
  T.eq(run({ battle = {}, battler = { side = "player" } }), true,
    tag .. "the player's battler always gets away")
  loaded.release()
end

T.finish("example_safe_escape")
