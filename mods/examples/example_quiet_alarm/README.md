# Quiet Alarm Example

No more beeping when your Pokémon's HP bar turns red. The bar still turns red; only the sound is gone.

**Runs on every game.** It was measured on Yellow, Gold and FireRed (below);
Red, Blue, Silver, Crystal, LeafGreen and Emerald run the same three engines.
One hook covers all of them, because
`battle.low_health_alarm` has a call site in each engine with the same name and the same
shape.

## Try it

```sh
cp -r mods/examples/example_quiet_alarm mods/
luajit mods/examples/example_quiet_alarm/tests/example_quiet_alarm_test.lua
```

Then enable it (`example_quiet_alarm = true` under `mods` in `options.lua`, or the
launcher's **Mods** page), and start any game.

## Where the hook is called

| Game | Engine call site |
|---|---|
| Red / Blue / Yellow | `BattleState:updateFx`, `src/battle/BattleState.lua` |
| Gold / Silver / Crystal | `BattleState:updateAlarm`, `src/ui/gen2/BattleState.lua` |
| FireRed / LeafGreen / Emerald | the low-HP check in `src/core/game3/battle/init.lua` |

## Measured in the real games

`tests/drivers/xgen_gallery_mods.lua` starts a real wild battle in each
engine and calls the function the hook wraps, with the mod off and on:

| | Yellow | Gold | FireRed |
|---|---|---|---|
| Alarm loops started with a red bar, off → on | 1 → 0 | 1 → 0 | 1 → 0 |
