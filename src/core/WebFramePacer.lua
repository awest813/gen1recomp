-- Nonblocking render deadlines for a requestAnimationFrame-driven host.
-- Updates and input continue on every callback; only drawing is capped.
local WebFramePacer = {}
WebFramePacer.__index = WebFramePacer

function WebFramePacer.new()
  return setmetatable({}, WebFramePacer)
end

function WebFramePacer:due(now, cap)
  -- Measure callbacks, including skipped draws. A stall restarts the window
  -- so one long gap is not averaged in as the refresh rate, but the last
  -- good rate is kept. Only a backwards clock forgets the display.
  local previous = self.last
  local clockReset = previous ~= nil and now < previous
  local stalled = previous ~= nil and (now - previous) > 0.1
  if self.hostStart == nil or clockReset or stalled then
    self.hostStart, self.hostSamples = now, 0
    if clockReset then
      self.hostPeriod, self.stride, self.phase = nil, nil, 0
    end
  else
    self.hostSamples = self.hostSamples + 1
    if self.hostSamples >= 64 then
      self.hostPeriod = (now - self.hostStart) / self.hostSamples
      self.hostStart, self.hostSamples = now, 0
    end
  end
  if self.cap ~= cap or clockReset then
    self.measureStart, self.frames, self.lastPresent = nil, 0, nil
    self.maxInterval, self.lateFrames = 0, 0
  end
  if cap <= 0 then
    self.deadline, self.cap, self.last = nil, cap, now
    self.stride, self.phase = nil, 0
    return true
  end
  local period = 1 / cap
  if self.deadline == nil or self.cap ~= cap or clockReset then
    self.cap, self.last, self.deadline = cap, now, now + period
    self.stride, self.phase = nil, 0
    return true
  end
  self.last = now
  -- Integer callback multiples (30 on 59.94Hz, 60 on 119.88Hz, ...) follow
  -- the host directly. A timestamp deadline plus a 2ms tolerance skips the
  -- refresh after a late callback, because the next one looks early.
  local stride = nil
  if self.hostPeriod and self.hostPeriod > 0 then
    local ratio = period / self.hostPeriod
    local rounded = math.floor(ratio + 0.5)
    local limit = self.stride == rounded and 0.2 or rounded * 0.02
    if rounded >= 1 and math.abs(ratio - rounded) <= limit then
      stride = rounded
    end
  end
  if stride then
    if self.stride ~= stride then
      -- Keep this frame's wall-clock decision so the handoff does not insert
      -- an extra skipped refresh. Later frames count host callbacks.
      self.stride = stride
      local tolerance = math.min(0.002, period * 0.1)
      local due = stalled or stride == 1 or now + tolerance >= self.deadline
      if not due then
        self.phase = 1
        return false
      end
      self.phase = 0
      if stalled or now - self.deadline >= period then
        self.deadline = now + period
      else
        self.deadline = self.deadline + period
      end
      return true
    end
    self.phase = (self.phase or 0) + 1
    if not stalled and self.phase < stride then return false end
    self.phase = 0
    self.deadline = now + period
    return true
  end
  self.stride, self.phase = nil, 0
  -- Rates that do not divide the display stay on a wall-clock budget.
  local tolerance = math.min(0.002, period * 0.1)
  if not stalled and now + tolerance < self.deadline then return false end
  if stalled or now - self.deadline >= period then
    -- A stalled frame renders once; never burst to repay missed presents.
    self.deadline = now + period
  else
    self.deadline = self.deadline + period
  end
  return true
end

-- Diagnostic rate counts completed draws, rather than browser callbacks.
function WebFramePacer:presented(now)
  if not self.measureStart then
    self.measureStart, self.lastPresent, self.frames = now, now, 0
    self.maxInterval, self.lateFrames = 0, 0
    return nil
  end
  local interval = math.max(0, now - self.lastPresent)
  self.lastPresent = now
  self.maxInterval = math.max(self.maxInterval, interval)
  -- Average FPS can hide alternating short frames and long pauses. Count
  -- intervals substantially beyond the selected budget, allowing RAF jitter.
  if self.cap and self.cap > 0 and interval > 1.25 / self.cap then
    self.lateFrames = self.lateFrames + 1
  end
  self.frames = self.frames + 1
  local elapsed = now - self.measureStart
  if elapsed < 1 then return nil end
  local fps = self.frames / elapsed
  local timing = { meanMs = elapsed * 1000 / self.frames,
    maxMs = self.maxInterval * 1000, late = self.lateFrames, frames = self.frames }
  self.measureStart, self.frames = now, 0
  self.maxInterval, self.lateFrames = 0, 0
  return fps, timing
end

return WebFramePacer
