-- What each installed mod's options look like, as far as the launcher can
-- know without running mod code (docs/mod-option-schema.md).
--
-- The loader writes mod_option_schemas.json after every boot, but only for
-- the mods that loaded in THAT boot: a Gold boot drops every Red-only mod's
-- rows, and a mod that declares its options with mod.options:define (rather
-- than an options_schema file) has none on disk at all.  So a merged copy is
-- kept beside it: every boot folds its rows in (Loader:_writeOptionSchemas
-- calls remember), the launcher folds in any snapshot it finds, and nothing
-- is dropped just because a later boot did not load the mod.  Like the
-- snapshot it is data, never code, and every row is re-checked on read.
local Json = require("src.link.Json")

local OptionSchemaCache = {}

OptionSchemaCache.SNAPSHOT = "mod_option_schemas.json"
OptionSchemaCache.FILE = "launcher_mod_option_schemas.json"

local TYPES = { toggle = true, choice = true, number = true, text = true }
local MAX_ROWS = 64

local function fsys(fs)
  return fs or (love and love.filesystem)
end

local function decode(fs, path)
  if not (fs and fs.getInfo and fs.getInfo(path)) then return nil end
  local okR, body = pcall(fs.read, path)
  if not okR or type(body) ~= "string" then return nil end
  local okD, doc = pcall(Json.decode, body)
  return okD and type(doc) == "table" and doc or nil
end

local function plain(value)
  local t = type(value)
  return t == "string" or t == "number" or t == "boolean"
end

-- One row, kept only if a consumer can draw it, and copied field by field so
-- nothing the file carried beyond the contract survives.
local function cleanRow(row)
  if type(row) ~= "table" or type(row.key) ~= "string" or row.key == ""
      or not TYPES[row.type] then
    return nil
  end
  local out = { key = row.key, type = row.type }
  if type(row.label) == "string" then out.label = row.label end
  if plain(row.default) then out.default = row.default end
  for _, field in ipairs({ "min", "max", "step", "maxLen" }) do
    if type(row[field]) == "number" then out[field] = row[field] end
  end
  if type(row.choices) == "table" then
    local choices = {}
    for _, pair in ipairs(row.choices) do
      if type(pair) == "table" and plain(pair[1]) and plain(pair[2]) then
        choices[#choices + 1] = { pair[1], pair[2] }
      end
    end
    if row.type == "choice" and #choices == 0 then return nil end
    out.choices = choices
  end
  local cond = row.visible_if
  if type(cond) == "table" and type(cond.key) == "string"
      and (plain(cond.equals) or plain(cond.not_equals)) then
    out.visible_if = { key = cond.key, equals = cond.equals, not_equals = cond.not_equals }
  end
  return out
end

local function cleanRows(rows)
  if type(rows) ~= "table" then return nil end
  local out = {}
  for _, row in ipairs(rows) do
    local clean = cleanRow(row)
    if clean then out[#out + 1] = clean end
    if #out >= MAX_ROWS then break end
  end
  return #out > 0 and out or nil
end
OptionSchemaCache.cleanRows = cleanRows

local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function save(fs, mods)
  if not (fs and fs.write) then return end
  local okE, body = pcall(Json.encode, { schema_version = 1, mods = mods })
  if okE then pcall(fs.write, OptionSchemaCache.FILE, body) end
end

local function readCache(fs)
  local cached = decode(fs, OptionSchemaCache.FILE)
  local mods = {}
  if cached and type(cached.mods) == "table" then
    for id, rows in pairs(cached.mods) do
      if type(id) == "string" then mods[id] = cleanRows(rows) end
    end
  end
  return mods
end

-- Fold { [modId] = rows } into the merged table; true when it changed.
local function fold(mods, incoming)
  local changed = false
  for id, rows in pairs(incoming) do
    if type(id) == "string" then
      local clean = cleanRows(rows)
      if clean and not same(mods[id], clean) then
        mods[id], changed = clean, true
      end
    end
  end
  return changed
end

-- The loader's half: called with the rows it just wrote to the snapshot, so
-- every boot is remembered whether or not the launcher opens in between.
function OptionSchemaCache.remember(fs, incoming)
  fs = fsys(fs)
  if type(incoming) ~= "table" or not (fs and fs.write) then return end
  local mods = readCache(fs)
  if fold(mods, incoming) then save(fs, mods) end
end

-- The merged table: { [modId] = rows }.  Reads the latest snapshot into it and
-- saves the result when that changed anything.
function OptionSchemaCache.load(fs)
  fs = fsys(fs)
  local mods = readCache(fs)
  local snap = decode(fs, OptionSchemaCache.SNAPSHOT)
  -- a newer document is not ours to guess at (docs/mod-option-schema.md)
  local version = snap and (snap.schema_version or 1)
  if snap and type(version) == "number" and version <= 1 and type(snap.mods) == "table"
      and fold(mods, snap.mods) then
    save(fs, mods)
  end
  return mods
end

return OptionSchemaCache
