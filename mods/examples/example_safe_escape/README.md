# Safe Escape Example

**RUN** always works in a wild battle. Only the speed roll is replaced: trainer battles, the scripted no-escape battles, Mean Look, wrapping moves and trapping abilities are all checked before the roll in each engine, so they still stop you. FireRed's double battles and Emerald's Battle Pyramid decide inside the roll, and keep their vanilla answer, and a wild Pokémon trying to flee keeps its own odds.

**Runs on every game.** It was measured on Yellow, Gold and FireRed (below);
Red, Blue, Silver, Crystal, LeafGreen and Emerald run the same three engines.
One hook covers all of them, because
`battle.run` has a call site in each engine with the same name and the same
shape.

## Try it

```sh
cp -r mods/examples/example_safe_escape mods/
luajit mods/examples/example_safe_escape/tests/example_safe_escape_test.lua
```

Then enable it (`example_safe_escape = true` under `mods` in `options.lua`, or the
launcher's **Mods** page), and start any game.

## Where the hook is called

| Game | Engine call site |
|---|---|
| Red / Blue / Yellow | `BattleState:runRoll`, `src/battle/BattleState.lua` |
| Gold / Silver / Crystal | `Battle:runRoll`, `src/battle/gen2/Battle.lua` |
| FireRed / LeafGreen / Emerald | `Engine.tryFlee`, `src/core/game3/battle/engine.lua` |

## Measured in the real games

`tests/drivers/xgen_gallery_mods.lua` starts a real wild battle in each
engine and calls the function the hook wraps, with the mod off and on:

| | Yellow | Gold | FireRed |
|---|---|---|---|
| Escapes, speed 10 against 200, out of 400, off → on | 56 → 400 | 58 → 400 | 12 → 400 |
