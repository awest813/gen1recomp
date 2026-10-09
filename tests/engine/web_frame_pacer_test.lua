package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local Pacer = require("src.core.WebFramePacer")
love = require("tests.love_stub")
love.system.getOS = function() return "Web" end
local Cap = require("src.core.FrameCap")
T.eq(Cap.DEFAULT, 30, "fresh web sessions default to the 30 FPS target")
T.eq(Cap.normalize(nil), 30, "missing web save option uses 30 FPS")
T.eq(Cap.normalize(60), 60, "explicit 60 FPS is preserved")
T.eq(Cap.normalize(0), 0, "web stores unlocked")
T.eq(Cap.label(0), "UNLOCKED", "web names unlocked accurately")
T.eq(Cap.cycle(30), 60, "30 cycles to 60")
T.eq(Cap.cycle(60), 0, "60 cycles to unlocked")
T.eq(Cap.cycle(0), 30, "unlocked cycles to 30")
T.eq(Cap.cycle(30, -1), 0, "reverse cycle reaches unlocked")
Cap.apply(0)
T.eq(Cap.clampToPerformance(60), 0, "quality tier cannot override explicit unlocked")
local function count(hz, cap, jitter)
  local p, frames = Pacer.new(), 0
  for i = 0, hz * 10 - 1 do
    local now = i / hz + (jitter and ((i % 3) - 1) * 0.0005 or 0)
    if p:due(now, cap) then frames = frames + 1 end
  end
  return frames
end
for _, hz in ipairs({ 60, 120, 144, 240 }) do
  for _, cap in ipairs({ 30, 60 }) do
    for _, jitter in ipairs({ false, true }) do
      local actual = count(hz, cap, jitter)
      T.check(math.abs(actual - cap * 10) <= 1,
        ("%dHz / %d FPS preserves cadence (%d)"):format(hz, cap, actual))
    end
  end
  T.eq(count(hz, 0), hz * 10, "unlocked uses every host callback")
end
local p = Pacer.new()
T.check(p:due(0, 60), "first present immediate")
T.check(p:due(5, 60), "stall presents once")
T.eq(p:due(5.001, 60), false, "stall does not trigger a catch-up burst")
T.check(p:due(5.002, 30), "changing cap starts a new cadence immediately")
T.check(p:due(1, 30), "clock reset reanchors")
local measured = Pacer.new()
T.eq(measured:presented(0), nil, "measurement waits for a complete window")
local fps
for i = 1, 30 do fps = measured:presented(i / 30) end
T.eq(fps, 30, "diagnostics count completed 30 FPS draws")
local hitch = Pacer.new()
hitch:due(0, 30)
hitch:presented(0)
local rate, timing
for i = 1, 29 do rate, timing = hitch:presented(i / 30) end
rate, timing = hitch:presented(1.1)
T.eq(timing.frames, 30, "frame-time window counts every completed present")
T.eq(timing.late, 1, "one long interval is visible despite the FPS average")
T.check(timing.maxMs > 130, "frame-time window reports the actual hitch")
T.check(timing.meanMs > 36, "frame-time mean includes the hitch")
hitch:due(1.1, 60)
T.eq(hitch:presented(1.1), nil, "cap change starts a fresh timing window")
for i = 1, 60 do rate, timing = hitch:presented(1.1 + i / 60) end
T.eq(timing.late, 0, "old hitch does not contaminate the new cap")
hitch:due(.1, 60)
T.eq(hitch:presented(.1), nil, "clock reset discards the old measurement epoch")
timing = nil
for i = 1, 61 do
  local _, window = hitch:presented(.1 + i / 60)
  if window then timing = window end
end
T.check(timing and timing.late == 0, "measurement recovers after a clock reset")
T.finish("web_frame_pacer_test")
