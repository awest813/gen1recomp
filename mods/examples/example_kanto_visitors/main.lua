-- Gallery: Gold / Silver wild encounters.  Gold keys its wild tables by
-- KIND first and map second (data.gen2Encounters.grass.ROUTE_29), with one
-- seven-slot list per time of day, so the registry id is "grass" and the
-- patch is a table of whole map rows.  Each row is copied from the merged
-- view and only the chosen slot changes: the slot ORDER is the roll
-- (30/30/20/10/5/4/1 percent, data/wild/johto_grass.asm), so a row keeps
-- exactly seven entries.
local SLOT = 3 -- the 20 percent slot

-- who visits where, by time of day; the level is the slot's own
local VISITORS = {
  ROUTE_29 = { MORN = "PIKACHU", DAY = "PIKACHU", NITE = "CLEFAIRY" },
  ROUTE_30 = { MORN = "BULBASAUR", DAY = "CHARMANDER", NITE = "GASTLY" },
  ROUTE_31 = { MORN = "SQUIRTLE", DAY = "EEVEE", NITE = "ABRA" },
}

local function copyRow(row)
  local out = { map = row.map, rates = {}, slots = {} }
  for tod, rate in pairs(row.rates or {}) do out.rates[tod] = rate end
  for tod, list in pairs(row.slots or {}) do
    local slots = {}
    for i, slot in ipairs(list) do
      slots[i] = { level = slot.level, species = slot.species }
    end
    out.slots[tod] = slots
  end
  return out
end

return function(mod)
  local grass = mod.content.encounters:get("grass") or {}
  local rows, changed = {}, 0
  for mapId, byTime in pairs(VISITORS) do
    local row = grass[mapId]
    if row then
      local new = copyRow(row)
      for tod, species in pairs(byTime) do
        local slot = new.slots[tod] and new.slots[tod][SLOT]
        if slot and mod.content.pokemon:get(species) then
          slot.species = species
          changed = changed + 1
        end
      end
      rows[mapId] = new
    end
  end
  if next(rows) then mod.content.encounters:patch("grass", rows) end
  mod.exports.slots = changed
  mod.log:info("%d wild slots now hold a Kanto visitor", changed)
end
