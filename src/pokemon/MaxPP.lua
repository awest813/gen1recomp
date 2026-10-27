-- A move's maximum PP with its PP UPs (Gen 1).
--
-- engine/items/item_effects.asm AddBonusPP: each PP UP adds a fifth of the
-- move's base PP, but at most 7 ("cp 8 / jr c, .addAmount / ld a, 7"), so a
-- 40-PP move (GROWL, GROWTH) tops out at 61, not 64 -- which is also the
-- largest value the 6-bit PP field of a save can hold.  Its own module so
-- the battle, the menus, the items and the link code share one formula
-- without requiring each other.
local MaxPP = {}

function MaxPP.bonus(basePP)
  return math.min(7, math.floor((basePP or 0) / 5))
end

function MaxPP.of(basePP, ppUps)
  return (basePP or 0) + (ppUps or 0) * MaxPP.bonus(basePP)
end

return MaxPP
