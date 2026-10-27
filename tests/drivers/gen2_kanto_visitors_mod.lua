-- Driver: mods/examples/example_kanto_visitors in a real Gold boot.  Warps to
-- Route 29, rolls the world's own grass table 4000 times per time of day and
-- prints the species split, then starts a wild battle with a visitor the
-- world's encounter roll produced and takes a screenshot.
--
--   KV roll DAY PIDGEY=..% PIKACHU=..% ...
--   KV battle PIKACHU 3
--
--   POKEPORT_GAME=gold tools/run_driver.sh gold <id> \
--     tests/drivers/gen2_kanto_visitors_mod.lua <shotdir>
local U = require("tests.drivers.util")
local OUT = os.getenv("POKEPORT_SHOT_DIR") or "/tmp/gen2_kanto_visitors_mod"
return function(game)
  U.wait(200)
  local L = game.mods
  local m = L and L.mods and L.mods.example_kanto_visitors
  print("KV state", m and m.state, m and m.failure, "slots", L and L.exports.example_kanto_visitors and L.exports.example_kanto_visitors.slots)
  local world = game.world
  world:warpToMapId("ROUTE_29", 50, 8, "down")
  U.wait(120)
  print("KV map", world.map and world.map.id, "tod", world.tod)
  local Encounter = require("src.battle.gen2.Encounter")
  for _, tod in ipairs({ "MORN", "DAY", "NITE" }) do
    local tally, n = {}, 4000
    for _ = 1, n do
      local r = Encounter.grassSlot(world:wildTables(), "ROUTE_29", tod, nil)
      if r then tally[r.species] = (tally[r.species] or 0) + 1 end
    end
    local parts = {}
    for sp, c in pairs(tally) do parts[#parts + 1] = ("%s=%.1f%%"):format(sp, 100 * c / n) end
    table.sort(parts)
    print("KV roll", tod, table.concat(parts, " "))
  end
  -- a real wild battle with whatever the world's own roll hands back
  local Mon = require("src.battle.gen2.Mon")
  local tod = world.tod or "DAY"
  game.save.party = { Mon.new(game.data, "CYNDAQUIL", 6) }
  local want = (tod == "NITE") and "CLEFAIRY" or "PIKACHU"
  for _ = 1, 500 do
    local roll = world:rollEncounter("wild", "grass", world:wildTables(), function(t, c)
      return Encounter.grassSlot(t, c.mapId, c.daytime, nil) end)
    if roll and roll.species == want then
      print("KV battle", roll.species, roll.level)
      world:startBattle({ wild = Mon.new(game.data, roll.species, roll.level) })
      break
    end
  end
  U.wait(500)
  U.shot(game, OUT .. "/battle.png")
  love.event.quit(0)
end
