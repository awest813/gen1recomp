-- Gallery: FireRed / LeafGreen map weather.  Every Gen 3 map header carries
-- a weather byte (pokefirered include/constants/weather.h), and the map
-- loader applies it on entry, so a one-field `patch` per map is the whole
-- mod: no hook, no per-frame code.
local WEATHER = {
  rain = 3,  -- WEATHER_RAIN
  storm = 5, -- WEATHER_RAIN_THUNDERSTORM
  fog = 6,   -- WEATHER_FOG_HORIZONTAL
}

-- the start of the journey, Pallet Town up to Pewter City
local MAPS = {
  "FR_PALLET_TOWN", "FR_ROUTE_1", "FR_VIRIDIAN_CITY", "FR_ROUTE_22",
  "FR_ROUTE_2", "FR_PEWTER_CITY",
}

return function(mod)
  mod.options:define({
    { key = "weather", label = "WEATHER", type = "choice", default = "rain",
      choices = { { "RAIN", "rain" }, { "STORM", "storm" }, { "FOG", "fog" } } },
  })

  local weather = WEATHER[mod.options:get("weather")] or WEATHER.rain
  local patched = 0
  for _, id in ipairs(MAPS) do
    -- a map this dataset does not have (a LeafGreen-only edit, an older
    -- cache) is skipped rather than registered as an empty map
    if mod.content.maps:get(id) then
      mod.content.maps:patch(id, { weather = weather })
      patched = patched + 1
    end
  end
  mod.exports.weather = weather
  mod.exports.maps = patched
  mod.log:info("weather %d on %d maps", weather, patched)
end
