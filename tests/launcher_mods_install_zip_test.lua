-- LauncherMods.installZip: PK gate, FileData mount preference, path fallback.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local S = require("tests.harness").suite("launcher mods installZip mount")
local eq = S.eq
local check = S.check

local MOD_ID = "mount_probe"
local ARCHIVE = {
  [MOD_ID .. "/manifest.json"] =
    ('{"id":"%s","name":"Mount Probe","version":"1.0.0","entry":"main.lua"}')
      :format(MOD_ID),
  [MOD_ID .. "/main.lua"] = "return function() end\n",
}

local files, dirs, arch = {}, {}, {}
local fileDataMounts, pathMounts, stagedTemps = 0, 0, {}
local stagedEver = false
local failWriteOnce

local function resetFs()
  for k in pairs(files) do files[k] = nil end
  for k in pairs(dirs) do dirs[k] = nil end
  for k in pairs(arch) do arch[k] = nil end
  fileDataMounts, pathMounts = 0, 0
  stagedTemps = {}
  stagedEver = false
  failWriteOnce = nil
end

local function dirChild(key, name)
  if name == nil or name == "" then return key:match("^[^/]+") end
  local prefix = name .. "/"
  if key:sub(1, #prefix) ~= prefix then return nil end
  return key:sub(#prefix + 1):match("^[^/]+")
end

local function mapInfo(map, name, kind)
  if map[name] ~= nil then return { type = kind or "file" } end
  for key in pairs(map) do
    if dirChild(key, name) then return { type = "directory" } end
  end
  return nil
end

local vfs = {}

function vfs.write(name, data)
  if failWriteOnce == name then
    failWriteOnce = nil
    return nil, "simulated write failure"
  end
  files[name] = data
  if name:match("^mod_import_") then
    stagedTemps[name] = true
    stagedEver = true
  end
  return true
end

function vfs.read(name)
  if arch[name] ~= nil then return arch[name] end
  return files[name]
end

function vfs.remove(name)
  files[name] = nil
  dirs[name] = nil
  stagedTemps[name] = nil
  return true
end

function vfs.createDirectory(name)
  dirs[name] = true
  return true
end

function vfs.getInfo(name, kind)
  local info = mapInfo(arch, name)
    or mapInfo(files, name)
    or mapInfo(dirs, name, "directory")
  if info and kind and info.type ~= kind then return nil end
  return info
end

function vfs.getDirectoryItems(name)
  local seen, items = {}, {}
  local function add(child)
    if child and not seen[child] then
      seen[child] = true
      items[#items + 1] = child
    end
  end
  for key in pairs(arch) do add(dirChild(key, name)) end
  for key in pairs(files) do add(dirChild(key, name)) end
  for key in pairs(dirs) do add(dirChild(key, name)) end
  table.sort(items)
  return items
end

function vfs.mount(archive, point)
  if type(archive) == "table" and archive.__filedata then
    fileDataMounts = fileDataMounts + 1
  else
    pathMounts = pathMounts + 1
  end
  for rel, body in pairs(ARCHIVE) do
    arch[point .. "/" .. rel] = body
  end
  return true
end

function vfs.unmount()
  for k in pairs(arch) do arch[k] = nil end
  return true
end

function vfs.newFileData(data, name)
  return { __filedata = true, data = data, name = name }
end

function vfs.getSaveDirectory()
  return "/tmp/pokeport-install-zip-test"
end

function vfs.getSource()
  return nil
end

local savedFs = love.filesystem
local savedCacheFs = package.loaded["src.import.CacheFs"]
local savedLauncherMods = package.loaded["src.mods.LauncherMods"]
local savedSaveDataPortable = nil

local SaveData = require("src.core.SaveData")
savedSaveDataPortable = SaveData.portableBaseDir

local function freshMods()
  package.loaded["src.import.CacheFs"] = nil
  package.loaded["src.mods.LauncherMods"] = nil
  SaveData.portableBaseDir = function() return nil end
  return require("src.mods.LauncherMods")
end

love.filesystem = vfs
local LauncherMods = freshMods()

-- Reject non-PK / empty / AppleDouble-shaped bytes before mount
resetFs()
files["imports/mods/junk.zip"] = "\0\5\22\7AppleDouble"
local ok, err = LauncherMods.installZip("imports/mods/junk.zip")
check(not ok, "non-PK bytes are rejected")
check(tostring(err):find("not a zip file", 1, true),
  "rejection names not a zip file")
eq(fileDataMounts + pathMounts, 0, "invalid zip never mounts")

resetFs()
files["imports/mods/empty.zip"] = ""
ok, err = LauncherMods.installZip("imports/mods/empty.zip")
check(not ok, "empty file is rejected")
check(tostring(err):find("not a zip file", 1, true),
  "empty rejection is not a zip file")

-- Prefer FileData / in-memory mount for relative save-dir zips
resetFs()
files["imports/mods/good.zip"] = "PK\3\4relative-inbox"
ok, err = LauncherMods.installZip("imports/mods/good.zip")
check(ok == true, "PK zip installs via relative love.filesystem path ("
  .. tostring(err) .. ")")
eq(err, MOD_ID, "install reports manifest id")
eq(fileDataMounts, 1, "relative zip prefers FileData mount")
eq(pathMounts, 0, "relative zip does not fall back to path mount when FileData works")
local staged = 0
for _ in pairs(stagedTemps) do staged = staged + 1 end
eq(staged, 0, "FileData path leaves no staged temp zip")
check(files["mods/" .. MOD_ID .. "/manifest.json"] ~= nil,
  "install wrote manifest into mods/")

-- A third-party archive cannot bypass modkit's no-baseroms packaging gate.
resetFs()
ARCHIVE[MOD_ID .. "/baseroms/source.z64"] = "packaged rom"
files["imports/mods/packaged-rom.zip"] = "PK\3\4packaged-rom"
ok, err = LauncherMods.installZip("imports/mods/packaged-rom.zip")
check(not ok, "an archive containing baseroms is rejected")
check(tostring(err):find("must not include", 1, true),
  "baseroms archive rejection explains the policy")
ARCHIVE[MOD_ID .. "/baseroms/source.z64"] = nil

-- Fallback: no newFileData → stage temp + path mount
resetFs()
vfs.newFileData = nil
package.loaded["src.mods.LauncherMods"] = nil
package.loaded["src.import.CacheFs"] = nil
LauncherMods = freshMods()
files["imports/mods/fallback.zip"] = "PK\3\4fallback"
ok, err = LauncherMods.installZip("imports/mods/fallback.zip")
check(ok == true, "install still works without newFileData ("
  .. tostring(err) .. ")")
eq(fileDataMounts, 0, "no FileData mounts when API absent")
eq(pathMounts, 1, "falls back to path mount")
check(stagedEver, "fallback stages a mod_import_*.zip temp")
local leftover = 0
for _ in pairs(stagedTemps) do leftover = leftover + 1 end
eq(leftover, 0, "fallback cleans staged temp after install")

-- #801: a same-id copy under a different folder name is replaced too, so the
-- update cannot leave a shadow copy for discover()'s first-id-wins race
resetFs()
files["mods/WildsOfKanto-1.5.0/manifest.json"] =
  ('{"id":"%s","name":"Old Copy","version":"0.9.0","entry":"main.lua"}')
    :format(MOD_ID)
files["mods/WildsOfKanto-1.5.0/main.lua"] = "return function() end\n"
files["imports/mods/update.zip"] = "PK\3\4update"
ok, err = LauncherMods.installZip("imports/mods/update.zip",
  { replace = true, expectId = MOD_ID })
check(ok == true, "replace install succeeds over an odd-named copy ("
  .. tostring(err) .. ")")
check(files["mods/WildsOfKanto-1.5.0/manifest.json"] == nil,
  "odd-named same-id folder is removed by the replace")
check(files["mods/" .. MOD_ID .. "/manifest.json"] ~= nil,
  "replace still lands in mods/<id>")

-- User-selected baseroms belong to the installation, not the downloaded mod
-- archive, and survive the same replacement path.
resetFs()
files["mods/OldFolder/manifest.json"] =
  ('{"id":"%s","name":"Old Copy","version":"0.9.0","entry":"main.lua"}')
    :format(MOD_ID)
files["mods/OldFolder/main.lua"] = "return function() end\n"
files["mods/OldFolder/baseroms/stadium2.z64"] = "user-owned-rom"
files["imports/mods/update-with-rom.zip"] = "PK\3\4update"
ok, err = LauncherMods.installZip("imports/mods/update-with-rom.zip",
  { replace = true, expectId = MOD_ID })
check(ok == true, "replace with a baserom succeeds (" .. tostring(err) .. ")")
eq(files["mods/" .. MOD_ID .. "/baseroms/stadium2.z64"], "user-owned-rom",
  "replace preserves user-owned baseroms under the canonical mod folder")
check(files["mods/OldFolder/baseroms/stadium2.z64"] == nil,
  "the shadow mod tree is still removed after preservation")

-- A preservation write failure keeps recovery bytes outside mods/, where
-- discovery cannot mistake a baseroms-only directory for an installed mod.
resetFs()
files["mods/OldFolder/manifest.json"] =
  ('{"id":"%s","name":"Old Copy","version":"0.9.0","entry":"main.lua"}')
    :format(MOD_ID)
files["mods/OldFolder/main.lua"] = "return function() end\n"
files["mods/OldFolder/baseroms/stadium2.z64"] = "user-owned-rom"
files["imports/mods/preserve-fail.zip"] = "PK\3\4update"
failWriteOnce = "mods/" .. MOD_ID .. "/baseroms/stadium2.z64"
ok, err = LauncherMods.installZip("imports/mods/preserve-fail.zip",
  { replace = true, expectId = MOD_ID })
check(not ok, "preservation failure rejects the update")
check(files["mods/" .. MOD_ID .. "/manifest.json"] == nil,
  "preservation failure leaves no manifest-less tree under mods")
eq(files["imports/baseroms-recovery/" .. MOD_ID .. "/stadium2.z64"],
  "user-owned-rom", "preservation failure stages recovery outside mods")

files["imports/mods/preserve-retry.zip"] = "PK\3\4update"
ok, err = LauncherMods.installZip("imports/mods/preserve-retry.zip",
  { replace = true, expectId = MOD_ID })
check(ok == true, "retry restores staged baseroms (" .. tostring(err) .. ")")
eq(files["mods/" .. MOD_ID .. "/baseroms/stadium2.z64"], "user-owned-rom",
  "retry restores the recovered baserom into the installed mod")
check(files["imports/baseroms-recovery/" .. MOD_ID .. "/stadium2.z64"] == nil,
  "successful retry clears baserom recovery debris")

-- #834: a manifest-less mods/<id> tree (interrupted copy debris) must not
-- block a plain re-import as "already installed"
resetFs()
files["mods/" .. MOD_ID .. "/gfx/a.bin"] = "x"
files["imports/mods/again.zip"] = "PK\3\4again"
ok, err = LauncherMods.installZip("imports/mods/again.zip")
check(ok == true, "debris tree does not block re-import ("
  .. tostring(err) .. ")")
check(files["mods/" .. MOD_ID .. "/gfx/a.bin"] == nil,
  "debris is cleared by the re-import")

-- a real installed copy still refuses a plain duplicate import
resetFs()
files["mods/" .. MOD_ID .. "/manifest.json"] = ARCHIVE[MOD_ID .. "/manifest.json"]
files["imports/mods/dup.zip"] = "PK\3\4dup"
ok, err = LauncherMods.installZip("imports/mods/dup.zip")
check(not ok, "a listed install still refuses a plain duplicate import")
check(tostring(err):find("already installed", 1, true),
  "duplicate refusal still names already installed")

-- Browser: a picked/dropped zip outside the save dir is streamed into a
-- save-dir temp in chunks and path-mounted, never read whole into Lua
do
  local savedWebHost = package.loaded["src.core.WebHost"]
  local web = true
  package.loaded["src.core.WebHost"] = { isWeb = function() return web end }
  vfs.newFileData = function(data, name)
    return { __filedata = true, data = data, name = name }
  end
  LauncherMods = freshMods()
  local saveDir = vfs.getSaveDirectory()
  os.execute("mkdir -p " .. saveDir .. " /tmp/pokeport-install-zip-host")
  local hostZip = "/tmp/pokeport-install-zip-host/picked.zip"
  local body = "PK\3\4" .. ("z"):rep(2 * 1024 * 1024 + 123)
  local fh = assert(io.open(hostZip, "wb"))
  fh:write(body)
  fh:close()
  local removed = {}
  local realRemove = vfs.remove
  vfs.remove = function(name)
    removed[#removed + 1] = name
    return realRemove(name)
  end
  local realMount = vfs.mount
  local stagedBytes
  vfs.mount = function(archive, point)
    if type(archive) == "string" then
      local sf = io.open(saveDir .. "/" .. archive, "rb")
      stagedBytes = sf and sf:read("*a")
      if sf then sf:close() end
    end
    return realMount(archive, point)
  end

  resetFs()
  local okW, errW = LauncherMods.installZip(hostZip)
  check(okW == true, "web host zip installs (" .. tostring(errW) .. ")")
  eq(fileDataMounts, 0, "web host zip is not copied into a FileData")
  eq(pathMounts, 1, "web host zip is path-mounted from the save dir")
  check(stagedBytes == body, "the staged copy is byte-identical across chunks")
  check(removed[1] and removed[1]:match("^mod_import_.*%.zip$"),
    "the staged temp is removed after the install")
  if removed[1] then os.remove(saveDir .. "/" .. removed[1]) end

  -- a big file inside the archive is copied out in chunks on the web
  local BIG = MOD_ID .. "/assets/big.bin"
  local bigBody = ("v"):rep(9 * 1024 * 1024 + 7)
  ARCHIVE[BIG] = bigBody
  local realGetInfo = vfs.getInfo
  vfs.getInfo = function(name, kind)
    local info = realGetInfo(name, kind)
    if info and info.type == "file" and arch[name] then info.size = #arch[name] end
    return info
  end
  local chunkReads, wholeReads = 0, 0
  local realRead = vfs.read
  vfs.read = function(name)
    if name:find("big.bin", 1, true) then wholeReads = wholeReads + 1 end
    return realRead(name)
  end
  vfs.newFile = function(name)
    local f, buf, pos = {}, {}, 1
    function f:open(mode) f.mode = mode return true end
    function f:read(n)
      local data = arch[name] or files[name] or ""
      if pos > #data then return nil end
      chunkReads = chunkReads + 1
      local c = data:sub(pos, pos + n - 1)
      pos = pos + n
      return c
    end
    function f:write(c) buf[#buf + 1] = c return true end
    function f:close() if f.mode == "w" then files[name] = table.concat(buf) end end
    return f
  end
  resetFs()
  okW, errW = LauncherMods.installZip(hostZip)
  check(okW == true, "web install with a big file succeeds (" .. tostring(errW) .. ")")
  check(files["mods/" .. MOD_ID .. "/assets/big.bin"] == bigBody,
    "the big file arrives byte-identical")
  check(chunkReads >= 9, "the big file is read in chunks (" .. chunkReads .. " reads)")
  eq(wholeReads, 0, "and never read whole")
  if removed[1] then os.remove(saveDir .. "/" .. removed[1]) end
  ARCHIVE[BIG] = nil
  vfs.getInfo, vfs.read, vfs.newFile = realGetInfo, realRead, nil
  removed = {}

  -- a DroppedFile-shaped source goes the same way
  resetFs()
  removed = {}
  local dropped = { getFilename = function() return hostZip end }
  okW, errW = LauncherMods.installZip(dropped)
  check(okW == true and pathMounts == 1 and fileDataMounts == 0,
    "a dropped file stages the same way (" .. tostring(errW) .. ")")
  if removed[1] then os.remove(saveDir .. "/" .. removed[1]) end

  -- a non-zip host file still gets the usual rejection
  local junk = "/tmp/pokeport-install-zip-host/junk.zip"
  fh = assert(io.open(junk, "wb"))
  fh:write("not a zip")
  fh:close()
  resetFs()
  okW, errW = LauncherMods.installZip(junk)
  check(not okW and tostring(errW):find("not a zip file", 1, true),
    "a non-zip host file is still rejected as not a zip")

  -- off the web the same host path keeps the in-memory mount
  web = false
  resetFs()
  okW = LauncherMods.installZip(hostZip)
  check(okW == true and fileDataMounts == 1 and pathMounts == 0,
    "desktop keeps the FileData mount for host zips")

  vfs.remove, vfs.mount = realRemove, realMount
  os.execute("rm -rf /tmp/pokeport-install-zip-host " .. saveDir)
  package.loaded["src.core.WebHost"] = savedWebHost
end

-- Restore
love.filesystem = savedFs
SaveData.portableBaseDir = savedSaveDataPortable
package.loaded["src.import.CacheFs"] = savedCacheFs
package.loaded["src.mods.LauncherMods"] = savedLauncherMods

S.finish()
