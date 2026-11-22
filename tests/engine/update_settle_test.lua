-- A chainloaded update counts as good only after it has run a while or quit
-- cleanly; an error before that sets it aside, so the next launch starts the
-- built-in version instead of failing again.  --skip-updates starts it too.
--   luajit tests/engine/update_settle_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local Boot = require("src.update.Boot")

local files = {}
local realFs = love.filesystem
love.filesystem = setmetatable({
  read = function(p) return files[p] end,
  write = function(p, d) files[p] = d return true end,
  append = function(p, d) files[p] = (files[p] or "") .. d return true end,
  remove = function(p) files[p] = nil return true end,
  getInfo = function(p) return files[p] and { type = "file" } or nil end,
  createDirectory = function() return true end,
}, { __index = realFs })

local PENDING = "updates/pending.txt"
local function start(name)
  files[PENDING] = name
  local updates, handled = 0, nil
  love.update = function() updates = updates + 1 end
  love.quit = nil
  love.errorhandler = function(msg) handled = msg return function() end end
  Boot.settle(name)
  return function() return updates, handled end
end

-- runs long enough: good
local probe = start("gen1recomp-2.0.0.love")
for _ = 1, 5 do love.update(1) end
T.check(files[PENDING] ~= nil, "five seconds in, the update is still on probation")
for _ = 1, 6 do love.update(1) end
T.eq(files[PENDING], nil, "after the settle time it counts as good")
T.eq((probe()), 11, "and the game's own update kept running throughout")

-- a clean quit early: good too
start("gen1recomp-2.0.1.love")
love.update(1)
love.quit()
T.eq(files[PENDING], nil, "a clean quit before the settle time counts as good")

-- an error while running: set aside
local probe2 = start("gen1recomp-2.0.2.love")
love.update(1)
love.errorhandler("boom")
T.check(Boot.isBad("gen1recomp-2.0.2.love"), "an error after starting marks the update bad")
T.eq(files[PENDING], nil, "and clears the marker")
T.eq(select(2, probe2()), "boom", "the game's error screen still shows the error")

T.check(Boot.skipRequested({ "--skip-updates" }), "--skip-updates starts the built-in version")
T.check(not Boot.skipRequested({}), "without it, updates load")

love.filesystem = realFs
T.finish("update settle")
