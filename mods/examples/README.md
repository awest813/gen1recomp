# Example mod gallery

Eight reference mods, one per modder persona, plus six that also run on
Gold and FireRed. Each is small enough to read
in one sitting, exercises a different slice of the mod API, and is a real,
runnable, tested mod — not a snippet.

Copy the one closest to what you want to build.

| # | Mod | Persona | Category | What it does |
|---|---|---|---|---|
| 0 | [`../example_mew_starter`](../example_mew_starter) | (legacy) | `GAMEPLAY` | Oak's gift becomes a L20 Mew. The api-1 compatibility proof. |
| 1 | [`example_balance_tweaks`](example_balance_tweaks) | Tweaker | `BALANCE` | Faster starters, half-price TMs, a re-slotted Route 1 |
| 2 | [`example_shiny_palette`](example_shiny_palette) | Artist | `GRAPHICS` | A teal player recolor derived from your own cache |
| 3 | [`example_jukebox`](example_jukebox) | Musician | `AUDIO` | An authored chip song, a new cry, a jukebox screen |
| 4 | [`example_lost_parcel`](example_lost_parcel) | Quest author | `QUEST` | A two-town fetch quest over vanilla NPCs |
| 5 | [`example_weather`](example_weather) | Mechanic designer | `MECHANIC` | Rain that scales WATER and FIRE damage, behind a ruleset |
| 6 | [`example_dexnav`](example_dexnav) | Tool builder | `TOOL` | A START-menu dex overlay with an inter-mod API |
| 7 | [`example_mini_conversion`](example_mini_conversion) | TC team | `TOTAL_CONVERSION` | Sable Cove: one town, three species, one badge |
| 8 | [`example_silly_oak`](example_silly_oak) | Intro author | `UI` | Extra Oak questions, sprite swaps, answers in `mod.save` |

### For every game, and for Gold and FireRed

These six were written for the newer engines too. Each one's README shows it
measured in a real Yellow, Gold or FireRed boot, and
`tests/engine/gallery_every_game_test.lua` runs their suites ROM-free.

| Mod | Games | Category | What it does |
|---|---|---|---|
| [`example_exp_boost`](example_exp_boost) | all | `BALANCE` | 1.5x / 2x / 3x EXP through `exp.gain` |
| [`example_lucky_ball`](example_lucky_ball) | all | `BALANCE` | A failed ball rolls again through `catch.rate` |
| [`example_safe_escape`](example_safe_escape) | all | `TWEAK` | RUN always works in wild battles through `battle.run` |
| [`example_quiet_alarm`](example_quiet_alarm) | all | `AUDIO` | No low-HP beeping through `battle.low_health_alarm` |
| [`example_kanto_visitors`](example_kanto_visitors) | Gold, Silver | `CONTENT` | Kanto Pokemon in the grass of Routes 29-31 |
| [`example_rainy_kanto`](example_rainy_kanto) | FireRed, LeafGreen | `GRAPHICS` | Rain, a storm or fog from Pallet Town to Pewter City |

## None of these load by default

The engine discovers mods one level below `mods/`. The gallery lives one
level deeper, in `mods/examples/`, so a fresh install finds none of them
and the vanilla game is unchanged — the parity invariant holds by
construction.

To run one, copy it up a level:

```sh
cp -r mods/examples/example_balance_tweaks mods/
python3 tools/modkit.py validate mods/example_balance_tweaks --base imported
```

then enable it in `options.lua` (`mods = { example_balance_tweaks = true }`)
or toggle it in the F10 mod manager.

## Coverage

Between them the gallery writes into `pokemon`, `items`, `encounters`,
`maps`, `sprites`, `palettes`, `icons`, `music`, `cries`, `screens`,
`map_scripts`, `commands`, `tokens`, `statuses`, `rulesets`, `constants`
and `field`, and exercises:

- the write verbs `register`, `override` and `patch`, plus `get` and
  `each` on the merged view
- both buses — `events:on` / `events:emit` and `hooks:wrap` — across
  `music.select`, `battle.damage`, `ui.start_menu.items`, `ui.options.rows`,
  `battle.started`, `battle.turn_started`, `battle.ended`, `flag.changed`,
  `game.ready`, `assets.transformed`, `intro.oak_speech.build`,
  `intro.oak_speech.answered` and `intro.oak_speech.finished`
- `mod.save`, `mod.options`, `mod.exports`, `mod.commands`, `mod.ui`,
  `mod:read`, `mod.log` and `mod.path`
- asset transforms, the `trueColor` opt-out, script labels and `choice`,
  parallel scripts, `mod:` field routing, replaying an overridden base talk
  handler through `MapScripts.baseTalk`, and the no-ROM-content posture

## What every entry has

```
mods/examples/<id>/
  manifest.json     api = 2, a category from the taxonomy, a semver engine range
  main.lua          the entry chunk
  mod.card          sharing metadata: summary, author, tags, differences, credits
  README.md         what it demonstrates, which persona, the commands to try it
  CHANGELOG.md      keep-a-changelog; headings match manifest.version
  tests/            one runnable suite asserting the mod's stated effect
  .modkitignore     keeps the suite out of the distributed package
```

`tests/mod_examples_tests.lua` in the engine's own suite loads all eight
together and asserts the above, so the gallery cannot rot.

These example mods arent perfect and are just examples to show you basics of wahts possible, but way more than just this is possible.