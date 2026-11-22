-- A link battle peer's actions are taken only as the menu could have made
-- them: no move without PP, not the Disabled slot, Struggle only with
-- nothing else left (src/link/LinkBattle.lua decodeWireAction).
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local LinkBattle = require("src.link.LinkBattle")
local decode = LinkBattle._decodeWireAction

local function battler(pps, disabled)
  local moves = {}
  for i, pp in ipairs(pps) do moves[i] = { id = "MOVE" .. i, pp = pp } end
  return { curMoves = moves, disabledSlot = disabled }
end

local b = battler({ 10, 0, 5 }, 3)
T.eq(decode({}, { kind = "move", slot = 1 }, b).id, "MOVE1", "a usable move runs")
T.eq(decode({}, { kind = "move", slot = 2 }, b), nil, "a move with no PP does not")
T.eq(decode({}, { kind = "move", slot = 3 }, b), nil, "nor the Disabled one")
T.eq(decode({}, { kind = "struggle" }, b), nil, "Struggle with a move left is refused")
local spent = battler({ 0, 0 })
T.check(decode({}, { kind = "struggle" }, spent).struggle, "Struggle with nothing left runs")
T.check(decode({}, { kind = "move", slot = 1 }, spent).struggle, "and a spent move becomes Struggle")
T.finish("link peer actions")
