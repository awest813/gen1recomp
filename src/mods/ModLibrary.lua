-- The installed-mods library a front end needs: list what is installed,
-- turn a mod on or off for a game, install one from a .zip, uninstall one.
--
-- It honours exactly the contract src/mods/Loader.lua reads at boot:
--   * a mod is a folder under mods/ holding a manifest.json that
--     Manifest.validate accepts;
--   * whether it runs is SaveData.modEnabled(options, id, scope), where a
--     missing answer means on -- except for an experimental mod, which stays
--     off until the player opts in;
--   * which games it runs on is ModTargets.supports(manifest, version).
-- So whatever this module writes, the game reads the same way.
--
-- A .zip is installed by mounting it read-only, finding the folder that
-- holds manifest.json (the archive root or one level down), validating that
-- manifest, and copying the folder to mods/<id>/.  Nothing in the archive
-- runs during an install.

local Json = require("src.link.Json")
local Manifest = require("src.mods.Manifest")
local ModTargets = require("src.mods.ModTargets")
local GameVersion = require("src.core.GameVersion")
local Semver = require("src.mods.Semver")

local ModLibrary = {}

ModLibrary.ROOT = "mods"
ModLibrary.MAX_ZIP_BYTES = 512 * 1024 * 1024

local function fsys(fs) return fs or love.filesystem end

-- A portable install (portable.txt, src/import/CacheFs.lua) keeps mods in the
-- game folder, which love.filesystem can read (it is mounted) but never
-- write: writes and deletes go through CacheFs there (#330).  An injected
-- fs (tests) is used as given.
local function portable(custom)
  if custom then return nil end
  local ok, CacheFs = pcall(require, "src.import.CacheFs")
  if not ok then return nil end
  local okR, root = pcall(CacheFs.root)
  if okR and root then return CacheFs, root end
  return nil
end

local function sink(fs, custom)
  local CacheFs = portable(custom)
  if CacheFs then
    local function scoped(fn, ...)
      local saved = CacheFs.prefix
      CacheFs.prefix = ""
      local ok, a, b = pcall(fn, ...)
      CacheFs.prefix = saved
      if not ok then return false, a end
      return a, b
    end
    return {
      write = function(path, body) return scoped(CacheFs.write, path, body) end,
      mkdir = function() return true end,  -- CacheFs.write makes parents
      remove = function(path, isDir)
        return scoped(isDir and CacheFs.removeDir or CacheFs.remove, path)
      end,
    }
  end
  return {
    write = fs.write,
    mkdir = fs.createDirectory,
    remove = function(path) return fs.remove(path) end,
  }
end

-- Where installed mods live: the save directory, or a portable game folder.
-- Anything else (the game's own archive) is a built-in mod.
local function writableDir(fs, real, custom)
  if real == nil then return true end
  local saveDir = fs.getSaveDirectory and fs.getSaveDirectory()
  if real == saveDir then return true end
  local _, root = portable(custom)
  return root ~= nil and real == root
end

local function readManifest(fs, folder)
  local raw = fs.read(folder .. "/manifest.json")
  if type(raw) ~= "string" then return nil, "no manifest.json" end
  local data, decodeErr = Json.decode(raw)
  if type(data) ~= "table" then return nil, decodeErr or "manifest.json is not JSON" end
  local ok, manifest = pcall(Manifest.validate, data, folder)
  -- an assert message carries "file.lua:123: "; the player wants the reason
  if not ok then return nil, (tostring(manifest):gsub("^[^:]*%.lua:%d+: ", "")) end
  return manifest
end
ModLibrary.readManifest = readManifest

local function loadOptions()
  local okS, SaveData = pcall(require, "src.core.SaveData")
  if not okS then return {} end
  local ok, opts = pcall(SaveData.loadOptions)
  return (ok and type(opts) == "table") and opts or {}
end

-- Every installed mod, sorted by name, as rows the UI can show directly.
-- `version` (optional) fills in `supported` and `enabled` for that game.
function ModLibrary.list(version, fs)
  local custom = fs ~= nil
  fs = fsys(fs)
  local rows = {}
  if not (fs.getInfo and fs.getInfo(ModLibrary.ROOT)) then return rows end
  local okS, SaveData = pcall(require, "src.core.SaveData")
  local options = loadOptions()
  local scope = version and okS and SaveData.modScope(version) or nil
  for _, name in ipairs(fs.getDirectoryItems(ModLibrary.ROOT) or {}) do
    local folder = ModLibrary.ROOT .. "/" .. name
    local info = fs.getInfo(folder)
    -- like the loader, a folder without manifest.json is not a mod at all
    if info and (info.type == "directory" or info.type == "symlink")
        and fs.getInfo(folder .. "/manifest.json") then
      local manifest, err = readManifest(fs, folder)
      -- mods shipped inside the game folder are read-only: only the ones in
      -- the save directory can be uninstalled
      local real = fs.getRealDirectory and fs.getRealDirectory(folder)
      local row = { folder = folder, bundled = not writableDir(fs, real, custom) }
      if manifest then
        row.id = manifest.id
        row.name = manifest.name or manifest.id
        row.version = manifest.version
        row.author = manifest.author
        row.description = manifest.description
        row.experimental = manifest.experimental and true or false
        row.manifest = manifest
        if version then
          local okT, supported = pcall(ModTargets.supports, manifest, version,
            GameVersion.generation(version))
          row.supported = okT and supported and true or false
          local answer
          if okS then answer = SaveData.modEnabled(options, manifest.id, scope) end
          if answer == nil then answer = not row.experimental end
          row.enabled = answer
        end
      else
        row.id, row.name, row.broken = name, name, tostring(err)
      end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b)
    return tostring(a.name):lower() < tostring(b.name):lower()
  end)
  return rows
