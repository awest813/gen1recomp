-- An experimental mod stays off until the player turns it on, including on
-- the very first boot of a fresh install.  That boot also writes the
-- per-game enable buckets (SaveData.migrateModEnablement), which turned the
-- "no answer yet" the experimental check looked for into an explicit false
-- it ignored, so the mod ran once before its "off" was ever read.
--   luajit tests/engine/mod_experimental_first_boot_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local GameVersion = require("src.core.GameVersion")

GameVersion.set("red")

local function files()
  return {
    ["mods/probe_experimental/manifest.json"] = [[{
      "id": "probe_experimental",
      "name": "Probe Experimental",
      "version": "1.0.0",
      "entry": "main.lua",
      "api": 2,
      "games": ["gen1"],
      "experimental": true
    }]],
    ["mods/probe_experimental/main.lua"] = [[
      local mod = ...
      mod.exports.ran = true
    ]],
    ["mods/probe_plain/manifest.json"] = [[{
      "id": "probe_plain",
      "name": "Probe Plain",
      "version": "1.0.0",
      "entry": "main.lua",
      "api": 2,
      "games": ["gen1"]
    }]],
    ["mods/probe_plain/main.lua"] = [[
      local mod = ...
      mod.exports.ran = true
    ]],
  }
end

local MODS = { "mods/probe_experimental", "mods/probe_plain" }

do
  -- a fresh install: no options file at all
  local fs = T.sdk.memfs(files())
  local run = T.sdk.loadMods(MODS, { fs = fs, generation = 1 })
  local exp = run.loader.mods.probe_experimental
  T.eq(exp and exp.enabled, false, "first boot: the experimental mod is off")
  T.eq(run.loader.exports.probe_experimental, nil, "and its entry never ran")
  T.eq(run.loader.mods.probe_plain and run.loader.mods.probe_plain.enabled, true,
    "while an ordinary mod is on by default")
  run.release()

  -- the second boot reads what the first one wrote: still off
  run = T.sdk.loadMods(MODS, { fs = fs, generation = 1 })
  T.eq(run.loader.mods.probe_experimental.enabled, false, "second boot: still off")
  run.release()
end

do
  -- the player opted in for this game: it runs
  local f = files()
  f["options.lua"] = "return { modsByVersion = { red = { probe_experimental = true } } }"
  local run = T.sdk.loadMods(MODS, { fs = T.sdk.memfs(f), generation = 1 })
  T.eq(run.loader.mods.probe_experimental.enabled, true, "an opted-in experimental mod runs")
  run.release()
end

T.finish("mod experimental first boot")
