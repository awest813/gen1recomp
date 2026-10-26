-- Every top-level suite under tests/ is run by some tier.
-- No pokered cite: this guards the test plumbing itself.
--
-- The directory tiers (tests/engine, tests/save_compat, tests/gen5,
-- tests/modkit/cases) pick up new files on their own; a file dropped straight
-- into tests/ is only run if scripts/test.sh, a runner's glob, or a list names
-- it.  Twenty such suites ran nowhere, and one of them
-- (chip_synth_bulk_pcm_test) broke for a whole round before anyone noticed.
-- A new top-level file must either be wired into a tier or be a helper some
-- other test requires; the few standalone drivers are listed below.
--   luajit tests/engine/test_wiring_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check = T.check

local function read(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*a")
  f:close()
  return s
end

local function list(cmd)
  local out, p = {}, io.popen(cmd)
  if not p then return out end
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

-- Not suites: drivers launched with arguments or by hand.
local DRIVERS = {
  ["tests/autopilot.lua"] = "POKEPORT_AUTOPILOT frame driver",
  ["tests/g3link_rs_mix_side.lua"] = "one side of a two-process link run",
}

-- Glob patterns the runners expand themselves.
local GLOBS = {
  "^tests/gen2_.*%.lua$", "^tests/crystal_.*%.lua$", -- run_gen2 / run_tests
  "^tests/game3_.*%.lua$", "^tests/emerald_.*%.lua$", -- scripts/test.sh T6
  "^tests/mod_.*%.lua$", "^tests/parity_.*%.lua$", -- run_tests
  "^tests/run_.*%.lua$", -- the runners
}

local wiring = read("scripts/test.sh") .. "\n" .. read("tests/quick.list")
for _, runner in ipairs(list("ls tests/run_*.lua tests/tier_runner.lua 2>/dev/null")) do
  wiring = wiring .. "\n" .. read(runner)
end

local everything = {}
for _, path in ipairs(list("ls tests/*.lua tests/*/*.lua tests/*/*/*.lua 2>/dev/null")) do
  everything[#everything + 1] = { path = path, text = read(path) }
end

local suites = list("ls tests/*.lua 2>/dev/null")
check(#suites > 100, "found the top-level suites (" .. #suites .. ")")

local orphans = {}
for _, path in ipairs(suites) do
  local base = path:match("([^/]+)$")
  local wired = DRIVERS[path] ~= nil
    or wiring:find(path, 1, true) ~= nil
    or wiring:find(base, 1, true) ~= nil
  for _, pattern in ipairs(GLOBS) do
    if wired then break end
    wired = path:match(pattern) ~= nil
  end
  if not wired then
    -- a helper another test requires (tests.harness, tests.love_stub, ...)
    local module = "tests." .. base:gsub("%.lua$", "")
    for _, other in ipairs(everything) do
      if other.path ~= path and other.text:find(module, 1, true) then
        wired = true
        break
      end
    end
  end
  if not wired then orphans[#orphans + 1] = path end
end

check(#orphans == 0, "every top-level suite is run by a tier; unwired: "
  .. table.concat(orphans, ", ")
  .. " (add it to STANDALONE_SUITES in scripts/test.sh)")

T.finish("test wiring")
