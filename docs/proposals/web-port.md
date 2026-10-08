# Proposal: browser (web) port, Gen 1 first

## Summary

Ship G1R in the browser by running the existing LÖVE 11.5 codebase under
**love.js** (LÖVE compiled to WebAssembly with Emscripten). Same model as
every other port: the page ships no ROM and no game data, the player picks
their own ROM, import runs client-side, and the generated cache plus saves
live in the browser's IndexedDB. Nothing about the ROM ever leaves the
player's machine.

The audit below was done against the canonical US **Pokemon Blue** ROM
(`d7037c83e1ae5b39bde3c30787637ba1d4c48ce2`, 1 MiB, MBC3+RAM+battery,
matches `src/core/GameVersion.lua:40`). Scope is the launcher + Gen 1
(Red/Blue/Yellow). Gen 2 and Gen 3 are noted where they diverge but are out
of scope for the first release.

**Verdict: feasible, with no rewrite.** The codebase is already unusually
well prepared: every `love.thread` user has a main-thread fallback, every
`ffi` call is `pcall`-guarded, shaders on the Gen 1 path are small GLSL ES
1.00-safe effects with no-shader fallbacks, and the mobile ports already
built an async "file appears in the save dir" import flow the web can reuse.
The real work is a handful of Lua 5.1 compatibility fixes, a `"Web"`
platform profile, a sleep-free main loop, a custom love.js build (for the
`bit` library and a file-picker/storage bridge), and audio tuning for a
non-JIT interpreter.

## Status

**All five phases are done.** Red, Blue and Yellow are playable in the browser
on desktop, on phones (touch) and with gamepads, and releases ship a web zip.
A scripted playthrough covered import, the intro, naming, the bedroom,
Pallet Town, Oak's cutscene, choosing SQUIRTLE, the rival battle (won,
level 6), the party menu, Route 1, a wild RATTATA battle, and saving and
continuing across tabs.
`ports/web/smoke_test.mjs --rom <blue.gb> --play` drives that whole path in
headless Chromium. Build and layout notes are in
[ports/web/BUILD.md](../../ports/web/BUILD.md).

Phase 2 measurements (headless Chromium, SwiftShader WebGL, x86-64 container):

