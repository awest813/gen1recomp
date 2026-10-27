-- src/mods/ModLibrary.lua: the installed-mods library the PK:GB launcher
-- uses.  No pokered cite: port-only mod tooling.
--
-- Pins the contract with src/mods/Loader.lua: a mod is a folder under mods/
-- with a valid manifest.json; it runs when SaveData.modEnabled says so, a
-- missing answer meaning on except for experimental mods; a .zip installs to
-- mods/<id>/ from its root or its one top-level folder; uninstall stays
-- inside mods/.
--   luajit tests/engine/mod_library_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- An in-memory save directory with the love.filesystem calls ModLibrary uses.
local files, dirs = {}, {}
local archives = {}   -- zip bytes -> { [relative path] = contents }
local mounts = {}
local fs = {}
local function parent(path) return path:match("^(.*)/[^/]+$") end
function fs.getInfo(path)
  if dirs[path] then return { type = "directory" } end
  if files[path] then return { type = "file", size = #files[path] } end
  return nil
end
function fs.getDirectoryItems(path)
  local out, seen = {}, {}
  local function add(p)
    if parent(p) == path then
      local name = p:sub(#path + 2)
      if not seen[name] then seen[name] = true out[#out + 1] = name end
    end
  end
  for p in pairs(files) do add(p) end
  for p in pairs(dirs) do add(p) end
  table.sort(out)
  return out
end
function fs.read(path) return files[path] end
function fs.createDirectory(path)
  local at = ""
  for part in path:gmatch("[^/]+") do
    at = at == "" and part or (at .. "/" .. part)
    dirs[at] = true
  end
  return true
end
function fs.write(path, body)
  fs.createDirectory(parent(path) or "")
  files[path] = body
  return true
end
function fs.remove(path)
  if files[path] then files[path] = nil return true end
  if dirs[path] and #fs.getDirectoryItems(path) == 0 then dirs[path] = nil return true end
  return false
end
function fs.newFileData(bytes, name) return { bytes = bytes, name = name } end
function fs.mount(data, point)
  local tree = archives[data.bytes]
  if not tree then return false end
  dirs[point] = true
  for rel, body in pairs(tree) do fs.write(point .. "/" .. rel, body) end
  mounts[data] = point
  return true
end
function fs.unmount(data)
  local point = mounts[data]
  if not point then return false end
  for p in pairs(files) do if p:sub(1, #point + 1) == point .. "/" then files[p] = nil end end
  for p in pairs(dirs) do if p == point or p:sub(1, #point + 1) == point .. "/" then dirs[p] = nil end end
  mounts[data] = nil
  return true
end
love.filesystem = setmetatable(fs, { __index = love.filesystem })

local options, saves = {}, 0
local SaveData = require("src.core.SaveData")
SaveData.loadOptions = function() return options end
SaveData.saveOptions = function(o) options = o; saves = saves + 1 return true end

local ModLibrary = require("src.mods.ModLibrary")

local function manifest(id, extra)
  local parts = { ('"id":"%s"'):format(id), ('"name":"%s mod"'):format(id),
    '"version":"1.0.0"', '"entry":"main.lua"' }
  for _, p in ipairs(extra or {}) do parts[#parts + 1] = p end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- ------------------------------------------------------------------ list
eq(#ModLibrary.list("gold"), 0, "no mods folder lists nothing")
fs.write("mods/zeta/manifest.json", manifest("zeta"))
fs.write("mods/zeta/main.lua", "return {}")
fs.write("mods/alpha/manifest.json", manifest("alpha", { '"experimental":true' }))
fs.write("mods/broken/manifest.json", '{"id":"broken"}')
fs.write("mods/stray.txt", "not a mod")
fs.write("mods/examples/readme.md", "a folder of examples, no manifest")
local rows = ModLibrary.list("gold")
eq(#rows, 3, "every mod folder is listed; loose files and manifest-less folders are not")
eq(rows[1].id, "alpha", "sorted by name")
check(rows[1].experimental and rows[1].enabled == false,
  "an experimental mod with no answer is off, as the loader treats it")
local zeta
for _, r in ipairs(rows) do if r.id == "zeta" then zeta = r end end
check(zeta and zeta.enabled == true, "an ordinary mod with no answer is on")
check(zeta.supported ~= nil, "each row says whether it targets the game")
local broken
for _, r in ipairs(rows) do if r.id == "broken" then broken = r end end
check(broken and broken.broken, "an invalid manifest is listed as broken, with why")
check(broken.broken:find("name is required", 1, true) and not broken.broken:find(".lua:", 1, true),
  "the reason is the player's, without a source location")
check(not zeta.bundled, "a mod in the save directory is removable")
fs.getRealDirectory = function(p) return p == "mods/zeta" and "/game" or "/save" end
fs.getSaveDirectory = function() return "/save" end
for _, r in ipairs(ModLibrary.list("gold")) do
  if r.id == "zeta" then check(r.bundled, "a mod shipped in the game folder is marked built in") end
  if r.id == "alpha" then check(not r.bundled, "one in the save directory is not") end
end
fs.getRealDirectory, fs.getSaveDirectory = nil, nil

-- ------------------------------------------------------------ setEnabled
ModLibrary.setEnabled("zeta", false, "gold")
eq(saves, 1, "toggling saves the options once")
eq(SaveData.modEnabled(options, "zeta", SaveData.modScope("gold")), false,
  "the loader's own lookup now reads it as off")
for _, r in ipairs(ModLibrary.list("gold")) do
  if r.id == "zeta" then eq(r.enabled, false, "and the list agrees") end
end
ModLibrary.setEnabled("alpha", true, "gold")
for _, r in ipairs(ModLibrary.list("gold")) do
  if r.id == "alpha" then eq(r.enabled, true, "an experimental mod can be opted in") end
end

-- ------------------------------------------------------------ installZip
local nested = "PK\3\4nested"
archives[nested] = {
  ["cool-mod-main/manifest.json"] = manifest("cool", { '"dependencies":["zeta","base"]' }),
  ["cool-mod-main/main.lua"] = "return {}",
  ["cool-mod-main/sprites/a.png"] = "png",
}
local got, err = ModLibrary.installZip(nested, "cool.zip")
check(got and got.id == "cool", "a zip with one top-level folder installs: " .. tostring(err))
eq(files["mods/cool/sprites/a.png"], "png", "the whole folder is copied to mods/<id>/")
check(files["mods/cool/manifest.json"] ~= nil, "manifest included")
local leftover = false
for p in pairs(files) do if p:find("__mod_install_", 1, true) then leftover = true end end
check(not leftover, "the archive is unmounted afterwards")
local missing = ModLibrary.missingDependencies(got, ModLibrary.list())
eq(table.concat(missing, ","), "base", "a missing dependency is named; an installed one is not")

local again, againErr, info = ModLibrary.installZip(nested, "cool.zip")
check(not again and againErr:find("already installed", 1, true) and info.exists,
  "installing over an existing mod asks first")
files["mods/cool/old.lua"] = "stale"
check(ModLibrary.installZip(nested, "cool.zip", { replace = true }),
  "and replaces it when asked")
eq(files["mods/cool/old.lua"], nil, "a replace drops the old mod's files")

local flat = "PK\3\4flat"
archives[flat] = { ["manifest.json"] = manifest("flat"), ["main.lua"] = "return {}" }
check(ModLibrary.installZip(flat, "flat.zip"), "a zip with the manifest at its root installs")
eq(files["mods/flat/main.lua"], "return {}", "to mods/<id>/")

local empty = "PK\3\4empty"
archives[empty] = { ["readme.txt"] = "hi" }
local no, why = ModLibrary.installZip(empty, "empty.zip")
check(not no and why:find("no manifest", 1, true), "a zip without a manifest is refused")
local bad = "PK\3\4bad"
archives[bad] = { ["manifest.json"] = '{"id":"../evil","name":"x","version":"1","entry":"m.lua"}' }
no, why = ModLibrary.installZip(bad, "bad.zip")
check(not no and why:find("invalid manifest", 1, true), "an unsafe id never validates")
check(not dirs["evil"] and not dirs["mods/../evil"], "and nothing is written")
no, why = ModLibrary.installZip("hello", "x.zip")
check(not no and why:find("not a .zip", 1, true), "a non-zip is refused before mounting")
no = ModLibrary.installZip("", "x.zip")
check(not no, "an empty file is refused")

-- ------------------------------------------------------------- uninstall
check(ModLibrary.uninstall("mods/flat"), "uninstall removes a mod folder")
check(not fs.getInfo("mods/flat") and not files["mods/flat/main.lua"], "with its files")
check(not ModLibrary.uninstall("mods/../save"), "but never climbs out of mods/")
check(not ModLibrary.uninstall("save/options"), "or touches anything else")

-- -------------------------------------------------- upgrade and shadowing
local v2 = "PK\3\4v2"
archives[v2] = { ["manifest.json"] = manifest("cool"):gsub('"1.0.0"', '"1.1.0"'), ["main.lua"] = "v2" }
local up = ModLibrary.installZip(v2, "cool.zip", { upgrade = true })
check(up and up.version == "1.1.0", "an upgrade installs a newer version over the old")
eq(files["mods/cool/main.lua"], "v2", "replacing its files")
local same, sameErr = ModLibrary.installZip(v2, "cool.zip", { upgrade = true })
check(not same and sameErr:find("already installed", 1, true), "the same version is not reinstalled")
fs.write("mods/shadow/manifest.json", manifest("shadow"))
fs.getRealDirectory = function() return "/game" end
fs.getSaveDirectory = function() return "/save" end
local realRemove = fs.remove
fs.remove = function(p) if p == "mods/shadow" then return false end return realRemove(p) end
fs.write("mods/shadow/x", "y")
dirs["mods/shadow"] = true
check(ModLibrary.uninstall("mods/shadow"), "uninstalling over a built-in copy of the same mod succeeds")
fs.remove, fs.getRealDirectory, fs.getSaveDirectory = realRemove, nil, nil

-- --------------------------------------------------- sync and translations
local rowsBy = {}
for _, r in ipairs(ModLibrary.syncRows()) do rowsBy[r.id] = r end
check(rowsBy.zeta and type(rowsBy.zeta.enabledByVersion) == "table", "sync rows carry per-game answers")
eq(rowsBy.zeta.enabledByVersion.gold, false, "including a mod switched off for one game")
eq(rowsBy.broken, nil, "a broken mod is not synced")

eq(next(ModLibrary.modOptions()), nil, "no mod options saved yet")
check(ModLibrary.setModOptions("zeta", { speed = 2, mode = "fast", bad = {} }), "mod options save")
eq(ModLibrary.modOptions().zeta.speed, 2, "and read back")
eq(ModLibrary.modOptions().zeta.bad, nil, "keeping only plain values")

fs.write("mods/alpha/lang/strings.lua", 'return { ["Hello"] = "Bonjour", [3] = "x", Bye = 4 }')
fs.write("mods/zeta/lang/strings.lua", 'return { ["Hello"] = "Hallo" }')
local catalog = ModLibrary.translationStrings("gold")
eq(catalog and catalog.Hello, "Bonjour", "an enabled mod's lang/strings.lua reaches the catalog")
eq(catalog.Bye, nil, "only string pairs are kept")
local zetaOn = ModLibrary.translationStrings("red")
eq(zetaOn and zetaOn.Hello, "Hallo", "a later mod (by id) wins a key where it is enabled")
fs.write("mods/alpha/lang/strings.lua", 'os.exit(1) return {}')
fs.write("mods/zeta/lang/strings.lua", 'return {}')
eq(ModLibrary.translationStrings("gold"), nil, "a catalog cannot reach the os library")

-- install from an index entry
local bytes = "PK\3\4indexed"
archives[bytes] = { ["manifest.json"] = manifest("indexed"), ["main.lua"] = "return {}" }
package.loaded["src.core.HostShell"] = { httpGet = function(url)
  if url == "https://example.com/indexed.zip" then return bytes end
  return nil, "404"
end }
package.loaded["src.mods.ModIndex"] = { installUrl = function(entry)
  return entry.downloadURL, "download" end }
check(ModLibrary.installFromIndex({ id = "indexed", downloadURL = "https://example.com/indexed.zip" }),
  "a mod index entry downloads and installs")
check(files["mods/indexed/main.lua"] ~= nil, "into mods/<id>/")
local okI, errI = ModLibrary.installFromIndex({ id = "gone", downloadURL = "https://example.com/gone.zip" })
check(not okI and errI == "404", "a failed download says why")

eq(table.concat(ModLibrary.missingDependencies({ dependencies = { "colorlib@^1.2.0#Acme/ColorLib", "zeta" } },
  ModLibrary.list()), ","), "colorlib", "a dependency written as id@range#repo is matched by its id")

-- --------------------------------------------- uninstall stays one folder
for _, bad in ipairs({ "mods/", "mods", "mods/cool/sprites", "mods/./", "mods/.." }) do
  check(not ModLibrary.uninstall(bad), ("uninstall refuses %q"):format(bad))
end
check(files["mods/cool/sprites/a.png"] == nil and files["mods/cool/main.lua"] == "v2"
  and files["mods/zeta/manifest.json"] ~= nil,
  "and the library is untouched afterwards")

-- ------------------------------ an install never lands on another mod's folder
fs.write("mods/squatter/manifest.json", manifest("other"))
fs.write("mods/squatter/main.lua", "other's code")
local squat = "PK\3\4squat"
archives[squat] = { ["manifest.json"] = manifest("squatter"), ["main.lua"] = "mine" }
local okSq, whySq = ModLibrary.installZip(squat, "squatter.zip", { replace = true })
check(not okSq and tostring(whySq):find("another mod", 1, true),
  "mods/<id> holding a different mod refuses, even with replace: " .. tostring(whySq))
eq(files["mods/squatter/main.lua"], "other's code", "the other mod's files are kept")

fs.write("mods/Cased/readme.txt", "a folder, no manifest")
local cased = "PK\3\4cased"
archives[cased] = { ["manifest.json"] = manifest("cased"), ["main.lua"] = "x" }
local okCa, whyCa = ModLibrary.installZip(cased, "cased.zip")
check(not okCa and tostring(whyCa):find("letter case", 1, true),
  "a folder differing only in case is refused (it would merge on Windows): " .. tostring(whyCa))
eq(files["mods/cased/main.lua"], nil, "and nothing is written")

-- a mod unzipped by hand under another folder name is upgraded in place
fs.write("mods/handmade-main/manifest.json", manifest("handmade"))
fs.write("mods/handmade-main/main.lua", "v1")
local hand2 = "PK\3\4hand2"
archives[hand2] = { ["manifest.json"] = manifest("handmade"):gsub('"1.0.0"', '"2.0.0"'),
  ["main.lua"] = "v2" }
check(ModLibrary.installZip(hand2, "handmade.zip", { upgrade = true }),
  "an upgrade finds the installed copy by its manifest id")
eq(files["mods/handmade-main/main.lua"], "v2", "and replaces it where it lives")
eq(files["mods/handmade/main.lua"], nil, "instead of adding a duplicate id under mods/<id>")

-- ------------------------------------------ a failed write leaves no wreck
local realWrite = fs.write
local function failWritesUnder(prefix)
  fs.write = function(path, body)
    if path:sub(1, #prefix) == prefix and path:find("big.bin", 1, true) then
      return false, "disk full"
    end
    return realWrite(path, body)
  end
end
local partial = "PK\3\4partial"
archives[partial] = { ["manifest.json"] = manifest("partial"), ["a.lua"] = "a",
  ["big.bin"] = "x" }
failWritesUnder("mods/partial")
local okP, whyP = ModLibrary.installZip(partial, "partial.zip")
fs.write = realWrite
check(not okP and tostring(whyP):find("disk full", 1, true), "a failed write fails the install")
eq(fs.getInfo("mods/partial"), nil, "and no half-installed folder is left for the loader")

local upFail = "PK\3\4upfail"
archives[upFail] = { ["manifest.json"] = manifest("cool"):gsub('"1.0.0"', '"9.0.0"'),
  ["main.lua"] = "v9", ["big.bin"] = "x" }
failWritesUnder(ModLibrary.STAGING)
local okU = ModLibrary.installZip(upFail, "cool.zip", { upgrade = true })
fs.write = realWrite
check(not okU, "an upgrade whose copy fails reports it")
eq(files["mods/cool/main.lua"], "v2", "and the old version still works")
eq(fs.getInfo(ModLibrary.STAGING .. "/cool"), nil, "with no staged copy left over")

-- ------------------- an update keeps the files the player supplied
fs.write("mods/romuser/manifest.json", manifest("romuser"))
fs.write("mods/romuser/main.lua", "v1")
fs.write("mods/romuser/baseroms/game.n64", "player's rom")
fs.write("mods/romuser/baseroms/.required-import-game.validated", "receipt")
fs.write("mods/romuser/baseroms/shipped.txt", "old shipped")
local romV2 = "PK\3\4romv2"
archives[romV2] = { ["manifest.json"] = manifest("romuser"):gsub('"1.0.0"', '"1.1.0"'),
  ["main.lua"] = "v2", ["baseroms/shipped.txt"] = "new shipped" }
check(ModLibrary.installZip(romV2, "romuser.zip", { upgrade = true }), "the update installs")
eq(files["mods/romuser/main.lua"], "v2", "with the new code")
eq(files["mods/romuser/baseroms/game.n64"], "player's rom",
  "and the ROM the player supplied for required_imports survives")
eq(files["mods/romuser/baseroms/.required-import-game.validated"], "receipt",
  "with its validation receipt")
eq(files["mods/romuser/baseroms/shipped.txt"], "new shipped", "but a file the update ships wins")

-- ------------------------------------- translations are data, never bytecode
fs.write("mods/zeta/lang/strings.lua", string.dump(function() return { Hello = "Bytecode" } end))
ModLibrary.setEnabled("zeta", true, "gold")
local bc = ModLibrary.translationStrings("gold")
check(not (bc and bc.Hello == "Bytecode"), "a precompiled lang/strings.lua is refused")

-- ------------------------------------------------------------ the gallery
do
  fs.write("mods/examples/ex_gold/manifest.json", manifest("ex_gold",
    { '"games":["gold","silver"]', '"description":"Gold things"' }))
  fs.write("mods/examples/ex_gold/main.lua", "return function() end")
  fs.write("mods/examples/ex_gold/assets/a.png", "PNG")
  fs.write("mods/examples/ex_gold/tests/ex_gold_test.lua", "-- a suite")
  fs.write("mods/examples/ex_gold/tools/make.py", "# a script")
  fs.write("mods/examples/ex_gold/.modkitignore", "tests/")
  fs.write("mods/examples/ex_red/manifest.json", manifest("ex_red", { '"games":["red"]' }))
  fs.write("mods/examples/ex_red/main.lua", "return function() end")
  fs.write("mods/examples/notes.md", "not an example")

  local rows = ModLibrary.examples("gold")
  eq(#rows, 2, "every bundled example with a manifest is listed")
  eq(rows[1].id, "ex_gold", "the one for this game first")
  eq(rows[1].supported, true, "marked as running here")
  eq(rows[2].supported, false, "and the other marked as not")
  eq(rows[1].description, "Gold things", "with what it does")
  eq(rows[1].installed, false, "and not installed yet")
  for _, r in ipairs(ModLibrary.list("gold")) do
    check(r.id ~= "ex_gold", "an example is not an installed mod until it is installed")
  end

  local got, err = ModLibrary.installExample("ex_gold")
  eq(got and got.id, "ex_gold", "an example installs (" .. tostring(err) .. ")")
  check(files["mods/ex_gold/main.lua"] and files["mods/ex_gold/assets/a.png"],
    "into mods/<id>, with its assets")
  eq(files["mods/ex_gold/tests/ex_gold_test.lua"], nil, "but not its test suite")
  eq(files["mods/ex_gold/tools/make.py"], nil, "or its asset scripts")
  eq(files["mods/ex_gold/.modkitignore"], nil, "or its packaging file")
  eq(ModLibrary.examples("gold")[1].installed, true, "it now reads as installed")
  local listed
  for _, r in ipairs(ModLibrary.list("gold")) do if r.id == "ex_gold" then listed = r end end
  check(listed and listed.enabled, "and is an installed mod, on like any new one")

  files["mods/ex_gold/main.lua"] = "-- the player's edit"
  local again, why = ModLibrary.installExample("ex_gold")
  eq(again, nil, "installing it twice is refused")
  check(tostring(why):find("already installed", 1, true), "with the reason")
  eq(files["mods/ex_gold/main.lua"], "-- the player's edit", "and the player's copy is untouched")
  eq(ModLibrary.examples("gold")[1].outdated, true, "a copy that differs from this build's reads as outdated")
  local upd, uerr = ModLibrary.installExample("ex_gold", { replace = true })
  eq(upd and upd.id, "ex_gold", "replace updates it (" .. tostring(uerr) .. ")")
  check(files["mods/ex_gold/main.lua"] ~= "-- the player's edit", "with this build's main.lua")
  check(files["mods/ex_gold/assets/a.png"] ~= nil, "and its assets")
  eq(ModLibrary.examples("gold")[1].outdated, nil, "after which it is current")

  eq((ModLibrary.installExample("../zeta")), nil, "a path is not an example name")
  eq((ModLibrary.installExample("missing")), nil, "an example not in this build is refused")
  ModLibrary.uninstall("mods/ex_gold")
end

T.finish("mod library")