end

-- Turn a mod on or off for one game (or for every game when version is nil
-- on a build without per-game mod flags).
function ModLibrary.setEnabled(id, enabled, version)
  local SaveData = require("src.core.SaveData")
  local options = SaveData.loadOptions()
  SaveData.setModEnabled(options, id, enabled, SaveData.modScope(version))
  return SaveData.saveOptions(options)
end

local function copyTree(fs, out, from, to)
  out.mkdir(to)
  for _, name in ipairs(fs.getDirectoryItems(from) or {}) do
    local src, dst = from .. "/" .. name, to .. "/" .. name
    local info = fs.getInfo(src)
    if info and info.type == "directory" then
      copyTree(fs, out, src, dst)
    elseif info then
      local body = fs.read(src)
      if type(body) ~= "string" then error("could not read " .. src, 0) end
      local ok, err = out.write(dst, body)
      if not ok then error("could not write " .. dst .. ": " .. tostring(err), 0) end
    end
  end
end

local function removeTree(fs, path, out)
  out = out or sink(fs, true)
  local info = fs.getInfo(path)
  if not info then return end
  local isDir = info.type == "directory"
  if isDir then
    for _, name in ipairs(fs.getDirectoryItems(path) or {}) do
      removeTree(fs, path .. "/" .. name, out)
    end
  end
  out.remove(path, isDir)
end
ModLibrary._removeTree = removeTree

-- The folder inside a mounted archive that holds manifest.json: the archive
-- root, or its single top-level folder (how GitHub source zips are laid out).
local function findModRoot(fs, mount)
  if fs.getInfo(mount .. "/manifest.json") then return mount end
  for _, name in ipairs(fs.getDirectoryItems(mount) or {}) do
    local sub = mount .. "/" .. name
    local info = fs.getInfo(sub)
    if info and info.type == "directory" and fs.getInfo(sub .. "/manifest.json") then
      return sub
    end
  end
  return nil
end

-- Outside mods/ on purpose: a staged copy has a manifest.json, and anything
-- under mods/ with one is a mod to the loader and to list().
local STAGING = "mod_staging"
ModLibrary.STAGING = STAGING

-- Where the mod with this id is installed now: the folder whose manifest
-- names it (nil when none).  Second result: why the install must stop --
-- mods/<id> holds a different mod, or a folder differing only in letter
-- case would collide on a case-insensitive disk (Windows, macOS, Android
-- shared storage) and silently merge two mods.
local function findInstalled(fs, id)
  local found
  local wanted = ModLibrary.ROOT .. "/" .. id
  for _, name in ipairs(fs.getDirectoryItems(ModLibrary.ROOT) or {}) do
    local folder = ModLibrary.ROOT .. "/" .. name
    local have = fs.getInfo(folder .. "/manifest.json") and readManifest(fs, folder)
    if have and have.id == id then
      found = found or folder
    elseif name:lower() == id:lower() then
      if have then
        return nil, ("%s is taken by another mod (%s); uninstall it first")
          :format(folder, tostring(have.id))
      end
      if name ~= id then
        return nil, ("%s already exists and differs from %s only in letter case; "
          .. "remove or rename it first"):format(folder, id)
      end
    end
  end
  if not found and fs.getInfo(wanted) then
    -- a folder with a broken or missing manifest: replacing it is how a
    -- player repairs it, which the old behaviour allowed too
    return wanted
  end
  return found
end

