-- Progress across extractor stages that take very different times.
--
-- The Gen 1 and Gen 2 extractors reported every stage as an equal slice of
-- the bar, so it raced through a dozen instant stages and then sat still
-- through Pokemon (a third of the import).  A weight table gives each stage
-- its measured share instead; stages it does not name count `default`.
--
--   local progress = StageWeights.new(WEIGHTS)
--   progress:begin("Maps")          -> done, total   (start of that stage)
--   progress:at(0.5)                -> done, total   (halfway through it)

local StageWeights = {}
StageWeights.__index = StageWeights

function StageWeights.new(weights, default)
  local total = 0
  for _, w in pairs(weights) do total = total + w end
  return setmetatable({ weights = weights, default = default or 1,
    total = total, done = 0, current = nil }, StageWeights)
end

function StageWeights:weight(name)
  return self.weights[name] or self.default
end

function StageWeights:begin(name)
  if self.current then self.done = self.done + self:weight(self.current) end
  self.current = name
  -- a stage the table does not know grows the total, so the bar still ends at 1
  if not self.weights[name] then self.total = self.total + self.default end
  return math.min(self.done, self.total), self.total
end

function StageWeights:at(fraction)
  local w = self.current and self:weight(self.current) or 0
  fraction = math.max(0, math.min(1, fraction or 0))
  return math.min(self.done + w * fraction, self.total), self.total
end

return StageWeights
