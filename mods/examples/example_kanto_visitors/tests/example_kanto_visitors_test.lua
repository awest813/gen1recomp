-- Standalone: luajit mods/examples/example_kanto_visitors/tests/example_kanto_visitors_test.lua
-- Loads the mod as Gold would against a small wild table and checks the
-- patched rows.  In a real boot the same rows are what
-- src/battle/gen2/Encounter.lua rolls from; tests/drivers/
-- gen2_kanto_visitors_mod.lua measures that roll on Route 29.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")

local SPECIES = { "PIDGEY", "SENTRET", "RATTATA", "HOOTHOOT", "CATERPIE",
                  "METAPOD", "SPINARAK", "PIKACHU", "CLEFAIRY", "BULBASAUR",
                  "CHARMANDER", "SQUIRTLE", "EEVEE", "GASTLY", "ABRA" }

local function row(map, a, b)
  local function seven(x, y)
    return { { level = 2, species = x }, { level = 3, species = y },
             { level = 3, species = x }, { level = 2, species = y },
             { level = 4, species = "RATTATA" }, { level = 4, species = x },
             { level = 4, species = x } }
  end
  return { map = map, rates = { MORN = 25, DAY = 25, NITE = 25 },
           slots = { MORN = seven(a, b), DAY = seven(a, b), NITE = seven("HOOTHOOT", "RATTATA") } }
end

local function dataset()
  local pokemon = {}
  for i, id in ipairs(SPECIES) do pokemon[id] = { name = id, dex = i } end
  return {
    pokemon = pokemon,
    gen2Encounters = { grass = {
      ROUTE_29 = row("ROUTE_29", "PIDGEY", "SENTRET"),
      ROUTE_30 = row("ROUTE_30", "PIDGEY", "CATERPIE"),
      ROUTE_31 = row("ROUTE_31", "PIDGEY", "CATERPIE"),
      ROUTE_32 = row("ROUTE_32", "PIDGEY", "RATTATA"),
    } },
  }
end

local run = T.sdk.loadMod("mods/examples/example_kanto_visitors",
  { data = dataset(), generation = 2 })
T.eq(#run.errors, 0, "loads clean on Gold (" .. tostring(run.errors[1]) .. ")")
T.eq(run.loader.exports.example_kanto_visitors.slots, 9, "nine slots changed")
local grass = run.data.gen2Encounters.grass
T.eq(grass.ROUTE_29.slots.DAY[3].species, "PIKACHU", "Route 29 by day: PIKACHU")
T.eq(grass.ROUTE_29.slots.NITE[3].species, "CLEFAIRY", "Route 29 by night: CLEFAIRY")
T.eq(grass.ROUTE_30.slots.MORN[3].species, "BULBASAUR", "Route 30 in the morning: BULBASAUR")
T.eq(grass.ROUTE_31.slots.DAY[3].species, "EEVEE", "Route 31 by day: EEVEE")
T.eq(grass.ROUTE_29.slots.DAY[3].level, 3, "the visitor takes the slot's own level")
for _, tod in ipairs({ "MORN", "DAY", "NITE" }) do
  T.eq(#grass.ROUTE_29.slots[tod], 7, "Route 29 " .. tod .. " still has seven slots")
end
T.eq(grass.ROUTE_29.slots.DAY[1].species, "PIDGEY", "the other slots are untouched")
T.eq(grass.ROUTE_29.rates.DAY, 25, "and so is the encounter rate")
T.eq(grass.ROUTE_32.slots.DAY[3].species, "PIDGEY", "Route 32 is not on the list")
run.release()

run = T.sdk.loadMod("mods/examples/example_kanto_visitors", { generation = 1 })
T.eq(run.mod and run.mod.state, "wrong_generation", "not loaded on a Gen 1 game")
run.release()

T.finish("example_kanto_visitors")
