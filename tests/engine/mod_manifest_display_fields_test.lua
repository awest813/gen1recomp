-- A manifest's display-only fields (category, description) arrive from
-- anybody's JSON.  A number or object category used to pass validation and
-- then crash the in-game mod manager's category sort for every installed
-- mod ("attempt to compare number with string").  Manifest.validate now
-- falls back to the default instead.
--   luajit tests/engine/mod_manifest_display_fields_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local Manifest = require("src.mods.Manifest")

local function raw(extra)
  local m = { id = "probe", name = "Probe", version = "1.0.0", entry = "main.lua", api = 2 }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

for _, bad in ipairs({ 5, { "GAMEPLAY" }, true, "" }) do
  local ok, m = pcall(Manifest.validate, raw({ category = bad }))
  check(ok, ("a %s category does not fail the mod: %s"):format(type(bad), tostring(m)))
  eq(ok and m.category, "OTHER", ("a %s category falls back to OTHER"):format(type(bad)))
end
local okD, md = pcall(Manifest.validate, raw({ description = { text = "x" } }))
check(okD and md.description == "", "an object description falls back to empty")
local okG, mg = pcall(Manifest.validate, raw({ category = "GAMEPLAY", description = "fine" }))
check(okG and mg.category == "GAMEPLAY" and mg.description == "fine",
  "well-typed fields pass through")

-- the manager's grouping sorts categories; mixed types must not reach it
local ManagerState = require("src.mods.ManagerState")
local a = Manifest.validate(raw({ id = "a", category = 7 }))
local b = Manifest.validate(raw({ id = "b", category = "GAMEPLAY" }))
local manager = setmetatable({ status = { available = { a, b } } }, ManagerState)
manager.glyphFor = function() return " " end
local okRows, rows = pcall(ManagerState.modRows, manager)
check(okRows, "the manager groups the mods without a sort crash: " .. tostring(rows))

T.finish("mod manifest display fields")