| Metric | Result |
|---|---|
| Blue import (pick to `rom-cache.complete`) | **4.2 s**, on the coroutine path |
| Gameplay frame rate | 60 fps on title/intro; ~46 fps measured right after a save, under software GL |
| wasm heap | 256 MiB initial; no growth seen through import and play |
| `game.love` / whole site | 26 MB / 32 MB (all games' code and assets; launcher videos removed) |
| Cache persistence | Reaches IndexedDB through `WebHost`'s debounced sync; a second tab sees it without love.js's `beforeunload` flush |

What the spike found that the audit had not:

- **The love.js `emscripten` branch is LÖVE 11.4**, not 11.5. `conf.lua`'s
  `t.version = "11.5"` only prints a notice. Nothing in the Gen 1 path has
  needed 11.5 so far.
- **C++ exceptions escaped `pcall`.** Upstream love.js passes
  `DISABLE_EXCEPTION_CATCHING=0` only at link time. LÖVE errors (for example
  `love.filesystem.read` of a missing file) therefore unwound straight through
  Lua's `pcall`: `conf.lua`'s guarded `require("src.core.Version")` died, and
  the boot then failed with "loop or previous error loading module". The build
  now passes the flag at compile time too.
- **The Gen 3 importer is on the boot path.** The launcher's cache check loads
  the Gen 3 plan registry, so the six `goto` files had to become
  `repeat ... until true` loops now rather than "later". Two loops had a real
  loop-exit `break` that the rewrite would have turned into `continue`; the
  `repeat` was moved below those exits. The `lua51_compat.sh` allowlist is now
  empty.
- **Import is fast.** The 10-40 s estimate (L12) was pessimistic; Blue
  imports in about 4 s.
- **A latent launcher crash on every platform.** `Theme.versionRail` could
  index one past its colour table, because `x % 1` is exactly `1.0` for a tiny
  negative `x`. It surfaced first in the browser because love.js timer values
  differ. Fixed, with `tests/engine/theme_version_rail_test.lua`.
- **Post-spike audit fixes**, from an independent review of the diff:
  - Lua and the page now flush IndexedDB through one coalescer
    (`Module.g1rSync`), so a save can no longer be left unflushed when two
    syncs overlap.
  - Streamed `File` writes mark the store dirty.
  - A Web Lock keeps the game to one tab. IDBFS mirroring would otherwise let
    two tabs delete each other's data.
  - The picker shows a Browse/Cancel bar as a real-click fallback when the
    automatic dialog is refused (a gamepad press is never a user gesture), and
    reports a cancel back to the game.
  - Temporary pick paths are no longer remembered in options.
  - `Rom.lua` errors keep their pre-change text (`error(msg, 0)`).
  - The build script's generated-data guard no longer passes vacuously under
    `pipefail`.
- **Not yet verified:** audio output. Headless Chromium plays to a null sink,
  so whether music is audible and free of underruns is a Phase 3 check on a
  real browser.

## How the audit was done

- ROM unpacked and SHA-1 verified against the importer's table.
- Every shipped Lua file (`main.lua`, `conf.lua`, `src/`, `data/`, `mods/`,
  `tools/save-editor/`; 1,599 files) compiled with `luac5.1 -p` (PUC Lua 5.1
  is what love.js runs; there is no LuaJIT in WebAssembly).
- Pattern sweep for LuaJIT-only and native-only constructs (`ffi`, `jit`,
  `bit`, `goto`, `\x`/`\u{}` escapes, 5.2 `load`, `love.thread`, sockets,
  `io.popen`/`os.execute`, `love.timer.sleep`, shaders, canvases).
- Code read of the boot path, ROM import, main loop, audio, rendering, saves
  and networking.
- `ChipSynth` micro-benchmark under LuaJIT vs PUC Lua 5.1 (numbers below).
- `scripts/test.sh --group engine` run under both interpreters. It passes
  under LuaJIT. Under `lua5.1` + `lua-bitop`, 461 of the 467 suites that
  print a check summary pass. The hard errors are mostly the 5.2-style
  `load(string)` (B2, including `tests/love_stub.lua:248` itself), Gen 3
  modules, and tests that need `ffi`.
- Upstream check: LÖVE 11.5's `src/modules/love/love.cpp` preloads `enet`,
  `utf8` and LuaSocket behind build flags but **does not bundle a `bit`
  library**; without LuaJIT there is no `bit` unless the build adds one.

## Findings

### Blockers (Gen 1 cannot boot or import without these)

| # | Issue | Where | Fix |
|---|-------|-------|-----|
| B1 | **`require("bit")` has no fallback.** 133 call sites; LÖVE 11.5 only gets `bit` from LuaJIT. Gen 1 hits it in the extractor, the synth, sound, overworld and save code. | `src/import/RomExtractor.lua:1`, `src/core/ChipSynth.lua:13`, `src/core/Sound.lua:11`, `src/world/OverworldController.lua:3011`, `src/save_convert/*` | Compile Lua BitOp (`bit.c`, MIT, ~200 lines) into the love.js build and preload it as `bit`. A pure-Lua `package.preload.bit` shim is the emergency fallback only: it would be very slow in the synth inner loop. |
| B2 | **`load(string, name, mode, env)` is Lua 5.2 API.** PUC 5.1 raises `bad argument #1 to 'load' (function expected, got string)`, and the call is not `pcall`ed, so `Data:load` dies on every boot from the cache (verified under `lua5.1`). | `src/core/Data.lua:271`; ~20 more in `src/ui/game3/*` | Add `src/core/LuaCompat.lua`, required first by `conf.lua`/`main.lua`: on a runtime where `load` rejects strings, wrap it as `loadstring` + `setfenv(env)`. One shim fixes every site. The same pattern is already used in `src/link/Fingerprint.lua:460` and `src/mods/Sandbox.lua:204`. |
| B3 | **The main loop sleeps every frame.** `sleepUntilFrame` (`main.lua:1677-1687`, called at `:1788`) and the unconditional `love.timer.sleep(0.001)` at `main.lua:1790` block the browser's main thread; `pacingEnabled()` (`main.lua:1637`) only checks env vars and can't turn the 1 ms sleep off. The crash screen also sleeps (`main.lua:163`). | `main.lua`, `src/core/FrameCap.lua`, `src/core/PresentSync.lua` | Web branch in `love.run`: no sleeps, no `PresentSync`/`PresentProbe`, `FrameCap` pinned to DISPLAY. The returned per-frame function is already the shape love.js wants. `FixedStep` (60 Hz accumulator, `MAX_ACCUM=0.25`) already handles uneven rAF timing and tab-return dt spikes; on 120/144 Hz screens skip update/draw for early frames instead of sleeping. |
| B4 | **No way to get a ROM in.** On `"Web"`, `Platform.canSpawnProcess` is false, so `FilePicker` (`io.popen` dialogs) returns nil; the fallback `Kit.FileBrowser` uses `io.popen("ls")` and absolute paths (`src/ui/kit/FileBrowser.lua:113-135`); `love.filedropped` depends on love.js's SDL emitting `SDL_DROPFILE` (unverified). | `src/import/RomImporter.lua:1243-1279, 3308`, `src/core/Platform.lua:25` | Reuse the mobile bridge contract: `love.system.pickFile(kind)` opens a picker, the host writes `picked_rom.gb` + `pick_complete.flag` into the save dir, and `_pollPickedFiles` (`RomImporter.lua:3441`) → `findPendingRom` (`:1070`) → `startData` (`:2050`) takes over. On web, `pickFile` is a tiny C→JS bridge that clicks a hidden `<input type=file>` and writes the bytes with `FS.writeFile`; page-level drag-and-drop writes the same two files. Treat `"Web"` as `mobileFileBridge` in `RomImporter.new` (`:1527`). |

### Likely issues (works, but wrong, slow or fragile)

| # | Issue | Where | Fix |
|---|-------|-------|-----|
| L1 | **`\x` escapes are silently wrong in 5.1.** PUC 5.1 reads `"\xc3\x97"` as the literal text `xc3x97`. The `POKé` macro means every `#MON`/POKéMON in dialogue renders as `POKxc3xa9`. | `src/render/Font.lua:348`, `src/ui/StartMenu.lua:227`, `src/ui/ListMenu.lua:340` (plus ~25 Gen 2/3 files and one `"\u{25B7}"` at `src/ui/gen2/BattleState.lua:4621`) | Use decimal escapes (`"POK\195\169"`, `"\195\151"`). They are identical under LuaJIT, so this is safe to land on desktop now. Add a lint gate (below) so new ones can't creep in. |
| L2 | **Thread fallbacks only trigger when thread *creation fails*.** A build whose `love.thread` exists but never runs a thread would hang import (`_pumpExtract`, `RomImporter.lua:2225`) or leave music silent (`ChipAudio.ensureWorker`, `ChipAudio.lua:97`). | `RomImporter.lua:2119-2142`, `ChipAudio.lua:97-117` | Add a `Platform.hasThreads()` flag (false on Web) and gate both on it, so Web goes straight to the coroutine extractor and the synchronous synth. |
| L3 | **Audio CPU without JIT.** See the benchmark. Steady state is fine, but each song start renders 4 × 8192 stereo samples in one frame (`ChipAudio.lua:171, 228-240`), and an underrun refills a whole 8192 buffer at once (`:219-221`). Noise `clockNoise` does ~12 LFSR steps × 6-8 `bit` calls per sample (`ChipSynth.lua:924-958`). | `src/core/ChipAudio.lua`, `src/core/ChipSynth.lua` | Web → 22050 Hz (`selectSampleRate`, `ChipAudio.lua:603`, already does this for the LOW tier); prefill 1 buffer and spread the rest over frames; smaller buffers (2048-4096); table-drive the noise LFSR. |
| L4 | **Web Audio needs a user gesture.** The launcher splash video plays with audio at boot. | `src/import/LauncherSplash.lua:20`, `src/import/LauncherThemeVideo.lua:10` | Gate first audio behind a "click to start" overlay in the HTML shell; disable the splash and theme video on Web (Theora support in love.js is also unverified). |
| L5 | **Platform profile is missing.** `"Web"` currently falls into desktop defaults: `networkValidated=true` and `canFetchRemote=true` start the updater and curl fetch workers (`src/update/Check.lua:211`, `src/net/Fetch.lua:48`, mod index prewarm at `RomImporter.lua:1757`), and `update/Boot.run` (`main.lua:791`) tries a physfs ffi lookup. | `src/core/Platform.lua:7-41` | Add `web = osName == "Web"` with `hasThreads=false`, `networkValidated=false`, `canFetchRemote=false`, `canSpawnProcess=false`, `romImportMode="web"`. |
| L6 | **Window management.** `setFullscreen(true,"desktop")` and `love.window.setMode` run on boot and only skip Android/iOS/NX. Browsers allow fullscreen only inside a gesture. | `src/core/VideoMode.lua:22-42`, `src/core/FaithfulRes.lua:110-120, 212, 235`, `src/import/LauncherWindow.lua:66-75`, `RomImporter.lua:3554, 3623` | Add `"Web"` to both `fixedDisplay` checks; let the HTML shell size the canvas to the page; fullscreen via an HTML button. |
| L7 | **Performance tier auto-detect has no web case.** It probably lands on BALANCED by accident (the emscripten CPU count is 1). | `src/core/Performance.lua:100-123` | `if os == "Web" then return "low" end`. LOW already turns off TILT, survey zoom and SHADER FX and caps at 60 fps (`src/core/Game.lua:1462-1470`). |
| L8 | **SHADER FX cannot work** (librashader via `ffi.load`, native preset paths, desktop GLSL 1.20). It is pcall-guarded, but `ShaderFX.escalatePerformanceIfNeeded` (`src/render/ShaderFX.lua:1107`) pins HIGH if a preset is persisted. | `src/render/ShaderFX.lua:389-437, 521-525` | Force off and hide the option row on Web; add `"Web"` to `ShaderFX.defaultEs` and `LauncherView.cartShaderIsEs` (`src/import/LauncherView.lua:869`) so validation checks the ES dialect. |
| L9 | **`GbcPalette.remapShader` declares 128 `vec3` fragment uniforms.** WebGL1 only guarantees 16, and many mobile GPUs report ~64. It degrades to a non-shader fade, so it won't crash. | `src/render/GbcPalette.lua:110-133, 205` (used by the overworld fade at `src/world/OverworldController.lua:5784`) | `REMAP_MAX = 32` on Web, or pack the table into a texture. |
| L10 | **Return-to-launcher uses `love.event.quit("restart")`**, which ends the program under Emscripten. | `main.lua:1594-1610`, `src/core/HostShell.lua:267-337` | Add `"Web"` to `inProcessReturn` (`main.lua:1595`), as Android/iOS do. |
| L11 | **IndexedDB persistence.** love.js's MEMFS is lost on reload unless the save dir is IDBFS-mounted and `FS.syncfs` runs. An import writes ~600 files; saves are written as `.bak`/`.tmp`/main sequences (`SaveData.lua:877-990, 2585-2632`). | `src/import/CacheContract.lua` publish (`RomImporter.lua:2179`), `SaveData.save`, `saveOptions` | Mount IDBFS on the save dir in the shell and `syncfs(true)` before `Module` runs; `syncfs(false)` after import publish, after each save, and on `visibilitychange`/`pagehide` (via the same C→JS bridge, e.g. `love.system.syncStorage()`); request `navigator.storage.persist()`; offer `.sav` export so browser storage clearing can't silently delete a run. |
| L12 | **Import cost on non-JIT Lua.** SHA-1 is native (`love.data.hash`, `RomImporter.lua:252`). But Gen 1 runs 17 stages (`RomExtractor.lua:2392`), with per-pixel `setPixel` and `2^`/`floor`/`%` (`src/import/ImageWriter.lua:42-65`, ~1-1.5M pixels) and ~600 PNG encodes. `Rom:byte` builds an assert message string on *every* byte read (`src/import/Rom.lua:13-25`). Rough estimate: 10-40 s of compute, not measured. | `src/import/*` | Cheap wins first: only format the assert message on failure in `Rom.offset`/`Rom:byte`; precompute pixel lookup tables in `ImageWriter`. Then measure in the real build. The coroutine path already keeps the UI responsive. |
| L13 | **Payload size.** `pack_love.sh` packs every game: `src/` is 31 MB and `assets/` 27 MB (18 MB of that is `assets/labels`), and love.js preloads the whole `.love` into memory before running. | `scripts/pack_love.sh` | A `--profile web-gen1` exclusion list (Gen 3 `game3`/`gba`, non-Gen-1 labels, launcher videos), after confirming those requires are lazy. `scripts/split_web_build.py` already exists to chunk `game.data` past CDN per-file limits. |

### Fine as-is (checked)

- **Lua 5.1 syntax:** 1,593 of 1,599 shipped files compile under `luac5.1`. The 6 failures are all `goto` in `src/import/gba/*` (Gen 3, lazily loaded).
- **`ffi`:** every use is `pcall`-guarded with a fallback (`RefreshRate`, `PresentProbe`, `SaveData`, `ChipSynth` bulk writes, `CacheFs` mounts, `Orientation`, `PadHints`, `Gen1Tls`, `HostShell` (Windows-only), `DiscordPresence` (off for non-desktop)).
- **Rendering:** no depth buffers, MRT, instancing, compressed textures, float/r8 canvases, MSAA or mipmaps on the Gen 1 path. Canvases are default rgba8. `repeat` wrap is only used on power-of-two textures. Shaders (`PaletteFX`, `TileRenderer` key, `GbcPalette`, Tilt, `SurfingMinigame`, launcher cart hover) avoid `#version`, derivatives, `texelFetch`/`textureLod` and dynamic indexing, and are pcall'd with no-shader fallbacks. One exception is the launcher invert shader (`LauncherView.lua:3714`), which is not pcall'd; wrap it.
- **Cache and saves:** `CacheFs.write` uses `io.open` on paths under `getSaveDirectory()`, which works on Emscripten's libc/MEMFS; mkdir falls back to `love.filesystem.createDirectory` without ffi. `SaveSerializer` is deterministic Lua source with a 5.1-safe parser. There is no autosave timer, so all writes are user-triggered and easy to sync.
- **Mods:** the sandbox uses `loadstring`/`setfenv` and an injected `fs`, and denies `ffi`/`jit`. `SkinZip` already `pcall`s `bit`.
- **Online client:** `src/online/Client.lua` is pumped every frame but returns immediately while offline (`:1300`). LAN link (`src/link/Net.lua:28-31`) `pcall`s `enet`/`socket` and reports itself unavailable.
- **Timing:** `FixedStep` and the separate 60 Hz audio accumulator (`Game.lua:439-444`) work unchanged under rAF.

### Synth benchmark (PUC Lua 5.1 vs LuaJIT)

10 s of 3-channel chip music (2 pulse + noise) rendered through
`ChipSynth.soundData` on the plain `setSample` path (no ffi bulk writes),
native x86-64. Script: `bench/synth_bench.lua` (in the audit scratchpad, not
committed).

| Runtime | Rate | CPU per 60 Hz frame | Share of 16.7 ms |
|---------|------|--------------------:|-----------------:|
| LuaJIT 2.1 (JIT on) | 44.1 kHz | 0.17 ms | 1.0 % |
| LuaJIT 2.1 (`-joff`) | 44.1 kHz | 1.24 ms | 7.4 % |
| PUC Lua 5.1 | 44.1 kHz | 2.67 ms | 16.0 % |
| PUC Lua 5.1 | 22.05 kHz | 1.35 ms | 8.1 % |

PUC Lua is ~16× slower than the JIT here, and WebAssembly typically adds
another 1.5-2× on top, so expect roughly **4-5 ms/frame at 44.1 kHz** for
music alone, more with all four channels. The 4-buffer prefill on song
start is ~0.74 s of audio, roughly **150-250 ms in one frame** in the
browser: a visible hitch on every map or battle transition until L3 lands.
22.05 kHz halves the steady-state cost.

## Architecture decisions

1. **love.js (Davidobot fork; its `emscripten` branch is LÖVE 11.4), not a
   rewrite or a different runtime.** It is the only path that keeps the 770k-line Lua codebase as
   the single source of truth. Fengari (Lua in JS) has no LÖVE API; a
   bespoke WebGL renderer would fork the engine.
2. **Custom love.js build, pinned.** Needed anyway for B1 (`bit`). The same
   build adds the small `love.system` bridge (`pickFile`, `syncStorage`, and
   later `httpDownload`) via `EM_JS`, matching the contract the Android/iOS
   bridges already satisfy, so Lua barely needs to know it is on the web.
3. **Start with the compatibility (no-pthreads) build.** Every thread user
   already has a main-thread fallback (L2 makes that explicit), and the
   compat build needs no `SharedArrayBuffer`, so no COOP/COEP headers: it
   hosts anywhere (GitHub Pages, itch.io, gen1re.com). Revisit the pthreads
   build later only if the synchronous synth can't hold 60 fps on target
   devices; it would let `chip_worker.lua` run off-thread.
4. **Everything client-side.** The page ships code and bundled metadata
   only, exactly as `pack_love.sh` does today. The ROM is read in-browser,
   hashed, extracted, and dropped. The cache and saves stay in that
   browser's IndexedDB. Nothing is uploaded, and there is no server
   component for single-player.

## Plan

Each phase ends in something testable. Phases 0-1 are safe to land on
desktop immediately and benefit every platform.

### Phase 0: Lua 5.1 hygiene (desktop-safe, no web build yet) -- done

- `src/core/LuaCompat.lua`: a 5.2-style `load` shim for runtimes without it (B2).
- Replace `\x` escapes with decimal escapes, Gen 1 first: `Font.lua:348`, `StartMenu.lua:227`, `ListMenu.lua:340`, then Gen 2 (L1).
- CI gate in `.github/workflows/ci.yml`:
  - `luac5.1 -p` over shipped files, with an allowlist for the 6 known `src/import/gba` `goto` files;
  - a grep that fails on new `\x`/`\u{` escapes in string literals;
  - the ROM-free test groups run under `lua5.1` + `lua-bitop` alongside LuaJIT, for tests that don't depend on `ffi`.
- `Rom.lua`: format assert messages only on failure (L12).

**Exit:** CI green under both interpreters; desktop behaviour unchanged.

### Phase 1: `"Web"` platform profile (desktop-safe) -- done

- `Platform.lua`: add `web`, `hasThreads()`, and the flag values from L5.
- Gate `_startExtractThread` and `ChipAudio.ensureWorker` on `hasThreads()` (L2).
- Web branch in `love.run`: no sleeps and no present probing (B3).
- Add `"Web"` to `VideoMode`/`FaithfulRes` `fixedDisplay` (L6), `Performance.detect` → `low` (L7), `ShaderFX` off and `defaultEs` (L8), `inProcessReturn` (L10), and `DiscordPresence` (already off).
- `RomImporter`: treat Web as `mobileFileBridge` and route `choose()` to `pickFile` (B4 Lua side).
- Disable splash/theme video on Web (L4).
- A test that fakes `love.system.getOS() == "Web"` (the `tests/love_stub.lua` pattern) and asserts the profile, the no-thread routing, and that `love.run` never calls `love.timer.sleep`.

**Exit:** with the OS faked as Web, desktop LÖVE boots to the launcher, imports via the pending-file path, and plays without threads or sleeps.

### Phase 2: web build spike (Blue end-to-end) -- done

- `scripts/build_web.sh`:
  - `pack_love.sh` → love.js (custom build, pinned version, `-c`, `-m` sized from measurement; start at 256 MB with growth) → `split_web_build.py` → `scripts/web-theme/`.
  - Output to `dist/web/`.
- Custom love.js:
  - LuaBitOp preloaded as `bit` (B1);
  - `love.system.pickFile`/`syncStorage` bridge (B4, L11);
  - IDBFS mount of the save dir.
- HTML shell:
  - "click to start" (audio unlock, L4);
  - hidden file input plus page drop zone;
  - fullscreen button;
  - canvas sized to the viewport.
- Smoke test with the Blue ROM:
  - import completes, title screen, Pallet Town, first battle, save, reload page, continue.
- Measure:
  - import time;
  - steady fps;
  - per-frame synth cost;
  - song-start hitch;
  - memory high-water mark;
  - payload size.

**Exit:** Blue playable from import to first gym in desktop Chrome and Firefox; measurements recorded in this doc.

### Phase 3: performance and audio -- done (open items listed below)

Done so far (measured with `smoke_test.mjs --play` and a slow-frame profiler
build, Blue, headless Chromium):

| | Before | After |
|---|---|---|
| Main-thread stalls >50 ms in the scripted run | 9-10, worst 375-493 ms | 5-6, worst ~120-130 ms (game start) |
| Song start (sync path) | ~150-160 ms | 9-15 ms |
| First play of an everyday SFX | 40-150 ms | 0 ms (prewarmed) |
| Steady-state music synthesis | -- | ~2-2.5 ms/frame at 22.05 kHz |
| `game.love` / site | 26 / 32 MB | 16 / 21 MB |

- **Music:** on Web the synchronous path queues 2048-sample buffers and
  prefills one, instead of 4 x 8192. The per-tick slice runs 1.5x faster
  than playback drains, and the 32 queue slots still hold about 3 s.
- **SFX:** `ChipSynth.newEffectJob` renders an effect a slice at a time,
  sample-identical to `renderEffectData`. With no worker thread, ChipAudio's
  prewarm runs that on the main thread at 3 ms per update, into the same
  cache `newSfx` reads from. A play that arrives mid-render finishes the job
  instead of starting over. `Sound.prewarmCommon` queues the intro, Oak's
  speech and the everyday effects at game load. The title screen prewarms
  the cry of whichever Pokemon is showing, which also helps desktop through
  the worker.
- **Payload:** the web build drops the cart-label `.psd` sources (~14 MB, not
  loaded by any code) and the launcher videos.
- **Shaders:** the launcher's invert shader is now `pcall`-guarded. The
  GbcPalette remap shader stays at 64 entries: shrinking it would drop
  palette entries, and a GPU that rejects it already falls back to the
  non-shader fade.
- **Import:** no work needed; it takes about 4 s.

Second pass, attributing the remaining slow frames with a sampling profiler
built on an instruction-count hook:

- **Catch-up ticks compounded.** After a long frame, `Game:update` runs up to
  15 catch-up audio ticks back to back, and each rendered a music slice and
  ran the 3 ms prewarm pump, so one slow frame made the next one slow too. On
  Web both now run once per real frame (`ranThisFrame`). The low-water rule
  still renders a whole buffer if the queue actually runs short.
- **Load-time prewarm.** `Sound.prewarmCommon` now spends up to 120 ms of the
  game-load pause (`ChipAudio.pumpPrewarm`), so the intro's first effect is
  ready: `Shooting_Star` went from ~80 ms to 3 ms.
- **Oak's show-off cry** (NIDORINA in Red/Blue; it shows NIDORINO) is
  prewarmed by `OakSpeech` itself when the speech starts, ~50 s before it
  plays.
- **Sprite palette bakes run on the GPU on Web.** `SpriteRenderer`'s
  per-pixel `mapPixel` recolor cost 60-70 ms per intro sprite without the JIT.
  A shader with the same thresholds renders it once into a Canvas. Verified
  pixel-identical to the CPU bake in the browser for every intro sprite.
  Desktop keeps the CPU path.

Third pass, a scripted playthrough in the browser (persistent profile, so
each run continues from the last save). It covered the bedroom, the stairs,
Pallet Town, Oak's cutscene, the lab, choosing SQUIRTLE, the rival battle
(won, level 6), the party menu, Route 1 and a wild RATTATA battle:

- **Every Canvas was RGBA4 on WebGL.** LÖVE only trusts an RGBA8 render
  target on GLES2 when `OES_rgb8_rgba8` is reported. WebGL 1 guarantees it
  but never reports that name, so every Canvas, the 160x144 game canvas
  included, stored 16 levels per channel and banded the SGB palettes. Found
  because a GPU battle-picture bake came back quantized to multiples of 1/15.
  `patch_love.py` now lets RGBA8 render targets through on Emscripten.
- **`src/render/GpuBake.lua`** generalizes the GPU palette bake to all four
  per-pixel bakes on the Gen 1 path: overworld sprites (SpriteRenderer),
  battle pictures and their fade variants (BattleState), party icons
  (PartyMenu) and emote bubbles (OverworldController). A probe that redoes
  the CPU formula on the read-back source found 0 mismatched texels on every
  bake the playthrough hit. Web only; the CPU bakes stay as the fallback.

Still open:

- **The game-start transition** (title menu to overworld, ~120-130 ms once):
  creating the overworld controller and loading the map scripts. This is a
  one-time load at a menu transition. I tried shipping precompiled bytecode,
  built by Lua 5.1.5 compiled with emscripten so it matches wasm32's 4-byte
  `size_t`. Launcher boot only went from 1.3 s to 1.2 s, while `game.love`
  grew from 16 to 20.5 MB because bytecode with debug info compresses worse.
  Compilation isn't the bottleneck, so the build ships source.
- **Texture and canvas creation under software GL** (~40-60 ms each for the
  title's images, ~18 ms even for the launcher logo). This isn't Lua (heap
  size doesn't change) and isn't GC (a full collect of the ~18 MB heap takes
  ~21 ms). It should be far cheaper on a real GPU, but that's unverified.
- **Frame rate on real GPUs and audio quality.** Headless SwiftShader draws
  in software, which gives 43-60 fps at 960x720; Lua update plus draw is ~3 ms
  per frame. Audible underruns can only be judged on a real browser.
- **The 15 MB payload goal**: `game.love` is 16 MB.

Original plan:

- Audio (L3):
  - 22.05 kHz on Web;
  - 1-buffer prefill with the rest amortized;
  - 2048-4096-sample buffers;
  - table-driven noise LFSR;
  - pause or duck music on `visibilitychange` (rAF stops in background tabs and the queue drains anyway).
- Import (L12): `ImageWriter` lookup tables; profile and fix the top 3 stages.
- `GbcPalette` `REMAP_MAX` on Web (L9); pcall the launcher invert shader.
- Payload: a `--profile web-gen1` pack that excludes Gen 3 and non-Gen-1 assets (L13).

**Exit:**
- 60 fps on a mid-range laptop with music.
- No transition hitch over one frame budget.
- Import under ~30 s.
- First-load download within a target size, e.g. ≤15 MB compressed.

### Phase 4: product polish -- done

Done:

- **Phone touch controls.** The overlay turns on at the first real touch,
  because phone browsers report "Web". Verified on an emulated phone: the
  overlay's A button advances the game.
- **Saves.** "Export save" downloads the `.sav`, and "Import save" goes
  through the page picker. The start card says storage is per-browser, and
  the page calls `navigator.storage.persist()`.
- **Controls hint** on the start card. The Fullscreen button sits clear of
  the touch controls and fades when idle. URL launch options (`?game=blue`).
- **Red and Yellow verified** against their canonical US dumps with the full
  browser smoke run (import, play, save, CONTINUE in a new tab), like Blue.
- **Gamepads verified** with an emulated standard-mapped gamepad: A advances
  the title, the D-pad moves the menu cursor.
- **Audio.** The page resumes suspended AudioContexts on any gesture (for
  iOS Safari). The smoke test logs every buffer OpenAL schedules and showed
  continuous music: 83 s covered across ~950 non-silent buffers, with one
  scripted song-change pause.
- **Docs:** docs/platforms/web.md, linked from the README.

Original list:

- Mobile browsers: `TouchControls`, orientation, iOS Safari audio unlock, safe areas.
- Save export/import as `.sav` downloads/uploads (the save converter already handles formats). Show a "browser storage can be cleared" notice and call `navigator.storage.persist()`.
- Gamepad API (love.js maps it to joysticks; verify the mappings in `GamepadMap.lua`).
- Red and Yellow verification (same importer, different manifests).
- Docs: `docs/platforms/web.md`, README Quick Start row.

### Phase 5: release pipeline -- done

- **`.github/workflows/web.yml`** builds the site on pushes and PRs, runs the
  ROM-free browser smoke test, uploads the site as an artifact, and deploys to
  GitHub Pages on a manual run with "deploy" ticked (see ports/web/BUILD.md).
- **The `web` job in `release.yml`** builds from the same version-stamped
  `game.love` every other platform ships (`build_web.sh --love`), smoke-tests
  it, and publishes `gen1recomp-<version>-web.zip` with the release, covered
  by `sha256sums.txt`.
- **Verified locally:** a fully clean `build_web.sh` takes 4m42s, and its site
  passes the full smoke run with Red, Blue and Yellow.

Original list:

- `web` job in `release.yml`, built from the shared `love-payload` artifact.
- Deploy to GitHub Pages or gen1re.com (static hosting; no COOP/COEP needed for the compat build).
- Playwright smoke in CI (Chromium is available on the runners):
  - the page boots to the launcher with no Lua error;
  - ROM-free, so no ROM in CI;
  - a ROM-backed run stays local or uses a private cache, like the existing T3 tier.

### Post-phase-5 audit -- done

Two review passes (web/CI layer, Lua changes) after phase 5. Fixed:

- **Build/CI:** a pin bump over a restored cache now force-checks-out and
  cleans the patched tree; emsdk's PATH no longer leaks into packaging; a
  serial `make` retry covers megasource's parallel `libz.a` race; PR builds
  also trigger on `data/`, `assets/` and `pack_love.sh`; a push no longer
  cancels a hand-started (deploy) run; the release smoke retries once.
- **Page:** the picker bar is keyboard-reachable (SDL ate Tab/Enter/Space)
  and Escape cancels it; a dialog cancel always closes it; a file dropped
  before Start no longer navigates away; errors after Start show on a banner
  (no more `alert()` on context loss); the Fullscreen button is hidden where
  fullscreen doesn't exist and uses the webkit API on older Safari; the
  "Already open" tab starts by itself once the other closes; love.js
  download failure is reported.
- **Bridge:** a synchronous `FS.syncfs` throw can't wedge the sync
  coalescer; download blob URLs live 40 s.
- **Audio:** `ranThisFrame` counts real frames (`ChipAudio.beginFrame` from
  `love.run`) instead of a 4 ms window a slow tick could outlast; the
  prewarm queue advances with no music playing; rate/stereo/mix changes drop
  in-flight main-thread renders (no mixed-rate PCM under a stale key); the
  restart/rebuild paths prefill one buffer on Web; title/Oak cry prewarms
  and the 120 ms common-SFX pump are browser-only and first-load-only.
- **Misc:** throwaway GPU-bake source images are released; a throwing drop
  handler still cleans up its `/tmp` copy; the version rail's lerp fraction.

### Later (not in the first release)

- **Online play:** `Client.configure{ connect = fn }` (`src/online/Client.lua:1174`) already accepts an injected transport. Implement send/poll over a browser WebSocket (one JSON line per text frame), and put a WebSocket endpoint or a websockify-style proxy in front of the relay. Alternatively, Emscripten's socket emulation turns LuaSocket TCP into WebSocket connections automatically, which may need no Lua change at all once the relay speaks WS.
- **Mod catalog:** implement `love.system.httpDownload` in the bridge with `fetch()` (requires CORS on the mod index host), then flip `canFetchRemote`.
- **Gen 2:** fix the remaining `\x` escapes; measure.
- **Gen 3:**
  - remove `goto` from 6 importer files;
  - move ~20 `load` sites onto the shim;
  - the GBA PPU compose shader uses 7 samplers, at WebGL1's guaranteed limit of 8;
  - several game3 shaders aren't pcall'd;
  - stencil in the pokedex;
  - likely needs the pthreads build for its workers.

## Risks and open questions

- **love.js specifics to verify in the Phase 2 spike:**
  - whether its SDL emits `SDL_DROPFILE`;
  - whether it already mounts IDBFS for the save dir, and when it syncs;
  - whether Theora video is compiled in;
  - `QueueableSource` behaviour under the compat build (the README warns of "dodgy audio" there);
  - whether `love.filesystem.mount` of save-dir subfolders (`CacheFs.mountVersion`) is accepted.
- **User-activation window:** opening the file picker from inside the game loop relies on the browser's transient activation surviving from the click until the next rAF tick. That works in Chromium and Firefox; Safari may need the HTML-side button.
- **Storage eviction:** browsers can clear IndexedDB under storage pressure or by user action. Persistent-storage requests and save export mitigate this; they don't eliminate it.
- **Performance floor:** low-end Chromebooks and phones may not hold 60 fps with music on PUC Lua. The fallbacks are the LOW tier, 22.05 kHz (or 11.025 kHz) audio, and ultimately the pthreads build to move synthesis off the main thread.
- **Distribution:** same rules as the desktop app. The page must never bundle or fetch ROMs or generated data, and the import flow stays SHA-1-gated to the canonical dumps.
