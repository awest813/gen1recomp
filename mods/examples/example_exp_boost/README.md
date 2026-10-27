# EXP Boost Example

Battles award more EXP: 2x by default, or 1.5x or 3x from the mod's **EXP RATE** option. **TRAINERS ONLY** leaves wild battles at the normal rate. The award is capped at 65535, the size of the EXP word in all three generations.

**Runs on every game.** It was measured on Yellow, Gold and FireRed (below);
Red, Blue, Silver, Crystal, LeafGreen and Emerald run the same three engines.
One hook covers all of them, because
`exp.gain` has a call site in each engine with the same name and the same
shape.

## Try it

```sh
cp -r mods/examples/example_exp_boost mods/
luajit mods/examples/example_exp_boost/tests/example_exp_boost_test.lua
```

Then enable it (`example_exp_boost = true` under `mods` in `options.lua`, or the
launcher's **Mods** page), and start any game.

## Where the hook is called

| Game | Engine call site |
|---|---|
| Red / Blue / Yellow | `Experience.apply`, `src/battle/Experience.lua` |
| Gold / Silver / Crystal | `Battle:giveExperiencePass`, `src/battle/gen2/Battle.lua` |
| FireRed / LeafGreen / Emerald | `Experience.awardFoe`, `src/core/game3/battle/experience.lua` |

## Measured in the real games

`tests/drivers/xgen_gallery_mods.lua` starts a real wild battle in each
engine and calls the function the hook wraps, with the mod off and on:

| | Yellow | Gold | FireRed |
|---|---|---|---|
| EXP for one wild L20 ONIX, off → on | 308 → 616 | 308 → 616 | 308 → 616 |
