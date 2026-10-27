-- The launcher shows options for mods that declare them in code
-- (mod.options:define), not just for mods with an options_schema file
-- (src/mods/OptionSchemaCache.lua).  The game's mod_option_schemas.json holds
-- only the mods THAT boot loaded, so a Gold boot used to hide every Red-only
-- mod's options; the merged copy keeps them, and every row is re-checked so
-- the file stays data the launcher can draw and nothing more.
--   luajit tests/engine/mod_option_schema_cache_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.modkit")
local Json = require("src.link.Json")
local Cache = require("src.mods.OptionSchemaCache")

local function countingFs(files)
  local fs = T.sdk.memfs(files)
  local inner = fs.write
  fs.writes = 0
  fs.write = function(path, body)
    if path == Cache.FILE then fs.writes = fs.writes + 1 end
    return inner(path, body)
  end
  return fs
end

local RATE = { key = "rate", label = "EXP RATE", type = "choice", default = "2",
               choices = { { "2X", "2" }, { "3X", "3" } } }
local SORT = { key = "sort", label = "SORT BY", type = "choice", default = "dex",
               choices = { { "DEX NO.", "dex" }, { "NAME", "name" } } }

-- ------- merging: a later boot does not drop an earlier boot's mods

do
  local files = {}
  local fs = countingFs(files)
  Cache.remember(fs, { example_dexnav = { SORT }, example_exp_boost = { RATE } })
  Cache.remember(fs, { example_exp_boost = { RATE } }) -- a Gold boot: no DexNav
  local got = Cache.load(fs)
  T.eq(got.example_dexnav and got.example_dexnav[1].key, "sort", "DexNav's rows survive a boot that did not load it")
  T.eq(got.example_exp_boost and got.example_exp_boost[1].key, "rate", "EXP Boost's rows are there")
  T.eq(fs.writes, 1, "an unchanged boot does not rewrite the file")

  local newer = { key = "rate", label = "EXP RATE", type = "choice", default = "3",
                  choices = { { "3X", "3" } } }
  Cache.remember(fs, { example_exp_boost = { newer } })
  T.eq(Cache.load(fs).example_exp_boost[1].default, "3", "a mod's new rows replace its old ones")
  T.eq(fs.writes, 2, "and that change is written")
end

-- ------- the launcher folds in a snapshot it finds

do
  local files = {
    [Cache.SNAPSHOT] = Json.encode({ schema_version = 1, mods = { example_lucky_ball = {
      { key = "tries", label = "ROLLS PER BALL", type = "choice", default = "2",
        choices = { { "2", "2" }, { "3", "3" } } } } } }),
  }
  local got = Cache.load(countingFs(files))
  T.eq(got.example_lucky_ball and got.example_lucky_ball[1].key, "tries", "a snapshot's rows are read")
  T.check(files[Cache.FILE] ~= nil, "and remembered")

  files = { [Cache.SNAPSHOT] = Json.encode({ schema_version = 2, mods = { x = { RATE } } }) }
  T.eq(Cache.load(countingFs(files)).x, nil, "a newer snapshot format is left alone")
  files = { [Cache.SNAPSHOT] = "{ not json" }
  T.eq(next(Cache.load(countingFs(files))), nil, "a broken snapshot reads as nothing")
end

-- ------- only rows the launcher can draw, and only their known fields

do
  local rows = Cache.cleanRows({
    { key = "ok", type = "toggle", default = true, label = "OK", extra = function() end },
    { key = "", type = "toggle" },
    { type = "toggle" },
    { key = "weird", type = "script" },
    { key = "empty", type = "choice", choices = {} },
    { key = "n", type = "number", min = 0, max = 9, step = "1" },
    { key = "c", type = "choice", choices = { { "A", "a" }, { {}, "b" } },
      visible_if = { key = "ok", equals = true } },
    "not a row",
  })
  T.eq(#rows, 3, "three rows survive")
  T.eq(rows[1].key, "ok", "a toggle is kept")
  T.eq(rows[1].extra, nil, "without the fields the contract does not name")
  T.eq(rows[2].max, 9, "a number keeps its numeric bounds")
  T.eq(rows[2].step, nil, "but not a bound of the wrong type")
  T.eq(#rows[3].choices, 1, "a choice keeps only well-formed pairs")
  T.eq(rows[3].visible_if and rows[3].visible_if.key, "ok", "and its visibility rule")
  T.eq(Cache.cleanRows({ { key = "x", type = "script" } }), nil, "no usable rows is no schema")
end

-- ------- the loader feeds it on every boot

local function modFiles(id, define)
  return {
    ["mods/" .. id .. "/manifest.json"] = ([[{ "id": "%s", "name": "%s",
      "version": "1.0.0", "entry": "main.lua", "api": 2, "games": ["%s"] }]])
      :format(id, id, define.games),
    ["mods/" .. id .. "/main.lua"] = "local mod = ...\nmod.options:define({ "
      .. define.row .. " })\n",
  }
end

do
  local files = {}
  for path, body in pairs(modFiles("probe_red", { games = "gen1",
      row = '{ key = "a", label = "A", type = "toggle", default = true }' })) do files[path] = body end
  for path, body in pairs(modFiles("probe_gold", { games = "gen2",
      row = '{ key = "b", label = "B", type = "toggle", default = false }' })) do files[path] = body end
  local fs = T.sdk.memfs(files)
  local run = T.sdk.loadMods({ "mods/probe_red", "mods/probe_gold" }, { fs = fs, generation = 1 })
  run.release()
  run = T.sdk.loadMods({ "mods/probe_red", "mods/probe_gold" }, { fs = fs, data = {}, generation = 2 })
  run.release()
  local snap = Json.decode(files[Cache.SNAPSHOT])
  T.eq(snap.mods.probe_red, nil, "the Gold boot's snapshot has no Red-only mod")
  local got = Cache.load(fs)
  T.eq(got.probe_red and got.probe_red[1].key, "a", "the merged copy still has its rows")
  T.eq(got.probe_gold and got.probe_gold[1].key, "b", "and the Gold mod's")
end

T.finish("mod option schema cache")
