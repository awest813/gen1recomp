-- FixedStep.sustainedCatchup (the browser build): a steady low frame rate
-- keeps the game at real-time speed, while a one-off hitch still gets the
-- two-step cap that stops a catch-up burst playing out as a slide.
--   luajit tests/engine/fixed_step_sustained_catchup_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local eq, check = T.eq, T.check
local FixedStep = require("src.core.FixedStep")
local STEP = FixedStep.STEP

-- logic steps the loop runs over `seconds` of frames `dt` long
local function stepsOver(dt, seconds)
  local steps = 0
  FixedStep:init(function() steps = steps + 1 end)
  for _ = 1, math.floor(seconds / dt + 0.5) do
    FixedStep.maxAccum = FixedStep.catchupLimit(1, dt)
    FixedStep:update(dt, 1)
  end
  return steps
end

-- off (desktop): 20 fps is capped at two steps a frame -- slow motion
FixedStep.sustainedCatchup = false
FixedStep._resetSustainedForTests()
eq(stepsOver(1 / 20, 10), 400, "off: 20 fps runs 40 steps a second (unchanged desktop pacing)")

-- on: the same 20 fps keeps real time once the average settles
FixedStep.sustainedCatchup = true
FixedStep._resetSustainedForTests()
local steps = stepsOver(1 / 20, 10)
check(steps >= 580 and steps <= 600, "on: 20 fps keeps ~60 steps a second (" .. steps .. " in 10 s)")

-- on: 60 fps is untouched
FixedStep._resetSustainedForTests()
eq(stepsOver(1 / 60, 10), 600, "on: 60 fps is one step a frame")

-- on: a single hitch at 60 fps keeps the two-step cap
FixedStep._resetSustainedForTests()
for _ = 1, 120 do FixedStep.catchupLimit(1, 1 / 60) end
eq(FixedStep.catchupLimit(1, 0.25), STEP * 2, "on: a lone 250 ms hitch is still capped at two steps")

-- on: below 15 fps the catch-up is bounded (no spiral)
FixedStep._resetSustainedForTests()
for _ = 1, 100 do FixedStep.catchupLimit(1, 0.2) end
check(FixedStep.catchupLimit(1, 0.2) <= STEP * 4 * 1.5 + 1e-9, "on: at most four steps' worth a frame")

FixedStep.sustainedCatchup = false
FixedStep._resetSustainedForTests()
T.finish()
