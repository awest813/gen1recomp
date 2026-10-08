# Web browser (beta)

The browser build runs the same engine as the desktop app, compiled to
WebAssembly with love.js. Pokemon Red, Blue and Yellow are supported. Gen 2
and Gen 3 tabs appear in the launcher but are untested in the browser.

## Playing

1. Open the page and press **Start**. Browsers only allow sound after a
   click or tap, and this one counts.
2. Press **Import ROM** and choose your legally obtained `.gb` / `.gbc` file,
   or drag it onto the page. The same SHA-1 check as desktop applies (see the
   table in the [README](../../README.md#quick-start)). Import takes about
   5 seconds.
3. Press the cart to play.

Your ROM is read inside the browser and never uploaded. Only the generated
game data and your saves are kept, in that browser's storage (IndexedDB). A
copy of the ROM itself is never stored.

### Controls

| Action | Keyboard | Gamepad | Phone |
| --- | --- | --- | --- |
| Move | Arrow keys / WASD | D-pad / left stick | on-screen D-pad |
| A | Z / Enter / Space | A | on-screen A |
| B | X / Backspace | B | on-screen B |
| Start | Escape | Start | on-screen Start |
| Select | Tab / Shift | Back / Select | on-screen Select |
| Save | F1 | | START menu > SAVE |

On a phone, the on-screen buttons appear the first time you touch the game.
The **Fullscreen** button in the top-left corner appears when you move the
mouse or touch the screen (Esc leaves fullscreen). iPhone browsers have no
fullscreen mode for pages, so the button is hidden there.

### Saves

Saves live in the browser's storage for that site, so they disappear if you
clear its site data or use a private window. To keep a copy, use **Export
save** on the launcher's save panel, which downloads a `.sav` file. **Import
save** brings one back, in this browser or in the desktop app.

The game runs in one tab at a time. A second tab shows "Already open" instead
of starting, because two copies would overwrite each other's saves. It starts
by itself once the other tab closes.

### Links

The page accepts the desktop [launch options](../guides/launch-options.md) as
URL parameters:

| URL | Effect |
| --- | --- |
| `?game=blue` | boot Blue directly, skipping the launcher |
| `?game=red&slot=2` | boot Red on save slot 2 |
| `?game=yellow&launcher=1` | open the launcher on Yellow |

## What is different from desktop

- **No self-updater, mod catalog or online play.** The browser can't run the
  curl and TCP transports those use. Locally installed mods still load.
- **No SHADER FX** (librashader is a native library). Performance defaults to
  LOW, which also turns off TILT and survey zoom; audio is synthesized at
  22.05 kHz.
- **No launcher splash or theme videos.**
- **The browser picks the display.** The game letterboxes into the window;
  use the Fullscreen button instead of the in-game video mode.

## Hosting your own copy

Build instructions, the smoke test and the GitHub Pages workflow are in
[ports/web/BUILD.md](../../ports/web/BUILD.md). The site is static (any web
server works) and needs no special headers.
