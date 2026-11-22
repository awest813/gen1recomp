-- Save editor review fixes: a save whose main file is gone (the game was
-- killed mid-write) opens from the game's recovery copy instead of a blank
-- stub, and the editor never writes over that copy; a save the game or a
-- sync changed since it was opened is noticed before Save replaces it;
-- backups never share a name; Release / Remove confirm the mon that was
-- armed, not whatever is selected by the second press.
--   luajit tests/engine/save_editor_review_fixes_test.lua
package.path = package.path .. ";./?.lua;./?/init.lua;./tools/save-editor/?.lua;./tools/save-editor/panels/?.lua"
love = require("tests.love_stub")
local T = require("tests.harness")
local SaveIO = require("SaveIO")
local SaveData = require("src.core.SaveData")

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local function write(path, text) local f = assert(io.open(path, "wb")) f:write(text) f:close() end
local function read(path) local f = io.open(path, "rb") if not f then return nil end local d = f:read("*a") f:close() return d end

-- ---- the game's recovery copy, as the game would load it
do
  local path = dir .. "/slot1.lua"
  write(path .. ".tmp", SaveData.encode({ player = { name = "RED" }, money = 1234 }))
  local save, err, recovered = SaveIO.load(path)
  T.check(save ~= nil, "a missing main file opens the game's staged copy: " .. tostring(err))
  T.eq(recovered, ".tmp", "and says which")
  T.eq(save and save.money, 1234, "with the real progress, not a stub")
  T.check(SaveIO.save(path, save), "saving it writes the main file")
  T.check(read(path .. ".tmp") ~= nil, "and leaves the game's copy alone")
  T.check(SaveIO.EDIT_TMP ~= ".tmp", "the editor stages under its own name")
end

-- ---- a file changed on disk since it was opened is noticed
do
  local path = dir .. "/slot2.lua"
  write(path, SaveData.encode({ player = { name = "BLUE" }, money = 1 }))
  local _, _, _, body = SaveIO.load(path)
  T.eq(SaveIO.changedOnDisk(path, body), false, "unchanged, it is not flagged")
  write(path, SaveData.encode({ player = { name = "BLUE" }, money = 999 }))
  T.eq(SaveIO.changedOnDisk(path, body), true, "written by the game since, it is")
end

-- ---- backups never share a name
do
  local path = dir .. "/slot3.lua"
  local a = SaveIO.backupPath(path)
  write(a, "first")
  local b = SaveIO.backupPath(path)
  T.check(a ~= b, "a second backup in the same second gets its own name")
end

-- ---- a confirm belongs to the mon it was armed for
do
  local Ops = require("Ops")
  local pidgey = { species = 16, level = 3 }
  local mewtwo = { species = 150, level = 70 }
  local S = { version = "red", save = { party = { pidgey, mewtwo }, player = {} },
    data = { pokemon = {} }, selectedParty = 1 }
  Ops.partyRemove(S)
  Ops.selectParty(S, 2)
  local removed = Ops.partyRemove(S)
  T.check(not removed, "selecting another mon does not confirm the first's Remove")
  T.eq(#S.save.party, 2, "nothing is removed")
  T.eq(S.save.party[2], mewtwo, "Mewtwo is still there")
end

os.execute("rm -rf '" .. dir .. "'")
T.finish("save editor review fixes")
