-- A stored mod option checked against its schema row before a mod sees it.
--
-- options.modOptions outlives any one version of a mod: an update can turn a
-- toggle into a choice, drop a choice value, or narrow a number's range, and
-- a hand-edited or synced options.lua can hold anything.  A mod that defined
-- a toggle expects a boolean back from mod.options:get, so a stored value
-- that no longer fits its row reads as the row's default instead (the stored
-- value itself is left alone; the next change the player makes replaces it).
-- Row shapes are docs/mod-option-schema.md's: toggle, choice ([label, value]
-- pairs), number (min/max/step), text (maxLen).

local OptionValue = {}

local function choiceValue(choice)
  if type(choice) == "table" then return choice[2] end
  return choice
end

-- The value a mod should see for `row` given what is stored (nil = unset).
function OptionValue.coerce(row, stored)
  if type(row) ~= "table" then return stored end
  local default = row.default
  if stored == nil then return default end
  local kind = row.type
  if kind == "toggle" then
    if type(stored) == "boolean" then return stored end
    return default
  elseif kind == "number" then
    local n = tonumber(stored)
    -- NaN and the infinities are never a setting
    if not n or n ~= n or n == math.huge or n == -math.huge then return default end
    if tonumber(row.min) and n < row.min then n = row.min end
    if tonumber(row.max) and n > row.max then n = row.max end
    return n
  elseif kind == "choice" then
    if type(row.choices) ~= "table" or #row.choices == 0 then return stored end
    for _, choice in ipairs(row.choices) do
      if choiceValue(choice) == stored then return stored end
    end
    return default
  elseif kind == "text" then
    if type(stored) ~= "string" then
      if type(stored) == "number" then stored = tostring(stored) else return default end
    end
    local maxLen = tonumber(row.maxLen)
    if maxLen and maxLen >= 0 and #stored > maxLen then
      stored = stored:sub(1, maxLen)
    end
    return stored
  end
  return stored
end

return OptionValue
