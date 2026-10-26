# Modding overview

The game ships a native mod platform: content registries, events and hooks,
per-mod saves and options, and an in-game manager (F10).

- Shipped example mods, one per kind of author: [mods/](../mods/)
- In-repo SDK docs: [modding.md](modding.md), [CONTRIBUTING-mods.md](../CONTRIBUTING-mods.md)
- Map editing: maps can be edited in [Tiled](https://www.mapeditor.org)
  with the `gen1-mod-export` extension and exported back out as a mod; see
  [tiled-map-editing.md](tiled-map-editing.md).
- Other tools: the save editor (the launcher's Edit button on a save row)
  edits party, boxes, items, events, and Pokedex flags outside the game.
