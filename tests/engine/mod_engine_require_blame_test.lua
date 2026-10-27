-- A mod is only blamed for the requires it makes.  On a Gold or FireRed
-- boot the loader's require tripwire logs "undeclared engine_internals
-- require" for each src.* module a mod reaches for, and the sandbox it builds
-- for that mod used to require src.core.LuaCompat lazily, while the mod was
-- the current one -- so the first mod loaded was warned about a require it
-- never made.
--   luajit tests/engine/mod_engine_require_blame_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Logger = require("src.core.Logger")

local FILES = {
  ["mods/probe_plain/manifest.json"] = [[{
    "id": "probe_plain", "name": "Probe Plain", "version": "1.0.0",
    "entry": "main.lua", "api": 2, "games": ["all"]
  }]],
  ["mods/probe_plain/main.lua"] = "local mod = ...\nmod.exports.ran = true\n",
}

for _, gen in ipairs({ 2, 3 }) do
  local warned = {}
  local realWarn = Logger.warn
  Logger.warn = function(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warned[#warned + 1] = ok and line or tostring(fmt)
  end
  -- not loaded yet, the way a real boot reaches its first mod
  package.loaded["src.core.LuaCompat"] = nil
  local run = T.sdk.loadMods({ "mods/probe_plain" },
    { fs = T.sdk.memfs(FILES), data = gen == 3 and T.sdk.gen3Data() or {}, generation = gen })
  Logger.warn = realWarn
  T.eq(run.loader.exports.probe_plain and run.loader.exports.probe_plain.ran, true,
    "gen " .. gen .. ": the mod ran")
  local blamed
  for _, line in ipairs(warned) do
    if line:find("probe_plain") and line:find("undeclared") then blamed = line end
  end
  T.eq(blamed, nil, "gen " .. gen .. ": the mod is not warned about the engine's own require")
  run.release()
end

T.finish("mod engine require blame")
