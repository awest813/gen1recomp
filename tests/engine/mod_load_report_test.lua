-- A mod that is on but fails to start reads as failed in the launcher, not
-- as a green "On": the loader writes which mods failed on each game's last
-- boot (Loader:_writeLoadReport) and the launcher's mod list reads it
-- (ModsPage:lastFailure).
--   luajit tests/engine/mod_load_report_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.modkit")
local Json = require("src.link.Json")
local Loader = require("src.mods.Loader")
local GameVersion = require("src.core.GameVersion")

local FILE = Loader.LOAD_REPORT_FILENAME

local function modFiles(files, id, body)
  files["mods/" .. id .. "/manifest.json"] = ([[{ "id": "%s", "name": "%s",
    "version": "1.0.0", "entry": "main.lua", "api": 2, "games": ["gen1"] }]]):format(id, id)
  files["mods/" .. id .. "/main.lua"] = body
end

local files = {}
modFiles(files, "probe_ok", "local mod = ...\n")
modFiles(files, "probe_bad", "error('the asset pack is missing', 0)\n")
modFiles(files, "probe_gold", "local mod = ...\n")
files["mods/probe_gold/manifest.json"] = files["mods/probe_gold/manifest.json"]:gsub('"gen1"', '"gen2"')
local fs = T.sdk.memfs(files)
local realGet = GameVersion.get
GameVersion.get = function() return "yellow" end

local run = T.sdk.loadMods({ "mods/probe_ok", "mods/probe_bad", "mods/probe_gold" }, { fs = fs, generation = 1 })
run.release()
local doc = files[FILE] and Json.decode(files[FILE])
local yellow = doc and doc.versions and doc.versions.yellow
T.check(yellow and yellow.probe_bad ~= nil, "a mod that failed is in Yellow's report")
T.check(yellow and tostring(yellow.probe_bad.reason):find("asset pack", 1, true) ~= nil,
  "with its reason")
T.eq(yellow and yellow.probe_ok, nil, "a mod that started is not")
T.eq(yellow and yellow.probe_gold, nil, "nor one left out because it is for another game")

-- fixed: the next boot clears it
files["mods/probe_bad/main.lua"] = "local mod = ...\n"
run = T.sdk.loadMods({ "mods/probe_ok", "mods/probe_bad" }, { fs = fs, generation = 1 })
run.release()
doc = Json.decode(files[FILE])
T.eq(doc.versions.yellow and doc.versions.yellow.probe_bad, nil, "a mod that starts again drops out")
GameVersion.get = realGet

-- the launcher reads it
love.filesystem.write(FILE, Json.encode({ schema_version = 1, versions = {
  yellow = { probe_bad = { reason = "needs an asset pack", version = "1.0.0" } } } }))
local ModsPage = require("src.launcher.ModsPage")
local page = setmetatable({ launcher = {} }, { __index = ModsPage })
T.eq(page:lastFailure("yellow", { id = "probe_bad", version = "1.0.0" }), "needs an asset pack",
  "the launcher knows why it did not start")
T.eq(page:lastFailure("gold", { id = "probe_bad", version = "1.0.0" }), nil, "only for the game it failed in")
T.eq(page:lastFailure("yellow", { id = "probe_bad", version = "1.1.0" }), nil,
  "and not once the mod has been updated")
love.filesystem.remove(FILE)

T.finish("mod load report")
