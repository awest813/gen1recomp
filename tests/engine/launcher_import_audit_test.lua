-- ROM loading, the launcher audit: an automatic re-import tries each game
-- once (a remembered file that now holds another game looped forever); a
-- file whose game changed is refused; a drop of a game already imported
-- selects it instead of wiping it; a drop during an import says the file
-- was not taken and forgets its path; an import started from Settings
-- shows the game panel; and Gold shares the launcher's volume.
--   luajit tests/engine/launcher_import_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end

local T = require("tests.harness")
local check, eq = T.check, T.eq

local ready = { gold = true }
local opts = {}
package.loaded["src.core.SaveData"] = {
  listSlots = function() return {} end, activeSlot = function() return nil end,
  loadOptions = function() return opts end,
  saveOptions = function(o) if o ~= opts then for k, v in pairs(o) do opts[k] = v end end return true end,
}
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(v) return ready[v] == true end,
  isImported = function(v) return ready[v] == true end,
  readMarker = function(v) return v == "yellow" and "old-format" or nil end,
}, { __index = require("src.import.CacheContract") })

-- bytes "ROM:<version>" verify as that game
local ImportJob = require("src.import.ImportJob")
ImportJob.interrupted = function() return false end
ImportJob.verify = function(data)
  local v = tostring(data):match("^ROM:(%a+)$")
  if v then return { version = v } end
  return nil, "That file is not a ROM."
end
local starts = {}
local finish = true
ImportJob.start = function(rom)
  starts[#starts + 1] = rom.version
  return { state = "working", version = rom.version, progress = 0.1,
    step = function(j)
      if not finish then return j.state end
      j.state = "done"; ready[rom.version] = true
      return "done"
    end }
end
local files = {}
package.loaded["src.core.FilePicker"] = setmetatable({
  read = function(path) return files[path], files[path] == nil and "gone" or nil end,
  basename = function(p) return (p:match("[^/]+$")) end,
}, { __index = require("src.core.FilePicker") })

local Launcher = require("src.launcher.Launcher")

-- ---- a stale game whose remembered file now holds another game
do
  opts.autoReimport = true
  -- a real file: the launcher looks for it on disk before trying it
  local path = os.tmpname()
  local f = assert(io.open(path, "wb")); f:write("ROM:gold"); f:close()
  opts.romSources = { yellow = path }
  files[path] = "ROM:gold" -- overwritten with Gold
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  check(l.stale and l.stale.yellow, "Yellow needs an update")
  for _ = 1, 20 do l:update(1 / 60) end
  eq(#starts, 0, "the file is not imported in Yellow's place")
  check(l.message and l.message.text:find("no longer holds", 1, true), "and the player is told why")
  -- one try a session: no loop, and no message repeated every frame
  l.message = nil
  l:autoReimport()
  eq(l.message, nil, "Yellow is not tried again this session")
  opts.autoReimport, opts.romSources = nil, nil
  os.remove(path)
end

-- ---- a drop of a game already imported selects it; force imports again
do
  starts = {}
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  l.page = "settings"
  l:importData("ROM:gold", "gold.gbc")
  eq(#starts, 0, "a ready Gold is not wiped by a second drop")
  eq(l.selected, "gold", "it is selected")
  eq(l.page, nil, "with its panel on screen")
  check(l.message and l.message.text:find("already imported", 1, true), "and says it is already there")
  l:importData("ROM:gold", "gold.gbc", true)
  eq(starts[1], "gold", "Import ROM again still imports it")
  l:update(1 / 60)
end

-- ---- an import started from Settings shows the game; a drop mid-import
do
  starts, finish = {}, false
  ready.yellow = nil
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  l.page = "settings"
  l:importData("ROM:yellow", "yellow.gb")
  eq(l.page, nil, "the import's progress is on screen, not hidden behind Settings")
  l.pickedRomPath = "/roms/firered.gba"
  l:importData("ROM:firered", "firered.gba")
  check(l.message and l.message.text:find("firered.gba was not imported", 1, true),
    "a second file says it was not taken")
  eq(l.pickedRomPath, nil, "and its path is not left for the next import")
  finish = true
end

-- ---- Gold reads the launcher's volume
do
  local Gen2Save = require("src.core.gen2.Save")
  opts.musicVol, opts.sfxVol = 3, 2
  opts.gold = { musicVol = 7 }
  local o = Gen2Save.loadOptions()
  eq(o.musicVol, 3, "Gold plays at the shared music volume")
  eq(o.sfxVol, 2, "and sound volume")
  o.musicVol = 5
  Gen2Save.saveOptions(o)
  eq(opts.musicVol, 5, "a change in Gold's OPTION reaches the other games")
end

T.finish("launcher import audit")