-- Install a mod from .zip bytes.  Returns the manifest, or nil plus a reason.
-- An installed mod with the same id is replaced when opts.replace, or when
-- opts.upgrade and the archive's version is newer.
function ModLibrary.installZip(bytes, name, opts)
  opts = opts or {}
  local fs = fsys(opts.fs)
  local out = sink(fs, opts.fs ~= nil)
  if type(bytes) ~= "string" or bytes == "" then return nil, "the file was empty" end
  if #bytes > ModLibrary.MAX_ZIP_BYTES then return nil, "that .zip is too large" end
  if bytes:sub(1, 2) ~= "PK" then return nil, "that is not a .zip file" end
  local okD, data = pcall(fs.newFileData, bytes, name or "mod.zip")
  if not okD then return nil, "could not read the .zip: " .. tostring(data) end
  local mount = "__mod_install_" .. tostring(os.time())
  local okM, mounted = pcall(fs.mount, data, mount)
  if not okM or not mounted then return nil, "could not open the .zip" end
  local result, err
  local ok, failure = pcall(function()
    local root = findModRoot(fs, mount)
    if not root then err = "no manifest.json in that .zip" return end
    local manifest, merr = readManifest(fs, root)
    if not manifest then err = "invalid manifest.json: " .. tostring(merr) return end
    if not tostring(manifest.id):match("^[%w_%-%.]+$") then
      err = "the mod id is not a safe folder name" return
    end
    -- The loader finds a mod by the id in its manifest, not by its folder
    -- name, so the copy already installed may live elsewhere (a hand-unzipped
    -- "cool-mod-main"), and mods/<id> may hold some other mod entirely.
    local installed, clash = findInstalled(fs, manifest.id)
    if clash then
      err = clash
      return
    end
    local target = installed or (ModLibrary.ROOT .. "/" .. manifest.id)
    if installed then
      local replace = opts.replace
      if not replace and opts.upgrade then
        local have = readManifest(fs, installed)
        local order = have and Semver.compare(manifest.version, have.version)
        replace = have == nil or (order ~= nil and order > 0)
      end
      if not replace then
        err = manifest.id .. " is already installed"
        result = { exists = true, manifest = manifest }
        return
      end
      -- Stage the new copy first: a failed write (a full disk, a file the
      -- archive could not give back) must leave the old version working.
      local staging = STAGING .. "/" .. manifest.id
      removeTree(fs, staging, out)
      local okS, stageErr = pcall(copyTree, fs, out, root, staging)
      if not okS then
        removeTree(fs, staging, out)
        error(stageErr, 0)
      end
      removeTree(fs, target, out)
      local okC, copyErr = pcall(copyTree, fs, out, staging, target)
      removeTree(fs, staging, out)
      if not okC then
        removeTree(fs, target, out)
        error(tostring(copyErr) .. " (the old version was removed; install it again)", 0)
      end
      result = manifest
      return
    end
    out.mkdir(ModLibrary.ROOT)
    local okC, copyErr = pcall(copyTree, fs, out, root, target)
    if not okC then
      -- never leave half a mod behind for the loader to trip over
      removeTree(fs, target, out)
      error(copyErr, 0)
    end
    result = manifest
  end)
  pcall(fs.unmount, data)
  if not ok then return nil, tostring(failure) end
  if err then return nil, err, result end
  return result
end

