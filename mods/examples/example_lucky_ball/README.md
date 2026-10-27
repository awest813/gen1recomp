# Lucky Ball Example

A ball that fails gets one more roll (two more at **ROLLS PER BALL** 3). Each roll is that game's own throw, with its ball bonus, status bonus and HP factor, so a Master Ball, the Safari Zone and Gold's Apricorn balls behave as they always do.

**Runs on every game.** It was measured on Yellow, Gold and FireRed (below);
Red, Blue, Silver, Crystal, LeafGreen and Emerald run the same three engines.
One hook covers all of them, because
`catch.rate` has a call site in each engine with the same name and the same
shape.

## Try it

```sh
cp -r mods/examples/example_lucky_ball mods/
luajit mods/examples/example_lucky_ball/tests/example_lucky_ball_test.lua
```

Then enable it (`example_lucky_ball = true` under `mods` in `options.lua`, or the
launcher's **Mods** page), and start any game.

## Where the hook is called

| Game | Engine call site |
|---|---|
| Red / Blue / Yellow | `BattleState:catchAttempt`, `src/battle/BattleState.lua` |
| Gold / Silver / Crystal | `Catching.attempt`, `src/battle/gen2/Catching.lua` |
| FireRed / LeafGreen / Emerald | `Catching.tryCatch`, `src/core/game3/battle/catching.lua` |

## Measured in the real games

`tests/drivers/xgen_gallery_mods.lua` starts a real wild battle in each
engine and calls the function the hook wraps, with the mod off and on:

| | Yellow | Gold | FireRed |
|---|---|---|---|
| POKé BALLs that catch a full-HP L20 ONIX, out of 400, off → on | 28 → 50 | 24 → 50 | 22 → 38 |
