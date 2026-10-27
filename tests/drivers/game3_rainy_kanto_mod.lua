-- Driver: mods/examples/example_rainy_kanto in a real FireRed boot.  Starts a
-- new game, walks into Pallet Town and Route 1 and prints the weather the
-- map loader applied (3 = rain, 5 = thunderstorm), with a screenshot of each.
--
--   RK state  loaded ...  exports <maps patched>
--   RK pallet weather <id>
--   RK route1 weather <id>
--
--   POKEPORT_GAME=firered tools/run_driver.sh firered <id> \
--     tests/drivers/game3_rainy_kanto_mod.lua <shotdir>
local U = require("tests.drivers.util")
local OUT = os.getenv("POKEPORT_SHOT_DIR") or "/tmp/game3_rainy_kanto_mod"
return function(game)
  for _ = 1, 900 do if game.phase == "boot" and game.boot then break end U.wait(1) end
  game:_handleBootAction({ action = "new_game", name = "RED" })
  U.wait(240)
  local L = game.mods
  local m = L and L.mods and L.mods.example_rainy_kanto
  print("RK state", m and m.state, m and m.failure, "exports", L and L.exports.example_rainy_kanto and L.exports.example_rainy_kanto.maps)
  local Map = require("src.core.game3.map")
  local Player = require("src.core.game3.player")
  local Weather = require("src.core.game3.weather")
  local function placeAt(mapId, x, y)
    Map.load(nil, game, mapId, { x = x, y = y, facing = "down" })
    if game.session then game.session.x, game.session.y, game.session.facing = x, y, "down" end
    Player.cellX, Player.cellY = x, y
    Player.px, Player.py = x * 16, y * 16
  end
  placeAt("FR_PALLET_TOWN", 12, 9)
  U.wait(300)
  print("RK pallet weather", Weather.current)
  U.shot(game, OUT .. "/pallet.png")
  placeAt("FR_ROUTE_1", 10, 20)
  U.wait(300)
  print("RK route1 weather", Weather.current)
  U.shot(game, OUT .. "/route1.png")
  love.event.quit(0)
end
