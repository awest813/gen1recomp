-- pokeemerald/src/field_player_avatar.c:608 PlayerNotOnBikeMoving,
-- :1011 PlayerNotOnBikeCollide, :1115 PlayCollisionSoundIfNotFacingWarp
-- pokeemerald/src/event_object_movement.c MovementAction_WalkInPlaceSlow_Step0
--
-- Walking into anything on foot plays SE_WALL_HIT and walks in place for the
-- 32-frame slow action; while the key stays held the collide repeats once the
-- action ends.  Gen 3 had no on-foot bump at all: the avatar just stood still
-- in silence (#2787).  The bike already had its own collide (bike/rse.lua).

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

require("src.core.GameVersion").set("emerald")

local played = {}
package.loaded["src.core.game3.audio"] = {
  playSe = function(id) played[#played + 1] = id end,
}
package.loaded["src.core.game3.trainer_sight"] = { check = function() return false end }

local SE = require("src.core.game3.se_ids")
local Collision = require("src.core.game3.collision")
local Player = require("src.core.game3.player")

local game = { data = {}, session = { version = "emerald", flags = {}, vars = {}, party = {} } }

-- a map with nothing enterable: every step is refused with `refuse`
local refuse = "tile"
Collision.canEnter = function() return false, refuse end
Collision.tryConnection = function() return false end
Collision.ledgeLanding = function() return nil end
local behaviors, arrow = {}, {}
Collision.behavior = function(x, y) return behaviors[x .. "," .. y] end
Collision.arrowWarpDir = function(beh) return arrow[beh] end
Collision.isWarpDoor = function(beh) return beh == "WARP_DOOR" end
for _, fn in ipairs({ "isStairWarp", "isDoorWarp", "isExitWarp", "isEscalatorWarp",
                      "isArrowWarp", "isSurfDismount" }) do
  Collision[fn] = function() return false end
end

local held = nil
local input = {
  isDown = function(_, b) return b == held end,
  wasPressed = function() return false end,
}

local function fresh(facing)
  Player.reset(5, 5, facing)
  Player.turnArmed = false
  Player.action = nil
  Player.walkInPlace = false
  Player.walkInPlaceFast = false
  played = {}
  behaviors = {}
end

-- === a wall to the right ===
fresh("right")
held = "right"
Player.update(game, input)
eq(#played, 1, "the first push into the wall plays one SE")
eq(played[1], SE.SE_WALL_HIT, "and it is SE_WALL_HIT")
eq(Player.moving, false, "a bump never starts a step")
eq(Player.cellX, 5, "the player stays on the cell")
eq(Player.facing, "right", "facing the wall")
check(Player.walkInPlace, "the refusal armed the in-place walk")
check(Player.action and Player.action.frames == 32,
      "MOVEMENT_ACTION_WALK_IN_PLACE_SLOW: 32 frames")
eq(Player.walkInPlaceFast, false, "at the walking (not running) animation rate")

-- hold the key: the action runs out its 32 frames before the next collide
local poses, flipAt = {}, nil
local flip0 = Player.drawFlip()
for f = 1, 31 do
  Player.update(game, input)
  poses[Player.walkPhase()] = true
  if not flipAt and Player.drawFlip() ~= flip0 then flipAt = f end
end
eq(#played, 1, "no second bump while the walk-in-place action is running")
check(Player.action ~= nil, "the action is still live on its 31st frame")
check(poses[0] and poses[1], "the legs cycle in place while held into the wall")
eq(flipAt, 16, "the other leg takes over after one 16-frame walk cycle")
Player.update(game, input)
eq(#played, 2, "frame 32 ends the action and the held key collides again")
check(Player.action and Player.action.frames == 32, "a fresh 32-frame walk-in-place")
eq(Player.cellX, 5, "still on the cell")

-- release: the running action finishes on its own, nothing new starts
held = nil
for _ = 1, 40 do Player.update(game, input) end
eq(#played, 2, "no bump without a direction held")
eq(Player.action, nil, "the action ran out")
eq(Player.walkInPlace, false, "and the avatar stands still")

-- === map edge with no connection and a blocking NPC bump the same way ===
for _, why in ipairs({ "bounds", "entity", "elevation", "water" }) do
  fresh("left")
  refuse = why
  held = "left"
  Player.update(game, input)
  eq(#played, 1, why .. ": SE_WALL_HIT")
  check(Player.walkInPlace, why .. ": walk in place")
end
refuse = "tile"

-- === PlayCollisionSoundIfNotFacingWarp exceptions ===
-- standing on an arrow warp that points the way pushed: silent, but the
-- avatar still walks in place
fresh("down")
behaviors["5,5"] = "ARROW_DOWN"
arrow.ARROW_DOWN = "down"
held = "down"
Player.update(game, input)
eq(#played, 0, "on a matching arrow warp the push is silent")
check(Player.walkInPlace, "but still walks in place")

-- an arrow warp pointing elsewhere does not exempt the push
fresh("up")
behaviors["5,5"] = "ARROW_DOWN"
held = "up"
Player.update(game, input)
eq(#played, 1, "an arrow warp facing another way still bumps")

-- pushing up into a warp door (the door animation's job): silent
fresh("up")
behaviors["5,4"] = "WARP_DOOR"
held = "up"
Player.update(game, input)
eq(#played, 0, "pushing up into a warp door is silent")
check(Player.walkInPlace, "and walks in place")

-- the door exemption is DIR_NORTH only
fresh("left")
behaviors["4,5"] = "WARP_DOOR"
held = "left"
Player.update(game, input)
eq(#played, 1, "a warp door to the side is an ordinary wall")

-- === a turn is not a bump ===
fresh("down")
Player.turnArmed = true
held = "right"
Player.update(game, input)
eq(#played, 0, "turning to face the wall first makes no sound")
eq(Player.facing, "right", "the avatar turned")

T.finish("game3_foot_bump_bug2787")
