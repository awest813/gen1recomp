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

local ModLibrary = {}

ModLibrary.ROOT = "mods"
ModLibrary.MAX_ZIP_BYTES = 512 * 1024 * 1024

local function fsys(fs) return fs or love.filesystem end

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
      local saveDir = fs.getSaveDirectory and fs.getSaveDirectory()
      local row = { folder = folder, bundled = real ~= nil and saveDir ~= nil and real ~= saveDir }
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

local function copyTree(fs, from, to)
  fs.createDirectory(to)
  for _, name in ipairs(fs.getDirectoryItems(from) or {}) do
    local src, dst = from .. "/" .. name, to .. "/" .. name
    local info = fs.getInfo(src)
    if info and info.type == "directory" then
      copyTree(fs, src, dst)
    elseif info then
      local body = fs.read(src)
      if type(body) ~= "string" then error("could not read " .. src, 0) end
      local ok, err = fs.write(dst, body)
      if not ok then error("could not write " .. dst .. ": " .. tostring(err), 0) end
    end
  end
end

local function removeTree(fs, path)
  local info = fs.getInfo(path)
  if not info then return end
  if info.type == "directory" then
    for _, name in ipairs(fs.getDirectoryItems(path) or {}) do
      removeTree(fs, path .. "/" .. name)
    end
  end
  fs.remove(path)
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

-- Install a mod from .zip bytes.  Returns the manifest, or nil plus a reason.
-- An installed mod with the same id is replaced only when opts.replace.
function ModLibrary.installZip(bytes, name, opts)
  opts = opts or {}
  local fs = fsys(opts.fs)
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
    local target = ModLibrary.ROOT .. "/" .. manifest.id
    if fs.getInfo(target) then
      if not opts.replace then
        err = manifest.id .. " is already installed"
        result = { exists = true, manifest = manifest }
        return
      end
      removeTree(fs, target)
    end
    fs.createDirectory(ModLibrary.ROOT)
    copyTree(fs, root, target)
    result = manifest
  end)
  pcall(fs.unmount, data)
  if not ok then return nil, tostring(failure) end
  if err then return nil, err, result end
  return result
end

function ModLibrary.uninstall(folder, fs)
  fs = fsys(fs)
  if type(folder) ~= "string" or folder:sub(1, #ModLibrary.ROOT + 1)
      ~= ModLibrary.ROOT .. "/" or folder:find("..", 1, true) then
    return false, "not an installed mod folder"
  end
  removeTree(fs, folder)
  return fs.getInfo(folder) == nil
end

-- Ids a manifest depends on that are not installed.
function ModLibrary.missingDependencies(manifest, rows)
  local have = {}
  for _, row in ipairs(rows or {}) do have[row.id] = true end
  local missing = {}
  for _, dep in ipairs(manifest and manifest.dependencies or {}) do
    local id = type(dep) == "table" and dep.id or dep
    if type(id) == "string" and not have[id] then missing[#missing + 1] = id end
  end
  return missing
end

return ModLibrary
