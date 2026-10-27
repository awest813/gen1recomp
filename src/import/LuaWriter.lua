local LuaWriter = {}

local KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

local function quote(value)
  -- most strings need no escapes: skip gsub's per-match callback machinery
  if not value:find('[%z\1-\31\\"]') then return '"' .. value .. '"' end
  local escaped = value:gsub('[%z\1-\31\\"]', function(character)
    if character == "\\" then return "\\\\" end
    if character == '"' then return '\\"' end
    if character == "\n" then return "\\n" end
    if character == "\r" then return "\\r" end
    if character == "\t" then return "\\t" end
    return ("\\%03d"):format(character:byte())
  end)
  return '"' .. escaped .. '"'
end

-- Keys repeat across thousands of rows ("x", "map", "name"); their text is
-- worked out once.
local KEY_TEXT = {}

local function keyText(key)
  local text = KEY_TEXT[key]
  if text then return text end
  if type(key) == "string"
      and key:match("^[A-Za-z_][A-Za-z0-9_]*$")
      and not KEYWORDS[key] then
    text = key
  else
    text = "[" .. (type(key) == "string" and quote(key) or tostring(key)) .. "]"
  end
  if type(key) == "string" and #key <= 64 then KEY_TEXT[key] = text end
  return text
end

local function isArray(value)
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false, 0
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count == maximum, maximum
end

local function mixedOrder(a, b)
  if type(a) == type(b) then return a < b end
  return type(a) == "number"
end

-- Numbers first, then strings, each ascending.  Keys are distinct, so the
-- order is the same whichever way the sort gets there; the common all-string
-- and all-number tables skip the comparator closure.
local function sortedKeys(value)
  local keys = {}
  local strings, numbers = false, false
  for key in pairs(value) do
    keys[#keys + 1] = key
    local kind = type(key)
    if kind == "string" then strings = true
    elseif kind == "number" then numbers = true
    else strings, numbers = true, true end
  end
  if strings ~= numbers then
    table.sort(keys)
  else
    table.sort(keys, mixedOrder)
  end
  return keys
end

-- "  " * n, built once per depth.
local PADS = setmetatable({}, { __index = function(pads, n)
  local pad = string.rep("  ", n)
  pads[n] = pad
  return pad
end })

-- Appends the encoding of `value` to `out`.  One shared buffer instead of a
-- string per nested table: the old version returned each child as a string
-- and copied it into its parent, so a deep table was copied once per level
-- (LuaWriter.encode was 12-20% of a Gen 1/2 import).  The text is unchanged.
local function emit(out, value, indent, seen)
  local kind = type(value)
  if value == nil then out[#out + 1] = "nil" return end
  if kind == "boolean" or kind == "number" then out[#out + 1] = tostring(value) return end
  if kind == "string" then out[#out + 1] = quote(value) return end
  if kind ~= "table" then
    error("cannot serialize " .. kind)
  end
  if seen[value] then error("cannot serialize a cyclic table") end
  if next(value) == nil then out[#out + 1] = "{}" return end
  seen[value] = true

  local childPad = PADS[indent + 1]
  out[#out + 1] = "{\n"
  local array, length = isArray(value)
  if array then
    for index = 1, length do
      out[#out + 1] = childPad
      emit(out, value[index], indent + 1, seen)
      out[#out + 1] = index < length and ",\n" or ","
    end
  else
    local keys = sortedKeys(value)
    for i, key in ipairs(keys) do
      out[#out + 1] = childPad
      out[#out + 1] = keyText(key)
      out[#out + 1] = " = "
      emit(out, value[key], indent + 1, seen)
      out[#out + 1] = i < #keys and ",\n" or ","
    end
  end
  seen[value] = nil
  out[#out + 1] = "\n"
  out[#out + 1] = PADS[indent]
  out[#out + 1] = "}"
end

function LuaWriter.encode(value)
  local out = { "return " }
  emit(out, value, 0, {})
  out[#out + 1] = "\n"
  return table.concat(out)
end

function LuaWriter.write(path, value)
  -- CacheFs routes this to the OS save directory (normal builds) or straight
  -- into the game folder (portable installs); it also creates the parent
  -- directories.  See src/import/CacheFs.lua.
  local CacheFs = require("src.import.CacheFs")
  local ok, err = CacheFs.write(path, LuaWriter.encode(value))
  if not ok then error("could not write " .. path .. ": " .. tostring(err)) end
end

return LuaWriter
