-- Standalone: luajit mods/examples/example_rainy_kanto/tests/example_rainy_kanto_test.lua
-- Loads the mod as FireRed would and checks the map headers it patches.
-- In a real boot the map loader hands def.weather to src/core/game3/weather.lua
-- on entry; tests/drivers/game3_rainy_kanto_mod.lua shows that on screen.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")

local IDS = { "FR_PALLET_TOWN", "FR_ROUTE_1", "FR_VIRIDIAN_CITY", "FR_ROUTE_22",
              "FR_ROUTE_2", "FR_PEWTER_CITY" }

local function dataset()
  local data = T.sdk.gen3Data()
  for _, id in ipairs(IDS) do
    data.maps[id] = { id = id, name = id, width = 20, height = 20, weather = 2 }
  end
  return data
end

local run = T.sdk.loadMod("mods/examples/example_rainy_kanto",
  { data = dataset(), generation = 3 })
T.eq(#run.errors, 0, "loads clean on FireRed (" .. tostring(run.errors[1]) .. ")")
T.eq(run.loader.exports.example_rainy_kanto.maps, #IDS, "every listed map was patched")
for _, id in ipairs(IDS) do
  T.eq(run.data.maps[id].weather, 3, id .. " rains")
  T.eq(run.data.maps[id].width, 20, id .. " keeps the rest of its header")
end
T.eq(run.data.maps.FR_OAKS_LAB.weather, nil, "an indoor map is left alone")
run.release()

-- a dataset missing a map: skipped, never registered as an empty one
local partial = dataset()
partial.maps.FR_PEWTER_CITY = nil
run = T.sdk.loadMod("mods/examples/example_rainy_kanto", { data = partial, generation = 3 })
T.eq(#run.errors, 0, "a missing map is not an error")
T.eq(run.loader.exports.example_rainy_kanto.maps, #IDS - 1, "and is not counted")
T.eq(run.data.maps.FR_PEWTER_CITY, nil, "nor created")
run.release()

-- Red has no such maps and no such weather byte: the mod does not load there
run = T.sdk.loadMod("mods/examples/example_rainy_kanto", { generation = 1 })
T.eq(run.mod and run.mod.state, "wrong_generation", "not loaded on a Gen 1 game")
run.release()

T.finish("example_rainy_kanto")
