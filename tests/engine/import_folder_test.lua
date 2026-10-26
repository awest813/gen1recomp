-- Import folders for hosts with no file picker (src/launcher/Inbox.lua and
-- Launcher:scanInbox): Switch and PS4 players copy files over FTP/MTP.
-- No pokered cite: port-only launcher plumbing.
--   luajit tests/engine/import_folder_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end

local T = require("tests.harness")
local check, eq = T.check, T.eq

local disk = {}
local fs = {}
local function parent(p) return p:match("^(.*)/[^/]+$") or "" end
function fs.getInfo(p)
  if disk[p] then return { type = "file" } end
  for k in pairs(disk) do if k:sub(1, #p + 1) == p .. "/" then return { type = "directory" } end end
  return nil
end
function fs.getDirectoryItems(p)
  local out, seen = {}, {}
  for k in pairs(disk) do
    if k:sub(1, #p + 1) == p .. "/" then
      local child = k:sub(#p + 2):match("^[^/]+")
      if not seen[child] then seen[child] = true out[#out + 1] = child end
    end
  end
  return out
end
function fs.read(p) return disk[p] end
function fs.remove(p) disk[p] = nil return true end
function fs.createDirectory() return true end
function fs.getSaveDirectory() return "/save" end
local realFs = love.filesystem
love.filesystem = setmetatable(fs, { __index = realFs })

package.loaded["src.core.SaveData"] = {
  listSlots = function() return {} end, activeSlot = function() return nil end,
  loadOptions = function() return {} end, saveOptions = function() return true end,
}
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(v) return v == "gold" end,
  isImported = function(v) return v == "gold" end,
}, { __index = require("src.import.CacheContract") })
package.loaded["src.core.Platform"] = setmetatable({ inboxTransfer = function() return true end },
  { __index = require("src.core.Platform") })

local Inbox = require("src.launcher.Inbox")
check(Inbox.enabled(), "the import folders are on where the platform has no picker")
disk["imports/red.gb"] = "ROM"
disk["imports/notes.txt"] = "x"
disk["imports/mods/cool.zip"] = "PK"
disk["imports/carts/hard.g1rcart"] = "CART"
disk["imports/saves/gold/mine.sav"] = "SAVE"
disk["imports/baseroms/stadium.z64"] = "N64"
local kinds = {}
for _, item in ipairs(Inbox.scan()) do kinds[item.kind] = (kinds[item.kind] or 0) + 1 end
eq(kinds.rom, 1, "a ROM in imports/ is found (and a stray .txt is not)")
eq(kinds.mod, 1, "a mod in imports/mods/")
eq(kinds.cart, 1, "a cart in imports/carts/")
eq(kinds.save, 1, "a save in imports/saves/<game>/")
eq(kinds.modfile, 1, "a mod's file in imports/baseroms/")
eq(Inbox.location(), "/save/imports/", "the folder is named for an FTP/MTP client")

local Launcher = require("src.launcher.Launcher")
local l = Launcher.new(function() end, { noUpdateCheck = true })
local got = {}
l.importData = function(self, data, name) got.rom = name; self.job = { state = "working" } end
l.installMod = function(_, data, name) got.mod = name return true end
l.installCart = function(_, data, name) got.cart = name return false end
l.importSave = function(self, path, name) got.save = path; got.saveFor = self.selected return true end
l.storeInboxModFile = function(_, data) got.modfile = data return true end
l:update(0)  -- the first scan is queued at start
eq(got.rom, "red.gb", "the ROM is imported")
eq(got.mod, "cool.zip", "the mod is installed")
eq(got.save, "/save/imports/saves/gold/mine.sav", "the save is imported by its path")
eq(got.saveFor, "gold", "into its own game")
eq(got.modfile, "N64", "the mod file is offered to the mods")
eq(disk["imports/mods/cool.zip"], nil, "an imported file is removed")
eq(disk["imports/saves/gold/mine.sav"], nil, "saves too")
eq(disk["imports/carts/hard.g1rcart"], "CART", "a file that failed stays for the player to see")
local before = got.cart
got.cart = nil
l:scanInbox()
eq(got.cart, nil, "and is not retried on every scan")
l.inboxTried = {}
l:scanInbox()
eq(got.cart, "hard.g1rcart", "until Scan again")
check(before == "hard.g1rcart", "it was tried once at first")

love.filesystem = realFs
T.finish("import folder")
