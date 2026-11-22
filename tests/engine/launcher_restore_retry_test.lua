-- A failed import whose old copy could not be put back (a rename refused)
-- leaves that copy set aside.  The launcher tries again by itself in the
-- same session, waiting longer each time; the game's page says so and has
-- a "Put it back" button; and an automatic re-import leaves it alone.
--   luajit tests/engine/launcher_restore_retry_test.lua
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
  defaultOptions = function() return { musicVol = 7, sfxVol = 7 } end,
  saveOptions = function(o) if o ~= opts then for k, v in pairs(o) do opts[k] = v end end return true end,
}
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(v) return ready[v] == true end,
  isImported = function(v) return ready[v] == true end,
  readMarker = function() return nil end,
}, { __index = require("src.import.CacheContract") })

-- a copy of Yellow is set aside; `blocked` says whether putting it back works
local waiting, blocked, tries = {}, true, 0
local ImportJob = require("src.import.ImportJob")
ImportJob.interrupted = function() return false end
ImportJob.backupWaiting = function(v) return waiting[v] == true end
ImportJob.recover = function(v)
  if not waiting[v] then return false end
  tries = tries + 1
  if blocked then return false end
  waiting[v], ready[v] = nil, true
  return true
end
local starts = {}
ImportJob.start = function(rom)
  starts[#starts + 1] = rom.version
  return { state = "working", version = rom.version, step = function(j) return j.state end }
end

local Launcher = require("src.launcher.Launcher")

local function failedJob(l, version)
  waiting[version] = true
  l.job = { state = "error", version = version, restored = false,
    error = "The disk is full.", detail = "disk full",
    step = function() return "error" end }
  l:update(1 / 60)
end

local function run(l, seconds)
  local steps = math.floor(seconds * 10)
  for _ = 1, steps do l:update(0.1) end
end

-- ---- the failure says the copy is kept, and the launcher keeps trying
do
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  tries = 0
  failedJob(l, "yellow")
  check(l.message and l.message.text:find("will keep trying", 1, true),
    "the failure says the old copy is kept and will be put back")
  eq(l.stale.yellow, "waiting", "the game reads as a copy set aside")
  run(l, 1)
  eq(tries, 0, "no retry straight away")
  run(l, 1.5)
  eq(tries, 1, "a first retry after a short wait")
  run(l, 5)
  eq(tries, 2, "a second after a longer one")
  blocked = false
  run(l, 15)
  eq(tries, 3, "a third, which works")
  check(l.ready.yellow, "Yellow is ready again in the same session")
  check(l.message and l.message.text:find("is back, ready to play", 1, true), "and the player is told")
  eq(l.restoreRetry, nil, "no more retries")
  blocked = true
end

-- ---- retries stop after the last wait (the button and the next start remain)
do
  ready.yellow = nil
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  tries = 0
  failedJob(l, "yellow")
  run(l, 2 + 5 + 15 + 30 + 60 + 5)
  eq(tries, #Launcher.RESTORE_WAITS, "one try per wait")
  eq(l.restoreRetry, nil, "then it stops")
  run(l, 120)
  eq(tries, #Launcher.RESTORE_WAITS, "and stays stopped")

  -- the page's button tries at once, and says when it cannot
  l.message = nil
  l:restorePrevious("yellow", true)
  eq(tries, #Launcher.RESTORE_WAITS + 1, "Put it back tries now")
  check(l.message and l.message.text:find("Could not put", 1, true), "and says it could not yet")
  blocked = false
  check(l:restorePrevious("yellow", true), "a later press works")
  check(l.ready.yellow, "and the game is ready")
  blocked = true
end

-- ---- an automatic re-import does not import over a copy set aside
do
  ready.yellow = nil
  waiting.yellow = true
  opts.autoReimport = true
  local path = os.tmpname()
  local f = assert(io.open(path, "wb")); f:write("ROM:yellow"); f:close()
  opts.romSources = { yellow = path }
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  starts = {}
  eq(l.stale.yellow, "waiting", "the set-aside copy is seen at start")
  l:autoReimport()
  eq(#starts, 0, "and is not imported over")
  opts.autoReimport, opts.romSources = nil, nil
  os.remove(path)
  waiting.yellow = nil
end

-- ---- the game's page shows the notice and its button, and draws cleanly
do
  ready.yellow = nil
  waiting.yellow = true
  local Kit = require("src.ui.kit.Kit")
  love.graphics.getDimensions = function() return 1280, 720 end
  love.graphics.getPixelDimensions = function() return 1280, 720 end
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  l:selectGame("yellow")
  local ok, err = true, nil
  for _ = 1, 6 do
    ok, err = pcall(l.draw, l)
    if not ok then break end
    l:update(1 / 60)
  end
  check(ok, "the page draws (" .. tostring(err) .. ")")
  local found = false
  for i = 1, Kit._navPrevN or 0 do
    if Kit._nav[i] and Kit._nav[i].id == "restore-previous" then found = true end
  end
  check(found, "with a Put it back button")
  waiting.yellow = nil
end

T.finish("launcher restore retry")
