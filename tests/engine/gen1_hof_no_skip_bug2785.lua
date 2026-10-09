-- engine/movie/hall_of_fame.asm AnimateHallOfFame:52-70, HoFShowMonOrPlayer
-- .ScrollPic, HoFDisplayPlayerStats / HoFPrintTextAndDelay
--
-- The induction is a DelayFrames program end to end: nothing between
-- PlayMusic and HoFFadeOutScreenAndMusic reads the joypad.  The port let A
-- cut the 80-frame info hold, the 180-frame HALL OF FAME banner, the fade and
-- the 120-frame stats hold short, so mashing A rushed the whole showcase and
-- the dex-rating texts before the credits (#2785).

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local HallOfFame = require("src.ui.HallOfFame")

local PIC_X = 12 * 8

local function run(holdA)
  local stack = { states = {} }
  function stack:push(s) self.states[#self.states + 1] = s; if s.enter then s:enter() end end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  local input = {
    wasPressed = function(_, b) return holdA and (b == "a" or b == "b") or false end,
    isDown = function(_, b) return holdA and (b == "a" or b == "b") or false end,
  }
  local game = {
    data = { pokemon = { CHARIZARD = { name = "CHARIZARD", types = { "FIRE", "FLYING" } } } },
    save = { party = { { species = "CHARIZARD", level = 81 } },
             pokedex = { seen = {}, owned = {} }, player = { name = "RED" },
             money = 0, playTime = 0 },
    input = input, stack = stack,
  }
  local hof = HallOfFame.new(game, function() end)
  -- HoFDisplayPlayerStats' PrintText chain is TextBox territory; the timed
  -- phases before it are what this suite measures
  local reachedDex = false
  hof.showDexTexts = function(self) reachedDex = true; self.phase = "player_dex" end
  stack:push(hof)

  local spent, order = {}, {}
  local function key()
    local k = hof.phase
    if k == "mons" then
      if hof.scrollX < PIC_X then k = "mons_scroll"
      elseif hof.showHofBanner then k = "mons_banner"
      else k = "mons_info" end
    elseif k == "back" then
      k = "back_" .. tostring(hof.afterBack)
    end
    return k
  end
  for _ = 1, 3000 do
    if reachedDex then break end
    local k = key()
    if not spent[k] then spent[k] = 0; order[#order + 1] = k end
    spent[k] = spent[k] + 1
    hof:update(1 / 60)
  end
  return spent, order, reachedDex
end

local quiet, quietOrder, quietDone = run(false)
local mashed, mashedOrder, mashedDone = run(true)

check(quietDone and mashedDone, "both runs reach HoFDisplayPlayerStats' dex texts")
eq(table.concat(quietOrder, " "),
   "back_mons mons_scroll mons_info mons_banner fade back_player player player_stats",
   "the induction runs back sweep, front scroll, info hold, banner, fade, then the player")
eq(table.concat(mashedOrder, " "), table.concat(quietOrder, " "),
   "holding A visits the same phases in the same order")

-- .ScrollPic: hSCX from $c0 to $a0 at e = 4 (56 frames), then the front pic
-- from -64 to hlcoord 12 (40 frames) -- plain DelayFrame loops
eq(quiet.back_mons, 56, "the back pic sweep is 56 DelayFrames")
eq(quiet.mons_scroll, 40, "the front pic scroll is 40 DelayFrames")
-- HoFDisplayAndRecordMonInfo then `ld c, 80 / call DelayFrames`
eq(quiet.mons_info, 80, "the LEVEL/TYPE box holds 80 frames")
-- TextBoxBorder + HallOfFameText then `ld c, 180 / call DelayFrames`
eq(quiet.mons_banner, 180, "the HALL OF FAME banner holds 180 frames")
-- GBFadeOutToWhite
eq(quiet.fade, 20, "the fade to white runs its 20 frames")
eq(quiet.back_player, 56, "the player's back pic sweeps the same 56 frames")
eq(quiet.player, 41, "the player's front pic scrolls in over 40 frames and settles")
-- the stat boxes are up for one HoFPrintTextAndDelay window before the first
-- dex text replaces the bottom of the screen
eq(quiet.player_stats, 120, "the name/time/money boxes hold 120 frames")

for _, k in ipairs(quietOrder) do
  eq(mashed[k], quiet[k], "A held: " .. k .. " still spends its full DelayFrames")
end

T.finish("gen1_hof_no_skip_bug2785")
