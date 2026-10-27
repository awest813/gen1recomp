# Rainy Kanto Example

Rain over the start of the journey in **FireRed and LeafGreen**: Pallet Town,
Route 1, Viridian City, Route 22, Route 2 and Pewter City. The mod's
**WEATHER** option picks RAIN (the default), STORM or FOG.

## Try it

```sh
cp -r mods/examples/example_rainy_kanto mods/
luajit mods/examples/example_rainy_kanto/tests/example_rainy_kanto_test.lua
```

Enable it (`example_rainy_kanto = true` under `mods` in `options.lua`, or the
launcher's **Mods** page), start FireRed and step outside.

## What it demonstrates

Every Gen 3 map header carries a weather byte
(`include/constants/weather.h` in pokefirered), and the map loader
(`src/core/game3/map.lua`) applies it each time you enter a map. So the whole
mod is one `patch` per map:

```lua
mod.content.maps:patch("FR_ROUTE_1", { weather = 3 }) -- WEATHER_RAIN
```

No hook, no code that runs every frame. A map the dataset does not have is
skipped, so the mod never invents an empty map.

Weather is part of the map header, so a WEATHER change applies on the next
boot. It is overworld weather only: battles on these routes are not rainy.

## Seen in the real game

`tests/drivers/game3_rainy_kanto_mod.lua` starts a new FireRed game, walks
into Pallet Town and Route 1, and prints the weather the map loader applied:
3 (rain) with the default option and 5 (thunderstorm) with STORM, with
falling rain in both screenshots.
