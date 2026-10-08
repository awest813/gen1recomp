-- engine/movie/credits.asm Credits / DisplayCreditsMon
--
-- Every credits screen is a DelayFrames program except DisplayCreditsMon's
-- LoadFrontSpriteByMonIndex, which decompresses the pic on the CPU with the
-- text still up: about 36 frames on the Game Boy.  Over 15 mon screens that
-- is 540 frames, which is how long the port's roll ran ahead of
-- Music_Credits (5880 frames, no loop): THE END sat under 13s of theme
-- instead of the original's ~4s (#2786).  This suite drives a synthetic
-- roll headless and pins the per-screen frame budget.

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local Credits = require("src.ui.Credits")

eq(Credits.MON_LOAD_FRAMES, 36, "LoadFrontSpriteByMonIndex: ~36 frames of CPU per mon screen")
eq(Credits.MON_PREP_FRAMES, 9, "three CreditsCopyTileMapToVRAM, each jp Delay3")
eq(Credits.WIPE_FRAMES, 27, "ScrollCreditsMonLeft x7 then x20")

local function roll(screens)
  local stack = { states = {} }
  function stack:push(s) self.states[#self.states + 1] = s; if s.enter then s:enter() end end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  local game = {
    data = { field = { credits = { screens = screens, mons = {} } } },
    input = { wasPressed = function() return false end, isDown = function() return false end },
    stack = stack, save = {},
  }
  local theEndAt
  local frame = 0
  local credits = Credits.new(game, function() end, function() theEndAt = frame end)
  stack:push(credits)
  local spent, order = {}, {}
  while credits.phase ~= "end_wait" and frame < 20000 do
    local k = credits.phase .. "#" .. tostring(credits.index)
    if not spent[k] then spent[k] = 0; order[#order + 1] = k end
    spent[k] = spent[k] + 1
    frame = frame + 1
    credits:update(1 / 60)
  end
  return spent, order, frame, theEndAt
end

-- one of each CreditsOrder terminator
local screens = {
  { fade = true, mon = "VENUSAUR", lines = { { text = "CRED_TEXT_FADE_MON" } } },
  { fade = true, lines = { { text = "CRED_TEXT_FADE" } } },
  { mon = "PARASECT", lines = { { text = "CRED_TEXT_MON" } } },
  { fade = true, lines = { { text = "CRED_TEXT_FADE again" } } },
  { lines = { { text = "CRED_TEXT" } } },
}
local spent, order, total, theEndAt = roll(screens)

eq(table.concat(order, " "),
   "white#0 intro#0 fade#1 hold#1 mon_prep#1 wipe#1 fade#2 hold#2 hold#3 mon_prep#3 wipe#3 "
   .. "fade#4 hold#4 hold#5 end_blank#6 end_fade#6 end_hold#6",
   "the phases run in CreditsOrder order")
eq(spent["white#0"], 100, "HallOfFamePC: ClearScreen + 100 DelayFrames")
eq(spent["intro#0"], 128, "bars + PlayMusic, then 128 DelayFrames")

-- CRED_TEXT_FADE_MON: FadeInCredits (20), 90 hold, then DisplayCreditsMon
eq(spent["fade#1"], 20, "FadeInCredits is 4 palettes x 5 frames")
eq(spent["hold#1"], 90, "CRED_TEXT_FADE_MON holds 90 frames")
eq(spent["mon_prep#1"], 36 + 9,
   "the text stays up for the sprite decompression and the three Delay3 copies")
eq(spent["wipe#1"], 27, "then the 27-frame scroll")

-- CRED_TEXT_MON: text at once, 110 hold, same DisplayCreditsMon
eq(spent["hold#3"], 110, "CRED_TEXT_MON holds 110 frames")
eq(spent["mon_prep#3"], 36 + 9, "every mon screen pays the decompression")
eq(spent["wipe#3"], 27, "and the same scroll")

-- the text-only terminators pay no sprite load
eq(spent["fade#2"], 20, "CRED_TEXT_FADE fades in")
eq(spent["hold#2"], 120, "and holds 120 frames")
eq(spent["hold#5"], 140, "CRED_TEXT holds 140 frames")
check(spent["mon_prep#2"] == nil and spent["mon_prep#5"] == nil,
      "no decompression wait on a screen with no mon")

-- CRED_THE_END: 16 blank frames, the letters, one more FadeInCredits, then
-- HallOfFameResetEventsAndSaveScript's 5 x 120 DelayFrames
eq(spent["end_blank#6"], 16, "THE END waits 16 frames on the blank band")
eq(spent["end_fade#6"], 20, "and fades (a no-op on color 3)")
eq(spent["end_hold#6"], 600, "then the script's 600-frame hold")
eq(theEndAt, 100 + 128 + (20 + 90 + 45 + 27) + (20 + 120) + (110 + 45 + 27)
   + (20 + 120) + 140 + 16 + 20,
   "onTheEnd fires after exactly the summed frame program")
eq(total, theEndAt + 600, "and the A/B wait starts 600 frames later")

-- the real CreditsOrder: 15 mon screens, so THE END now finishes 5694 frames
-- after the music starts (was 5154), ~3s before Music_Credits' 5880 end
local full = 128 + 7 * (20 + 90 + 45 + 27) + 8 * (110 + 45 + 27)
  + 15 * (20 + 120) + 5 * 140 + 16 + 20
eq(full, 5694, "CreditsOrder (7 FADE_MON, 8 MON, 15 FADE, 5 TEXT) adds up to 5694")
check(5880 - full > 0 and 5880 - full < 5 * 60,
      "the theme outlasts THE END by a few seconds, as on hardware")

T.finish("gen1_credits_mon_lag_bug2786")
