# Browser build (love.js)

The browser port runs the unmodified engine under **love.js**: LÖVE compiled to
WebAssembly with Emscripten. The plan, audit and status are in
[docs/proposals/web-port.md](../../docs/proposals/web-port.md).

Same model as every other port. The page ships engine code and bundled
metadata, but no ROM and no game data. The player picks a ROM, it is read and
imported inside the browser, and the generated cache and saves live in that
browser's IndexedDB.

## Build

```sh
scripts/build_web.sh            # first run installs emsdk 2.0.0 and builds love.js
python3 -m http.server -d dist/web 8000
```

Open <http://localhost:8000>. The wasm will not load from `file://`. The
compatibility (no-pthreads) build needs no COOP/COEP headers, so any static
host works.

Turn on gzip or brotli for `.wasm` and `.js` if the host doesn't by default:
`love.wasm` drops from about 5.1 MB to 1.7 MB and `love.js` from 360 KB to
75 KB. `game.data` is the zipped `game.love` and barely compresses. Serve
`.wasm` as `application/wasm`; browsers otherwise fall back to a slower
compile path.

Requirements: `git`, `cmake`, `make`, `python3`, `node`/`npm`, `zip`. The first
native build takes several minutes. Later runs can reuse it:

```sh
scripts/build_web.sh --skip-native        # repack Lua/assets only (~10 s)
scripts/build_web.sh --split-mb 20        # split game.data for per-file host caps
```

## Smoke test

```sh
node ports/web/smoke_test.mjs --site dist/web              # ROM-free: boots to the launcher
node ports/web/smoke_test.mjs --site dist/web --rom blue.gb --play
```

The script drives headless Chromium through Playwright, using SwiftShader for
WebGL.

- **ROM-free mode** (for CI): it fails on any Lua error, any uncaught page
  error, or a missing native bridge.
- **With `--rom`**: it also imports through the page's real file input and
  waits for the cache marker. It then closes the tab without `beforeunload`
  (so love.js's own flush cannot help) and requires a new tab to find the
  cache in IndexedDB.
- **With `--play`**: it plays to the bedroom, saves with F1, and requires a
  fresh tab's CONTINUE to load that save. It also checks that a second
  simultaneous tab refuses to start.
- Any `lua-error.log` (the in-game crash screen) fails the run.
- It reports import time, frame rate, main-thread stalls over 50 ms, and wasm
  heap size.

Screenshots and the console log go to `dist/web-smoke/`.

## CI and GitHub Pages

`.github/workflows/web.yml` runs on pushes to `dev`/`main` and on pull requests
that touch the engine or the web port. Each run builds the site, runs the
ROM-free smoke test, and uploads two artifacts:

- **`gen1recomp-web`**: the site. Unzip it and serve it to play.
- **`gen1recomp-web-smoke`**: the smoke screenshots and console log.

The emsdk and love.js build tree are cached between runs.

To publish on GitHub Pages:

1. Set **Settings > Pages > Source** to **GitHub Actions** (once).
2. Go to **Actions > web > Run workflow**, tick **deploy**, and run it. The
   workflow must exist on the default branch to be runnable by hand.

The page carries no ROM and no game data. Each player imports their own ROM,
which stays in their browser.

### Releases

`release.yml`'s `web` job builds from the release's own version-stamped
`game.love` (`scripts/build_web.sh --love dist/payload/game.love`) and runs
the smoke test. The site is published as `gen1recomp-<version>-web.zip`,
ready to unzip onto any static host.

## How it fits together

| Piece | What it does |
|---|---|
| `scripts/build_web.sh` | Pins and fetches the love.js sources. Patches, builds, packs `game.love` and packages the site. |
| `ports/web/patch_love.py` | Adds `love_3p_g1rweb` to LÖVE's CMake build. Preloads `bit` and `lovejs` in `love.cpp`. Idempotent. |
| `ports/web/native/bit.c` | Lua BitOp 1.0.2 (Mike Pall, MIT). LuaJIT has `bit` built in; PUC Lua does not, and 130+ engine files require it. |
| `ports/web/native/lovejs_bridge.cpp` | The `lovejs` module: picker queue, drop queue and IndexedDB sync, using `EM_JS` calls into the page. |
| `ports/web/shell/index.html` | The page. A Start button unlocks Web Audio and provides the user gesture the picker needs. It also holds the full-viewport canvas, the hidden file input, drag-and-drop, and storage flushes on hide/unload. |
| `src/core/WebHost.lua` | Lua side. It installs the bridge onto `love.system` under the UWP picker names. It debounces storage syncs after save-dir writes and turns drops into `love.filedropped` calls. |
| `src/core/Platform.lua` | The `"Web"` profile: no threads, no processes, no updater, no curl. Picks are temporary. |

**One tab at a time.** IDBFS makes IndexedDB mirror the running tab's
filesystem on every sync, so the page takes a Web Lock (`g1r-instance`) and a
second tab shows "Already open" instead of starting.

**File picker.** Lua asks for a file from inside a frame tick. The browser
opens a file dialog only while the triggering click or key press still counts
as a user gesture, and a gamepad press never does. So the page also shows a
Browse/Cancel bar, which is always a real click.

Picked and dropped files are staged under `/tmp` (MEMFS), which is never
persisted. The importer reads the ROM once and deletes the copy, so a ROM never
reaches IndexedDB.

## Pinned third-party sources

All pins live at the top of `scripts/build_web.sh`. The script refuses a
checkout that is not at its pin.

- **emsdk 2.0.0.** love.js needs 2.0.x; newer releases dropped `getMemory`.
  The emsdk installer is pinned too (`EMSDK_COMMIT`). It logs a 404 for a
  `.tar.xz` download on 2.0.0, then falls back to the `.tbz2` that exists.
- **Davidobot/love.js, Davidobot/megasource and Davidobot/love** (`emscripten`
  branches). Note that this LÖVE reports itself as **11.4**, so `conf.lua`'s
  `t.version = "11.5"` only prints a compatibility notice.
- **emscripten-ports/SDL2 `version_22`**, fetched with git and passed through
  `EMCC_LOCAL_PORTS`. emscripten 2.0.0 would otherwise download a GitHub
  archive zip by hash.

## Build flags that matter

- **`-s DISABLE_EXCEPTION_CATCHING=0` at compile time**, not just link time.
  LÖVE reports failures such as a missing file as C++ exceptions, which it
  converts to Lua errors. Without the compile flag those exceptions unwind
  straight through Lua's `pcall`, so any guarded `love.filesystem.read` of a
  missing file aborts the caller.
- **PUC Lua built as C++** (`patch_lua.py`). Compiled as C, Lua raises
  errors with `longjmp`, and emscripten 2.0.0 mishandles a `longjmp` through
  C++ frames built with exception catching. Every LÖVE error that comes back
  through `luax_catchexcept` then broke the caller's `pcall`:
  `newImageData`/`newSource` jumped out of it, and `newImage` on a missing
  file trapped and killed the runtime (Gold's intro probing for Crystal's
  `kris.png`). As C++, `lua_error` is a `throw` (Lua's own `LUAI_THROW`), and
  the public API keeps C linkage. Measured: no speed difference.
- **RGBA8 canvases** (patched in `patch_love.py`). Upstream LÖVE gives
  GLES2 an RGBA8 render target only if `OES_rgb8_rgba8` is reported, and
  WebGL never reports it, so every Canvas was RGBA4.
- **`LOVEJS_COMPAT=1`** gives the no-pthreads build. Every engine worker has a
  main-thread fallback; `Platform.hasThreads()` is false on Web, so they take
  it.