function ModLibrary.uninstall(folder, fs)
  local custom = fs ~= nil
  fs = fsys(fs)
  -- exactly one folder directly under mods/: "mods/", "mods/x/sub" and any
  -- climb are refused, so a bad caller can never empty the whole library
  local name = type(folder) == "string"
    and folder:match("^" .. ModLibrary.ROOT .. "/([^/\\]+)$")
  if not name or name == "." or name == ".." then
    return false, "not an installed mod folder"
  end
  removeTree(fs, folder, sink(fs, custom))
  if portable(custom) then
    -- a copy an older build wrote to the OS save directory instead (#330)
    removeTree(fs, folder, sink(fs, true))
  end
  if fs.getInfo(folder) == nil then return true end
  -- a built-in mod of the same name still shows through; the player's copy
  -- is gone, which is what uninstalling it means
  local real = fs.getRealDirectory and fs.getRealDirectory(folder)
  if not writableDir(fs, real, custom) then return true end
  return false, "the mod's files could not all be removed"
end

-- Ids a manifest depends on that are not installed.  Dependencies come
-- parsed from Manifest.validate (dependencySpecs: "id@range#owner/repo"
-- already split into id and range); the raw list is the fallback.
function ModLibrary.missingDependencies(manifest, rows)
  local have = {}
  for _, row in ipairs(rows or {}) do have[row.id] = true end
  local missing = {}
  local specs = manifest and manifest.dependencySpecs
  if type(specs) ~= "table" then
    specs = {}
    for _, dep in ipairs(manifest and manifest.dependencies or {}) do
      local id = type(dep) == "table" and dep.id or tostring(dep):match("^([%w_%-]+)")
      specs[#specs + 1] = { id = id }
    end
  end
  for _, spec in ipairs(specs) do
    if type(spec.id) == "string" and not have[spec.id] then missing[#missing + 1] = spec.id end
  end
  return missing
end

-- ------------------------------------------------------------ save sync

-- Installed mods with each one's on/off answer for every game, the shape
-- src/sync/SyncMods.lua records: { id, version, manifest, enabledByVersion }.
function ModLibrary.syncRows(fs)
  local byId, order = {}, {}
  for _, version in ipairs(GameVersion.ORDER) do
    for _, row in ipairs(ModLibrary.list(version, fs)) do
      if not row.broken then
        local rec = byId[row.id]
        if not rec then
          rec = { id = row.id, version = row.version, manifest = row.manifest,
                  enabledByVersion = {} }
          byId[row.id] = rec
          order[#order + 1] = rec
        end
        rec.enabledByVersion[version] = row.supported and row.enabled or false
      end
    end
  end
  return order
end

-- Download and install a mod listed in a mod index (src/mods/ModIndex.lua).
-- Blocking: sync runs it from its own task list.
function ModLibrary.installFromIndex(entry)
  local url, why = require("src.mods.ModIndex").installUrl(entry)
  if not url then return nil, why end
  local okH, HostShell = pcall(require, "src.core.HostShell")
  if not (okH and HostShell.httpGet) then return nil, "no network transport here" end
  local body, err = HostShell.httpGet(url, nil, "application/zip", 300)
  if not body then return nil, err end
  local manifest, installErr = ModLibrary.installZip(body,
    tostring(entry and entry.id or "mod") .. ".zip", { upgrade = true })
  if not manifest then
    if tostring(installErr):find("already installed", 1, true) then return true end
    return nil, installErr
  end
  return true
end

-- Every mod's saved option answers (options.modOptions), and one mod's.
function ModLibrary.modOptions()
  local opts = loadOptions()
  return type(opts.modOptions) == "table" and opts.modOptions or {}
end

function ModLibrary.setModOptions(id, values)
  if type(id) ~= "string" or type(values) ~= "table" then return false, "bad options" end
  local SaveData = require("src.core.SaveData")
  local opts = SaveData.loadOptions()
  opts.modOptions = type(opts.modOptions) == "table" and opts.modOptions or {}
  local bucket = {}
  for key, value in pairs(values) do
    local kind = type(value)
    if type(key) == "string" and (kind == "string" or kind == "number" or kind == "boolean") then
      bucket[key] = value
    end
  end
  opts.modOptions[id] = bucket
  return SaveData.saveOptions(opts)
end

-- ---------------------------------------------------------- translations

ModLibrary.STRINGS_FILE = "lang/strings.lua"

-- A mod's lang/strings.lua run as data: no globals, so it can only build a
-- table.  Returns source -> translation, or nil.
local function readStrings(fs, folder)
  local text = fs.read(folder .. "/" .. ModLibrary.STRINGS_FILE)
  if type(text) ~= "string" then return nil end
  -- through Sandbox.compile, which refuses precompiled bytecode: LuaJIT
  -- runs it unverified, and an empty environment does not contain it
  local chunk = require("src.mods.Sandbox").compile(text,
    "=" .. folder .. "/" .. ModLibrary.STRINGS_FILE, {})
  if not chunk then return nil end
  local ok, map = pcall(chunk)
  if not ok or type(map) ~= "table" then return nil end
  local out = {}
  for source, target in pairs(map) do
    if type(source) == "string" and type(target) == "string" then out[source] = target end
  end
  return out
end

-- The launcher's string catalog before any game boots: the enabled mods'
-- lang/strings.lua merged, later mods (by id) winning a key.  The game's mod
-- loader replaces it with the real catalog once a version boots.  nil when
-- no enabled mod ships one.
function ModLibrary.translationStrings(version, fs)
  fs = fsys(fs)
  local okL, rows = pcall(ModLibrary.list, version, fs)
  if not okL then return nil end
  table.sort(rows, function(a, b) return tostring(a.id) < tostring(b.id) end)
  local merged, any = {}, false
  for _, row in ipairs(rows) do
    local on = row.enabled
    if on == nil then on = not row.experimental end
    if not row.broken and on then
      local map = readStrings(fs, row.folder)
      for source, target in pairs(map or {}) do
        merged[source] = target
        any = true
      end
    end
  end
  return any and merged or nil
end

return ModLibrary
