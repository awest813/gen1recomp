-- Nonblocking render deadlines for a requestAnimationFrame-driven host.
-- Updates and input continue on every callback; only drawing is capped.
local WebFramePacer = {}
WebFramePacer.__index = WebFramePacer

function WebFramePacer.new()
  return setmetatable({}, WebFramePacer)
end

function WebFramePacer:due(now, cap)
  -- Measure callbacks, including skipped draws. Fractional refresh rates need
  -- a refresh-aligned cadence when the requested cap nearly divides the host.
  if not self.hostStart or now < (self.last or now)
      or now - (self.last or now) > 0.1 then
    self.hostStart, self.hostSamples, self.hostPeriod = now, 0, nil
  else
    self.hostSamples = self.hostSamples + 1
    if self.hostSamples >= 64 then
      self.hostPeriod = (now - self.hostStart) / self.hostSamples
      self.hostStart, self.hostSamples = now, 0
    end
  end
  if self.cap ~= cap or now < (self.last or now) then
    self.measureStart, self.frames, self.lastPresent = nil, 0, nil
    self.maxInterval, self.lateFrames = 0, 0
  end
  if cap <= 0 then
    self.deadline, self.cap, self.last = nil, cap, now
    return true
  end
  local period = 1 / cap
  if not self.deadline or self.cap ~= cap or now < (self.last or now) then
    self.cap, self.last, self.deadline = cap, now, now + period
    return true
  end
  self.last = now
  -- Small browser timestamp jitter must not halve a matching-refresh cap.
  local tolerance = math.min(0.002, period * 0.1)
  if now + tolerance < self.deadline then return false end
  local refreshAligned = false
  if self.hostPeriod and self.hostPeriod > 0 then
    local ratio = period / self.hostPeriod
    local stride = math.floor(ratio + 0.5)
    refreshAligned = stride >= 1 and math.abs(ratio - stride) <= stride * 0.005
  end
  if refreshAligned or now - self.deadline >= period then
    -- Follow matching displays without periodic phase corrections. A stalled
    -- frame also renders once; never burst to repay missed presents.
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
