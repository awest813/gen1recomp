-- Import folders for hosts with no file picker (Switch, PS4: files arrive
-- over FTP/MTP), docs/switch-transfer.md and docs/ps4-install.md:
--   imports/                 a ROM (.gb .gbc .gba, or a .zip/.7z holding one)
--   imports/mods/            mod .zip files
--   imports/carts/           custom carts (.g1rcart)
--   imports/saves/<game>/    battery saves for that game
--   imports/baseroms/        files a mod asked for (required_imports)
-- scan() lists what is waiting; the launcher imports each and removes the
-- ones it took (Inbox.take).

local GameVersion = require("src.core.GameVersion")

local Inbox = {}

Inbox.ROOT = "imports"

local ROM_EXTS = { gb = true, gbc = true, gba = true, zip = true, ["7z"] = true }
local SAVE_EXTS = { sav = true, srm = true, sa1 = true, dsv = true, sgm = true }

function Inbox.enabled()
  if os.getenv("POKEPORT_INBOX") == "1" then return true end
  local ok, Platform = pcall(require, "src.core.Platform")
  return ok and Platform.inboxTransfer and Platform.inboxTransfer() and true or false
end

local function ext(name) return tostring(name):lower():match("%.([%w]+)$") end

local function files(fs, dir)
  local out = {}
  if not (fs.getInfo and fs.getInfo(dir)) then return out end
  for _, name in ipairs(fs.getDirectoryItems(dir) or {}) do
    local info = fs.getInfo(dir .. "/" .. name)
    if info and info.type == "file" and name:sub(1, 1) ~= "." then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- Everything waiting, as { kind = "rom"|"mod"|"cart"|"save"|"modfile",
-- path = save-dir relative path, name, version (saves only) }.
function Inbox.scan(fs)
  fs = fs or love.filesystem
  local out = {}
  local root = Inbox.ROOT
  for _, name in ipairs(files(fs, root)) do
    local e = ext(name)
    if e == "g1rcart" then
      out[#out + 1] = { kind = "cart", path = root .. "/" .. name, name = name }
    elseif ROM_EXTS[e] then
      out[#out + 1] = { kind = "rom", path = root .. "/" .. name, name = name }
    end
  end
  for _, name in ipairs(files(fs, root .. "/mods")) do
    if ext(name) == "zip" then
      out[#out + 1] = { kind = "mod", path = root .. "/mods/" .. name, name = name }
    end
  end
  for _, name in ipairs(files(fs, root .. "/carts")) do
    if ext(name) == "g1rcart" then
      out[#out + 1] = { kind = "cart", path = root .. "/carts/" .. name, name = name }
    end
  end
  for _, version in ipairs(GameVersion.ORDER) do
    local dir = root .. "/saves/" .. version
    for _, name in ipairs(files(fs, dir)) do
      if SAVE_EXTS[ext(name)] then
        out[#out + 1] = { kind = "save", path = dir .. "/" .. name, name = name, version = version }
      end
    end
  end
  for _, name in ipairs(files(fs, root .. "/baseroms")) do
    out[#out + 1] = { kind = "modfile", path = root .. "/baseroms/" .. name, name = name }
  end
  return out
end

-- Make every inbox folder, so a player browsing over FTP/MTP finds them.
function Inbox.prepare(fs)
  fs = fs or love.filesystem
  if not fs.createDirectory then return end
  for _, dir in ipairs({ "", "/mods", "/carts", "/baseroms", "/saves" }) do
    pcall(fs.createDirectory, Inbox.ROOT .. dir)
  end
  for _, version in ipairs(GameVersion.ORDER) do
    pcall(fs.createDirectory, Inbox.ROOT .. "/saves/" .. version)
  end
end

function Inbox.take(item, fs)
  fs = fs or love.filesystem
  pcall(fs.remove, item.path)
end

-- Where the folder is, for the player to type into an FTP/MTP client.
function Inbox.location(fs)
  fs = fs or love.filesystem
  local base = fs.getSaveDirectory and fs.getSaveDirectory() or ""
  return (base ~= "" and (base .. "/") or "") .. Inbox.ROOT .. "/"
end

return Inbox
