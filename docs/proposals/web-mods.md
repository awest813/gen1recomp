# Mods in the browser build: test results and fix plan

Status: phases 1 and 2 (engine side) done; phase 3 is for the mod authors. Companion to
[web-port.md](web-port.md). Tested in headless Chromium against
`dist/web` (Blue unless noted), each mod alone, driven from the overworld
into a wild battle.

## Results

The baseline with no mods runs at 40 fps in the overworld and 40 fps in
battle.

| Mod | Version | Result | Notes |
| --- | --- | --- | --- |
| Crystal 251 | 0.12.0 | Works | Imported the required ROM through the mod card in the browser (MD5 checked, "Ready"). It extracts on first boot in about 10 s, then runs Gen 2 battles with gender, damage and Crystal sprites at about 31 fps. The white boxes behind battle sprites come from the mod forcing palette colour 0 to pure white (`main.lua`), not from the web build. |
| Gen1Follower + Player Sprite Flip | 1.8.0 / 0.1.0 | Works | 39–41 fps. |
| Terrarium | 1.30.1 | Loads, one handler fails | It requires `src.render.GBCFX`, which this engine has never had, so its `save.created` handler errors on every platform. Not a web issue. |
| Voxel Dex | 1.0.0 | Blocked by a dependency | It needs `DRAMATIC_SHAPE` (the original Dramatic Shape Voxel Mod), which wasn't installed. The loader says so clearly. The dependency couldn't be fetched from the test sandbox. |
| PotatoVoxel | 1.9.6 | Renders, slow | Its 3D overworld and battles render. Two problems were found and fixed: the page hung (phase 1) and a shadow canvas thrash (phase 3, upstream). What's left is GPU-bound in a software renderer (see below). |
| Battle Art Voxel Fork | 1.11.1 | Renders, slow | The 3D overworld renders and the battle transition starts. It is GPU-bound: the main thread is 86–88% idle at about 1 fps, even with a 320×240 viewport. |
| Voxel Ascendant | 0.1.7 | Not tested | It is a 482 MB download. A synthetic 300 MB mod now installs (phase 1). |

### What the profiles showed

- **"attempt to yield across C-call boundary"** came from the voxel mesh
  builders. They run in coroutines and call `pcall` inside them; PUC Lua 5.1
  can't yield through `pcall`, while LuaJIT can.
- **Page hang (PotatoVoxel).** The browser's love.js build has
  `love.thread`, but its workers never start. The mod waited on a channel
  forever.
- **30% of the main thread in `glGetError` (PotatoVoxel).**
  - A named-symbol wasm build traced 97% of it to `Canvas::loadVolatile`.
  - A `newCanvas` call counter traced that to `ShadowMap.available()`. It
    probes `getCanvas(SIZES[1])`, which rebuilds the shadow canvases (colour,
    sprite and depth) at the smallest rung, and then `fit()` rebuilds them at
    the rung it wants. That happens every frame whenever the two differ.
  - Under the Brick profile, which the mod uses on web and Android, `SIZES`
    is `{512, 768, 1024}` and the fit picks 1024. The result was about 6
    canvas allocations per frame, each with two synchronous `getError` calls
    and a framebuffer status check.
  - Patching that one line in the installed copy dropped creation from
    1000+ in two minutes to 6 in total.
- **GPU-bound.** With the thrash gone, both voxel mods leave the main thread
  82–88% idle. The time goes to the GPU, which in the test sandbox is
  SwiftShader (software). These numbers say nothing about a real GPU.
- **Large mods.** The installer read the whole zip into a Lua string and
  copied it again into a `FileData`. A 300 MB zip grew the wasm heap to its
  2 GB limit and failed with "not enough memory". The heap never shrinks
  afterwards.

## Plan

### Phase 1: engine fixes (done, this repo)
- Mod sandbox: `pcall`/`xpcall` are yield-safe inside a mod's coroutine on
  PUC Lua 5.1 (`LuaCompat.coPcall` / `coXpcall`). `goto` is rewritten to a
  5.1 form at compile time (`LuaCompat.rewriteGoto`).
- `love.thread` is hidden from mods where threads never run, so mods take
  their headless fallback instead of waiting forever.
- love.js patch 6: `Canvas` filter/wrap calls skip renderbuffer canvases,
  which ends a per-frame WebGL "no texture bound" warning flood.
- Mod zip install on web streams the picked or dropped file into the save
  directory in 1 MB chunks and path-mounts it. 300 MB now installs with a
  766 MB heap peak and survives a reload.
- Dropped: skipping `Buffer::load`'s `getError` drain made no measurable
  difference, so the error check stays.

### Phase 2: measuring on real hardware (this repo, small; done)
- Done: a `?fps=1` page option that overlays frames per second and the worst
  frame, measured by the page itself, so the voxel mods can be judged on
  real GPUs, phones included.
- Done: files over 8 MB are copied out of a mod archive in 1 MB chunks too.
  The same 300 MB install now peaks at 531 MB of heap (766 MB before).
- Still to do, needing a real browser: try Voxel Ascendant (482 MB) and
  Voxel Dex with `DRAMATIC_SHAPE`, and read `?fps=1` with each voxel mod.

### Phase 3: upstream mod fixes (mod authors; patches below)
- **PotatoVoxel** `lib/ShadowMap.lua`, in `ShadowMap.available()`:
  ```lua
  -- probe at the rung already allocated instead of rebuilding at SIZES[1]
  if getCanvas(canvas and canvasRes or ShadowMap.SIZES[1]) == nil then
  ```
  This affects the Brick profile on Android as well as the browser.
- **Battle Art Voxel Fork** keeps the desktop shadow ladder (`1024/1536/2048`)
  in the browser. It allocated 1024², 1536² and 2048² maps. A web/mobile
  profile like PotatoVoxel's Brick would suit it.
- **Terrarium** requires `src.render.GBCFX`, which doesn't exist in this
  engine. It should guard the require with `pcall` or drop it.

### Phase 4: engine guard rails (this repo, medium, optional)
- A development warning when one mod creates more than N canvases or images
  in a second. PotatoVoxel's thrash cost a profiler session to find, and a
  one-line warning naming the call site would have shown it immediately.
  The `newCanvas` counter used here (wrap `love.graphics.newCanvas`, key by
  `debug.getinfo(2, "Sl")`) is the starting point.

## Not web issues

These were seen while testing and also happen on desktop:
- Crystal 251's white sprite boxes.
- Terrarium's missing `GBCFX`.
