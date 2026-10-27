-- Max PP with PP UPs (src/pokemon/MaxPP.lua): a fifth of the base PP per PP
-- UP, at most 7 (engine/items/item_effects.asm AddBonusPP).  The summary,
-- the battle menus, healing, the ETHERs and PP UP itself all used the
-- uncapped fifth, so a 40-PP move with three PP UPs read /64 -- past the
-- 6-bit PP field a save keeps (61 is its ceiling here).
--   luajit tests/engine/max_pp_cap_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local MaxPP = require("src.pokemon.MaxPP")

T.eq(MaxPP.of(40, 3), 61, "GROWL (40 PP) with three PP UPs tops out at 61")
T.eq(MaxPP.of(40, 0), 40, "no PP UP, no bonus")
T.eq(MaxPP.of(35, 3), 56, "35 PP: 7 per PP UP, under the cap")
T.eq(MaxPP.of(10, 3), 16, "10 PP: 2 per PP UP")
T.eq(MaxPP.of(5, 2), 7, "5 PP: 1 per PP UP")
T.eq(MaxPP.bonus(40), 7, "the bonus is capped at 7")

-- PP UP adds the capped bonus to the move's current PP
local ItemEffects = require("src.inventory.ItemEffects")
local data = { moves = { GROWL = { name = "GROWL", pp = 40 } }, text = {}, items = { PP_UP = { name = "PP UP" } } }
local mon = { moves = { { id = "GROWL", pp = 40, ppUps = 2 } } }
local ok, err = pcall(ItemEffects.use, data, { bag = {} }, "PP_UP", mon, nil, 1)
T.check(ok, "PP UP runs (" .. tostring(err) .. ")")
T.eq(mon.moves[1].ppUps, 3, "PP UP counts the third use")
T.eq(mon.moves[1].pp, 47, "and adds 7, not 8")

-- a loaded save gets the capped PP too when a slot has none
local SaveData = require("src.core.SaveData")
local sdata = { moves = { GROWL = { name = "GROWL", pp = 40 } },
  pokemon = { PIKACHU = { name = "PIKACHU", baseStats = { hp = 35, attack = 55, defense = 30, speed = 90, special = 50 } } },
  items = {}, text = {}, maps = {} }
local party = { { species = "PIKACHU", level = 5, moves = {
  { id = "GROWL", ppUps = 3 }, { id = "GROWL", pp = 64, ppUps = 3 }, { id = "GROWL", pp = 12, ppUps = 3 } } } }
local okV, errV = pcall(SaveData.validate, { party = party, boxes = {} }, sdata)
if T.check(okV, "validate runs (" .. tostring(errV) .. ")") then
  T.eq(party[1].moves[1].pp, 61, "a missing PP defaults to the capped max")
  T.eq(party[1].moves[2].pp, 64, "a stored PP is kept (under Mimic it is another move's)")
  T.eq(party[1].moves[3].pp, 12, "a spent move keeps what it has left")
end
T.finish("max pp cap")
