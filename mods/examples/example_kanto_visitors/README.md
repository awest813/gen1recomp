# Kanto Visitors Example

Kanto Pokémon in the grass of **Gold and Silver**'s first routes:

| Route | Morning | Day | Night |
|---|---|---|---|
| 29 | PIKACHU | PIKACHU | CLEFAIRY |
| 30 | BULBASAUR | CHARMANDER | GASTLY |
| 31 | SQUIRTLE | EEVEE | ABRA |

Each visitor takes the 20 percent grass slot at that slot's own level, so
it is as easy to catch as anything else on the route.

## Try it

```sh
cp -r mods/examples/example_kanto_visitors mods/
luajit mods/examples/example_kanto_visitors/tests/example_kanto_visitors_test.lua
```

Enable it (`example_kanto_visitors = true` under `mods` in `options.lua`, or
the launcher's **Mods** page), start Gold and walk into the grass on Route 29.

## What it demonstrates

Gold keys its wild tables by **kind** first and map second
(`data.gen2Encounters.grass.ROUTE_29`), with a seven-slot list for each time
of day. The registry id is therefore the kind, and the patch is a table of
whole map rows:

```lua
mod.content.encounters:patch("grass", { ROUTE_29 = row })
```

The slot order is the roll (30/30/20/10/5/4/1 percent), so the mod copies each
row from the merged view with `mod.content.encounters:get("grass")` and
changes only the third slot. Every row keeps exactly seven slots, and its
encounter rate is unchanged.

## Seen in the real game

`tests/drivers/gen2_kanto_visitors_mod.lua` warps to Route 29 in a real Gold
boot and rolls the world's own grass table 4000 times per time of day:

| | PIDGEY | SENTRET | PIKACHU | RATTATA |
|---|---|---|---|---|
| Day | 35.1% | 40.5% | 19.6% | 4.8% |

By night CLEFAIRY takes 18.9%. It then starts a wild battle against the
PIKACHU the roll produced.
