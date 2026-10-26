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

T.finish("mod library")
