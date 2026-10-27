-- mod.options:get checks a stored value against the mod's schema row
-- (src/mods/OptionValue.lua).  options.modOptions outlives any one version
-- of a mod, so a value saved for an older schema -- a toggle that became a
-- choice, a choice value since removed, a number past a narrowed max -- or a
-- hand-edited options.lua used to reach the mod as the wrong type.
--   luajit tests/engine/mod_option_values_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local OptionValue = require("src.mods.OptionValue")

local toggle = { key = "on", type = "toggle", default = true }
local choice = { key = "mode", type = "choice", default = "safe",
  choices = { { "Safe", "safe" }, { "Fast", "fast" } } }
local number = { key = "rate", type = "number", default = 5, min = 0, max = 10 }
local text = { key = "name", type = "text", default = "", maxLen = 4 }

eq(OptionValue.coerce(toggle, nil), true, "unset reads as the default")
eq(OptionValue.coerce(toggle, false), false, "a boolean toggle passes")
eq(OptionValue.coerce(toggle, "yes"), true, "a string toggle reads as the default")
eq(OptionValue.coerce(choice, "fast"), "fast", "a listed choice passes")
eq(OptionValue.coerce(choice, "turbo"), "safe", "a choice the mod dropped reads as the default")
eq(OptionValue.coerce(number, 7), 7, "an in-range number passes")
eq(OptionValue.coerce(number, 99), 10, "a number past max is clamped")
eq(OptionValue.coerce(number, -3), 0, "and below min")
eq(OptionValue.coerce(number, "8"), 8, "a numeric string reads as its number")
eq(OptionValue.coerce(number, "lots"), 5, "garbage reads as the default")
eq(OptionValue.coerce(number, 0 / 0), 5, "NaN reads as the default")
eq(OptionValue.coerce(text, "abcdef"), "abcd", "text is cut to maxLen")
eq(OptionValue.coerce(text, {}), "", "a table where text belongs reads as the default")
eq(OptionValue.coerce({ key = "x", type = "future" }, { 1 }) and true, true,
  "an unknown row type passes the stored value through")

-- through the real loader: what mod.options:get hands the mod
local Sdk = require("tests.modkit.sdk")
local files = {
  ["options.lua"] = 'return { mods = { opt = true }, modOptions = { opt = '
    .. '{ on = "yes", mode = "turbo", rate = 99, name = "abcdef" } } }',
  ["mods/opt/manifest.json"] = '{"id":"opt","name":"opt","version":"1.0.0",'
    .. '"entry":"main.lua","api":2}',
  ["mods/opt/main.lua"] = [[
    local mod = ...
    mod.options:define({
      { key = "on", type = "toggle", default = true },
      { key = "mode", type = "choice", default = "safe",
        choices = { { "Safe", "safe" }, { "Fast", "fast" } } },
      { key = "rate", type = "number", default = 5, min = 0, max = 10 },
      { key = "name", type = "text", default = "", maxLen = 4 },
    })
    mod.exports.read = function()
      return { on = mod.options:get("on"), mode = mod.options:get("mode"),
        rate = mod.options:get("rate"), name = mod.options:get("name"),
        missing = mod.options:get("missing") }
    end
  ]],
}
local run = Sdk.loadMods({ "mods/opt" }, { fs = Sdk.memfs(files) })
eq(#run.errors, 0, "the probe mod loads (" .. tostring(run.errors[1]) .. ")")
local exports = run.loader.exports.opt
local got = exports and exports.read() or {}
eq(got.on, true, "a stale toggle reads as its default through mod.options:get")
eq(got.mode, "safe", "a dropped choice too")
eq(got.rate, 10, "a number past max is clamped")
eq(got.name, "abcd", "text is cut to maxLen")
eq(got.missing, nil, "an undefined key is nil")
check(run.loader.modOptions.opt.on == "yes", "the stored value itself is left alone")
run.release()

T.finish("mod option values")
