-- A mod's assets_transforms recipe (src/mods/AssetTransform.lua) runs in a
-- restricted environment.  Two holes it used to have:
--   * it was compiled with a bare loadstring, which on LuaJIT accepts
--     precompiled bytecode -- unverified, and able to read and write memory
--     no environment table governs;
--   * it was handed the engine's own string/table/math tables, so a recipe
--     assigning string.format rewrote it for the whole game.
--   luajit tests/engine/mod_asset_transform_sandbox_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local AssetTransform = require("src.mods.AssetTransform")

local files = {}
local fs = {
  read = function(path) return files[path] end,
  write = function(path, body) files[path] = body return true end,
  getInfo = function(path) return files[path] and { type = "file" } or nil end,
  createDirectory = function() return true end,
}

local function mod(id)
  return { path = "mods/" .. id,
    manifest = { id = id, assets_transforms = "transform.lua" } }
end

-- a plain recipe still runs
files["mods/plain/transform.lua"] = "return function(ctx) end"
check(AssetTransform.runFor(mod("plain"), fs, true), "an ordinary recipe runs")

-- bytecode is refused before it runs
local ran = false
_G.__transformRan = function() ran = true end
files["mods/dumped/transform.lua"] = string.dump(function()
  return function() __transformRan() end -- luacheck: ignore
end)
local ok, err = AssetTransform.runFor(mod("dumped"), fs, true)
check(not ok and tostring(err):find("bytecode", 1, true),
  "a precompiled recipe is refused: " .. tostring(err))
check(not ran, "and nothing in it ran")
_G.__transformRan = nil

-- the standard library a recipe sees is its own copy
local realFormat, realInsert = string.format, table.insert
files["mods/stomp/transform.lua"] = [[
  string.format = function() return "stomped" end
  table.insert = nil
  return function(ctx) end
]]
check(AssetTransform.runFor(mod("stomp"), fs, true), "a recipe stomping its libraries still runs")
check(string.format == realFormat and ("%d"):format(1) == "1",
  "but the engine's string.format is untouched")
eq(table.insert, realInsert, "and so is table.insert")

T.finish("mod asset transform sandbox")
