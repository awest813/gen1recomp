# Web voxel audit — October 8, 2026

Work lives in the attached `web-voxel-audit` worktree, based on
`origin/claude/brave-wozniak-nz47bk`, which contains the web port.
The original checkout and downloaded ROM/save files were left untouched.
The preview is local; these changes have not been deployed.

## Changes

- Browser mod downloads now explain the ZIP import step. Re-importing an
  installed mod offers a replacement prompt, pins the validated mod ID,
  preserves enable settings, and retains picker input until confirmation.
- The drop overlay includes mod ZIPs.
- Renderer reinitialization releases its retained tilt canvas.
- Split web payloads use four concurrent requests, timeouts, exact byte-count
  validation, and abort on failure. Invalid templates are rejected before
  deleting build data; part numbers above 999 work correctly.
- `ports/web/patch_voxel_mod.py` creates a separate, locally patched
  PotatoVoxel 1.9.6 ZIP. It validates the exact upstream source patterns and
  preserves the original archive and art. Three changes:
  - Shadow support probes reuse the active canvas resolution instead of
    repeatedly allocating the first resolution and replacing it afterward.
  - Web terrain builds skip optional persistent mesh-cache writes, which
    flatten and duplicate the largest Lua arrays. Existing cache reads remain.
  - Web quality presets persist their eight options once, after updating all
    values. Native behavior stays unchanged.

## Browser verification

Tested in the Codex Chromium browser, at 1280×720, using locally imported
Blue and an existing save from Downloads. Imported data and mods survived
reloads. The rebuilt payload booted successfully through 15 one-MiB chunks.

Battle Art Voxel Fork 1.11.1 was found through FIND and downloaded through
its web catalog flow. Standard camera angles, first person, and OFF rendered.
Experimental third person produced an obscured dark view at the test location;
it is not validated as usable. Snapshot page FPS varied roughly 35–54 in the
standard voxel views; cold startup had a multi-second stall.

PotatoVoxel 1.9.6 was installed through MODS. The initial shadow-only patch
still failed while building ROUTE_2 (`not enough memory`) and left a black
screen. With the final patch, the controlled Pallet Town → Route 1 transition
rendered and ROUTE_2/body completed its background build in about 10 seconds
without reproducing that error. This is a single-map regression check, not
a whole-game memory guarantee.

OFF, HIGH, MEDIUM, LOW, and POTATO were cycled in browser; all rendered.
CUSTOM matching and persistence were verified with the headless quality probe.
The 3D wild battle path also rendered and returned to the overworld.

Before save batching, observed quality changes stalled for about 2.8–4.4 s.
After batching, MEDIUM/LOW/POTATO switches showed worst page-frame intervals
around 0.6–0.8 s. Setting trace timestamps for all eight values spanned only
4–12 ms after batching. These are observations from interactive testing,
not statistical benchmark results. Remaining work includes startup and mesh
build slices that exceed their budget; steady FPS varies with scene and mode.

The page FPS meter measures browser animation frames. Mod diagnostics also
showed steady frame averages around 17–22 ms in several patched scenes, with
occasional larger spikes. Do not interpret a single screenshot as guaranteed
60 FPS. A prior Chromium storage UnknownError was logged during earlier tests;
its cause has not been isolated.

## Validation

- Split-loader Python tests: 3 passed, including Node checks for concurrency,
  ordering, truncation, oversize, network failure, timeout, HTTP errors, and
  part number 1000.
- ZIP patcher Python tests: 2 passed; original/archive metadata and unrelated
  entries are preserved, and unsafe/unsupported destinations are refused.
- LuaJIT checks: ZIP install 47/47, shadow-copy installation 18/18, replacement
  UI callback 10/10, session teardown 35/35, web profile 49/49, touch activation
  5/5. POSIX temporary-directory commands in the ZIP test were replaced by
  precreated Windows test directories in the local runner.
- Shadow probe: original code allocated 720 extra canvases over 120 steady
  frames; patched code allocated zero.
- Quality probe: one options save per web preset, eight on native; all values
  preserved and a changed quality knob selects CUSTOM.
- `git diff --check` passed.

## Reproduce the mod patch

```text
python ports/web/patch_voxel_mod.py ORIGINAL_1.9.6.zip potato-web-fixed.zip
```

Import the output using MODS → Import mod .zip. Accept Replace when the
original mod is installed. Enable only one voxel renderer for the selected
game. PotatoVoxel uses `8` to cycle OFF/HIGH/MEDIUM/LOW/POTATO; Battle Art uses
`3` for its camera ladder. The patcher supports exactly PotatoVoxel 1.9.6.
Use the separate original ZIP to restore upstream code through the same
replacement flow.

Generated builds, test ROMs, mods, and screenshots remain under ignored
`dist/`; they are not repository assets. Browser proof:
`dist/web-voxel-proof.jpg`.

## Follow-up: actual web render pacing

The browser loop previously drew on every animation callback regardless of
MAX FPS. It now uses nonblocking deadlines for 30 and 60; UNLOCKED draws on
every callback. Input, fixed-step updates, audio, and storage service continue
on every callback. Native display synchronization retains its existing path.
The web MAX FPS ladder is 30 / 60 / UNLOCKED. The optional `?fps=1` meter now
counts completed game renders separately from page animation callbacks.

The pacing probe passes 34 checks, including jittered 60/120/144/240 Hz hosts,
cap changes, clock reversal, and stalls without catch-up bursts. The web-loop
integration suite passes 61 checks: at 120 Hz, 240 callbacks produce 60 draws
at 30, 120 draws at 60, and 240 unlocked draws, with all 240 updates retained.
Native cap/display tests pass 49 checks and the legacy-loop suite passes 16.

Red and Yellow were imported from the user's Downloads ZIPs. Extracted ROM
hashes match the supported Red, Blue, and Yellow releases. Yellow reached its
title screen at approximately 30 actual rendering FPS. Blue's loaded voxel
scene ran around 30 at the 30 cap. Switching the in-game MAX FPS row to 60
and UNLOCKED changed the actual rendering rate and diagnostic label correctly.
This browser host runs near 60 Hz; faster-host behavior is covered by the
headless pacing tests, not an actual high-refresh browser measurement.

At the 60 cap, a stationary medium-quality Pallet scene had one-second samples
around 42–59 FPS. Lower quality improved some samples to about 60, but Route 1
later varied around 43–49 unlocked. These observations do not demonstrate a
locked 60 FPS. Quality changes still produced roughly 0.8–1.0 second stalls.
The controlled Pallet-to-Route-1 crossing rendered successfully with a
167 ms worst page interval at the sampled crossing. Startup still stalls.

Additional ROM-independent regression checks passed: timing parity 192,
fixed-step catch-up 5, Yellow starter 24, old man 29, gifts 14, rival-loss text
24, Oak/Pikachu back pictures 24, and advanced palettes 21. The timing fixture
logs expected missing POOF_ANIM/overworld-transition warnings. Passing fixtures
and boot screens are not a full Red/Blue/Yellow gameplay accuracy certification.

Browser evidence is under ignored `dist/`: `yellow-30fps-boot.jpg`,
`blue-60fps-voxel.jpg`, `blue-unlocked-voxel.jpg`,
`blue-route1-unlocked.jpg`, and `web-pacing-test-logs.json`.
Red also reached its title screen at roughly 60 FPS with UNLOCKED selected
(`red-unlocked-boot.jpg`).

Optional `?fps=1` diagnostics now log average/worst update and draw durations
once per second. Initial lower-quality Pallet samples at the narrower browser
viewport showed roughly 3–5 ms average updates and 8–11 ms average draws,
with occasional draw spikes of 33–39 ms. These CPU-side timings include
presentation but are not separate GPU measurements. The meter's sizing was
adjusted to avoid unnecessary wrapping on narrower desktop views.

ZIP dependency checks now honor the MODS game scope and persisted enable
flags. ID-only update callbacks resolve the full installed manifest, so
forward dependencies are checked instead of silently skipped. Manifest tests
pass 118 checks, update-all 154, and command-line update regressions 60.

## Remaining coverage

The public catalog inventory was scanned at commit
`25576b0de03d556a538d8a6d12027ac5408d3af7` (242 entries).
Besides the two installed renderers, candidates include Terrarium,
Voxel Ascendant, Voxel Dex, Kanto Ascendant, and compatible weather/follower/
flying/UI add-ons. Catalog metadata can lag releases: Terrarium's current
release was 1.30.1 and Voxel Ascendant's was 3.0.62 when checked. Those renderer
versions had not yet been installed at that point; the Terrarium follow-up
below supersedes that status. Voxel Dex's
DRAMATIC_SHAPE dependency and external model requirements still need checking.
The published feed currently lists 193 mods; refreshing it still did not list
Terrarium or Voxel Ascendant. Their metadata directories are candidates for
follow-up, not proof that FIND currently exposes them. Voxel Pokédex 1.0.0 was
downloaded through FIND and imported. Its resolver correctly reports missing
DRAMATIC_SHAPE with no repository hint. The add-on is disabled for Red/Blue/
Yellow until that dependency is supplied or compatibility is implemented.
Its source supports a sprite-card fallback when a Stadium model cache is
absent, so the N64 asset pack is not required merely to open an entry.

The overall goal remains open: broaden renderer/game coverage, inspect visual
accuracy (including vegetation obscuring the Route 1 entrance), isolate mesh
and settings-change stalls, and measure sustained gameplay at 60 FPS. The two
installed renderers must be tested individually; simultaneous world renderers
conflict. Red and Yellow currently have both disabled for vanilla baselines;
Blue had PotatoVoxel enabled and Battle Art disabled. The Terrarium follow-up
below supersedes Blue's active renderer.

## Terrarium follow-up

Terrarium 1.30.1 was fetched from its official GitHub release
(`BrenoBertucci/Terrarium`, tag `v1.30.1`) and imported through MODS. The browser's
direct GitHub asset download was blocked; `gh release download` fetched the
same official asset locally, which was then imported through the port.
Original archive: 44,023,567 bytes, SHA-256
`c13769b3278934da7060295e23a6748d24d92dea2f7c6f643e6c0b0ae5af91f0`.
Original downloads are preserved; local patched ZIPs are ignored under `dist/`.

Three distinct problems were separated:

1. Emscripten 2.0.0's generated OpenAL vector play/pause/stop passed numeric
   source IDs to a helper expecting source objects. On crash cleanup, Stopv
   then failed reading `bufQueue.length`, masking the original Lua error.
   `scripts/patch_web_openal.py` repairs all three calls after packaging,
   including cached native builds. The browser now reaches the engine's own
   crash screen, with no OpenAL JavaScript exception.
2. Terrarium requires the removed `src.render.GBCFX` module when toggling its
   voxel camera. Its local ZIP patch caches a protected lookup and uses a
   no-op only when the legacy module is absent. Old engines retain the effect
   call; current engines have no obsolete pass to disable.
3. All four Terrarium shader fallback variants failed linking. A temporary
   diagnostic in the generated runtime revealed the actual error:
   `Precisions of uniform 'swellPhase' differ between VERTEX and FRAGMENT shaders.`
   The ZIP patch gives the 36 shared numeric uniforms matching
   `LOVE_HIGHP_OR_MEDIUMP` precision. The actual browser now renders the 3D
   scene, buildings, characters, shadows, trees and minimap. The temporary
   console instrumentation was removed. `scripts/patch_web_gl.py` also fixes
   generated runtime status/log queries after failed linking, so future
   failures retain their diagnostic instead of an empty linker error.

Blue currently enables Terrarium alone among the installed world renderers;
PotatoVoxel and Battle Art are disabled for Blue. Terrarium, PotatoVoxel,
Battle Art and Voxel Dex are disabled for Red and Yellow. Other game scopes
were left as installed. The original DRAMATIC_SHAPE repository referenced by
Terrarium's README returned 404 via GitHub's API; Voxel Dex remains disabled
for the Gen 1 tests because its donor dependency is unresolved.

Terrarium's OFF/15/35/50/75 camera cycle rendered and wrapped successfully.
The Pallet-to-Route-1 crossing reached ROUTE_1 at (10,35), but produced a
7,810 ms worst page interval. Vegetation obscures the character and path at
the entrance. Stationary 3D samples were roughly 30–40 FPS at the 1280×720
browser viewport, with average draw costs around 19–42 ms and updates around
7–11 ms. These measurements do not demonstrate locked 60 FPS.
The mod also logs failed wild-roamer/town-life derived sprite loads; those
features fall back for the session and still need compatibility repair.

The first performance repair targets the cooperative build budget. On PUC
Lua, the engine's yieldable `pcall` runs protected code in a child coroutine.
Terrarium's `coroutine.running() == buildCo` guard therefore ignores its
deadline inside protected uploads. The patch uses the active begin/finish
scope, which already brackets one synchronous pump resume and its children.
The real downloaded BuildBudget plus the engine's real LuaCompat reproduces
the original missed yield; the patched version yields and resumes correctly.
Outside the pump, calls remain inert. Browser retesting is described below.

Python patch/loader tests pass 13 cases, including Lua 5.1 protected-call
behavior, source/archive preservation, runtime format refusal, OpenAL object
dispatch, and failed/linked WebGL program queries. The local runtime now loads
as `love.js?g1r-runtime=2` to invalidate the earlier browser cache.

Evidence: `dist/terrarium-3d-working.jpg`,
`dist/terrarium-route1-before-budget.jpg`,
`dist/terrarium-shader-link-logs.json`, and
`dist/terrarium-3d-before-budget-logs.json` (ignored).

The budget-fixed ZIP was imported and retested at the same 1280×720 viewport,
15-degree camera, and Route 1 entry coordinate (10,35). It builds and renders
successfully, but the crossing still had a 7,527 ms worst page interval.
The engine profile attributes 7,404 ms to the worst draw and 122.1 ms to the
worst update in that crossing's sample. The budget repair therefore does not
solve the dominant transition stall. Initial upload/draw spikes still occur;
settled samples varied and did not establish locked 60 FPS. Next profiling
should time the work triggered from VoxelScene's draw path, especially
new-map textures, tree batches and mesh uploads, before changing it.
Evidence is `dist/terrarium-after-budget-logs.json` and
`dist/terrarium-route1-after-budget.jpg`. The temporary viewport override was
reset after comparison, and Blue was returned to Pallet in working 3D mode.

### Tree draw analysis repair

Temporary draw-stage profiling attributes 8,217.8 ms on the first Route 1
frame to trees and lamps. Detailed tree timings show drawing starts uncached
Structures analysis for distant neighbours: Cinnabar Island takes 3,151.6 ms
and Viridian City 790.7 ms on the first Pallet frame. Tree uploads independently
take roughly 0.4–1.9 seconds per map and remain a performance problem.

The Terrarium ZIP patch now makes the draw-only tree lookup use
Structures.peek. An unfinished analysis returns without caching a permanent
absence; the next frame retries. Explicit synchronous probe/build APIs retain
Structures.forMap. This avoids duplicating the terrain builder's analysis
from draw while its coroutine is still in progress. The regression verifies
120 cold draws start no analysis, a later ready cache renders, empty sites
remain terminal, and explicit probes still build.

The clean, non-instrumented `TERRARIUM-1.30.1-web-trees-fixed.zip` was imported
through MODS and reached Route 1 (10,35) at the matched 1280×720 viewport.
Worst draw in the crossing interval was 1,395.4 ms, compared with 8,217.8 ms
in the profiled baseline. The actual boundary frame's profile reported a
60.7 ms worst draw; a later mesh upload still stalls. Update spikes of up to
660.5 ms also remain. This is one crossing, not proof of sustained 60 FPS.
All 11 Python runtime/mod patch tests pass, the four patched official Lua
files compile under Lua 5.1, and `git diff --check` passes.

Ignored evidence: `dist/terrarium-tree-analysis-before.json`,
`dist/terrarium-after-tree-analysis-fix.json`, and
`dist/terrarium-route1-tree-analysis-fixed.jpg`. Temporary profiling ZIPs are
not the installed final patch. Remaining scope includes all voxel mod/game
accuracy, sustained 30/60/unlocked behavior, easy build/hosting, stability for
ordinary users, then a complete launcher UI/UX overhaul plan.

### Cooperative tree and vertex uploads

The ZIP patch now runs browser tree stamping and finalization in a coroutine
with a 1 ms budget per map draw. Large browser vertex-table uploads allocate
the original-sized mesh and replace 256 vertices per call, checking the
active build budget between calls. The mesh stays unpublished until its
vertices and index map finish. It retains the original one-mesh-per-species
draw layout, positions, shades, textures and shadow geometry. Native builds
retain the original stamping/upload path. Index-map conversion and GPU
allocation are still atomic and need further profiling.

The clean `TERRARIUM-1.30.1-web-upload-fixed.zip` was imported in MODS. Browser
logs confirm forests finished: 205 trees on Cinnabar, 234 on Pallet, and 364
on Route 1, each in one mesh. They take more frames to appear (316, 364 and
557 respectively), which is a remaining usability tradeoff. There were no
tree-build failure reports. At the matched 1280×720 viewport, the first
Route 1 boundary sample reports worst draw 62.9 ms and worst update 116.5 ms;
the following sample reports worst draw 41.9 ms. A later wild Rattata battle
exposed a separate worst update of 1,995.8 ms and later draw spikes near
150 ms. The 3D battle appeared, Run succeeded, and the overworld returned.
These results do not prove sustained 60 FPS or whole-game accuracy.

All 13 runtime/mod patch tests pass. New probes verify vertex equality on
Web and native, yielding through protected child coroutines, complete-only
tree publication, and failed-build retirement. The four patched official
Lua files compile. Evidence: `dist/terrarium-upload-fix-logs.json` and
`dist/terrarium-upload-fix-proof.jpg` (ignored). Next performance work should
isolate the battle-start update stalls, remaining index uploads, and settled
draw cost. Roamer compatibility, player visibility and battle HUD alignment
remain accuracy/usability work.

### Roamer sprite compatibility

The compatibility filesystem previously called tostring on LÖVE FileData and
ByteData, storing an object description instead of PNG bytes. LegacyCompat
now reads Data:getString for filesystem write/append and File:write. Failed
Data conversion returns an error before overwriting a file. Eight binary
round-trip checks pass under both Lua 5.1 and LuaJIT, including embedded zero
and high bytes, length-limited append, file handles and failed conversion.
The existing sandbox suite passes all 99 checks.

Terrarium's RoamerArt wrote fallback sheets through the compatibility overlay,
then returned their old save/mod-derived path to the engine's Assets.image,
which reads the real filesystem. The ZIP patch now uses mod.cache:write with
encoded PNG bytes and returns the matching mod_cache/<id>/roamers path. Its
legacy path remains available on engines without mod.cache. The cache probe
checks the exact bytes and image path and releases the temporary encoded data.

The rebuilt local web runtime includes LegacyCompat. The clean
`TERRARIUM-1.30.1-web-roamers-fixed.zip` was imported through MODS and Blue
loaded into Pallet. A town Pokémon is visibly present and the previous wild
roamer / town-life sprite-load failure reports are absent. This proves the
PNG load path is repaired, not all species or encounter behavior. Initial
entry still has a 5,779 ms page interval, and subsequent samples remain slow:
new sprite baking and remaining update work need profiling. Fourteen Python
runtime/mod patch tests pass; source diff checks pass.
Evidence: `dist/terrarium-roamers-fixed-proof.jpg` and
`dist/terrarium-roamers-fixed-logs.json` (ignored).

### Stationary shader and resolution checks

The ZIP patch now replaces 177 protected shader sends with a helper that
caches uniform presence independently for each shader. Unused uniforms are
skipped; active values are still sent on every call, including changing model
matrices. Missing-uniform false returns and protected send errors retain the
original fallback behavior. Engines without hasUniform retain protected sends.
The presence cache uses weak shader keys so retired variants are collectible.
The API reports optimized-out uniforms as absent:
[LÖVE Shader:hasUniform](https://www.love2d.org/wiki/Shader%3AhasUniform).

Fifteen Python runtime/mod patch tests pass, and all five modified official
Lua files compile under Lua 5.1. A broader compile check found two unmodified
upstream probe files with syntax errors; these are outside the runtime patch.
The clean `TERRARIUM-1.30.1-web-uniforms-fixed.zip` was imported through MODS.
Blue loads, town Pokémon remain visible, camera modes cycle through the flat
mode and back to 3D, and FULL / 1/3 / 1/4 resolution changes render without a
restart. Tests used the natural 714×692 viewport with LOW shadows and PFX ON.

This has not demonstrated a substantial steady-frame speedup. Before the
cache, stationary half-resolution draw samples ranged roughly 31–57 ms.
Afterward, half-resolution samples remain roughly 34–44 ms when settled;
FULL samples are roughly 47–58 ms with larger spikes. One-third resolution
samples start around 25–32 ms but later reach 57–66 ms. These are observed
windows, not controlled averages: background work and timing variance remain.
The flat mode produces draw samples around 1.6–2.1 ms, helping isolate the
remaining cost to the 3D path. Initial entry still has a 4,796 ms page interval.
Sustained 60 FPS remains unverified and unmet in these voxel scenes.

Quarter-resolution draw samples range roughly 30–51 ms. Half resolution was
restored after testing. Walking toward Route 1 triggered a wild Rattata;
the introduction reaches a 2,058.7 ms worst update with further 1.2–1.5 second
update stalls. Run succeeds, restores the 3D overworld, and the player reaches
the Route 1 sign/ledge. The enemy HUD still clips at the left edge, and tree
canopies obscure the player on the entrance path. These remain actionable
accuracy/usability issues. Evidence: `dist/terrarium-uniform-quality-logs.json`,
`dist/terrarium-uniform-route-logs.json`, `dist/terrarium-full-quality-proof.jpg`,
and `dist/terrarium-uniform-route-proof.jpg` (ignored). The next performance
pass should profile the settled 3D draw sections and battle update work.

### Enemy HUD padding and section profiling

The fallback HUD band was shifted left by eight GB pixels to put its panel
at the window edge. The clean ZIP patch now retains the full band at x=0,
preserving leading padding for the name and HUD shake. Bounds checks cover
320×288, 714×692, 1280×720 and portrait 360×640. Sixteen Python runtime/mod
patch tests pass. Visual battle confirmation of this correction is pending.
The separate clean output is `TERRARIUM-1.30.1-web-hud-fixed.zip`.

An ignored temporary diagnostic ZIP added per-section timing to VoxelScene.
Recent settled samples attribute about 10–15 ms to terrain/actors/grass,
8–20 ms to trees/lamps and 8–13 ms to shadows. Final scene upscale is around
0.15–0.23 ms; these samples make it a lower priority than scene submission.
The runtime also experienced much slower windows, including launcher frames,
so these are not controlled benchmark averages. Evidence is in
`dist/terrarium-draw-sections.json`.

The diagnostic session stopped producing game render/update logs during a
walk, leaving a black canvas while the independent page RAF stayed live.
The captured logs contain no explanatory error. This is an unresolved
stability observation, not proof that a battle rendered or that the HUD
correction works visually. `dist/terrarium-diagnostic-stop.jpg` records it.
Restore the clean HUD ZIP before repeating the walk; do not distribute the
temporary section profiler.

Recovery was verified: the local launcher boots, and MODS reports Installed
TERRARIUM after replacing the diagnostic ZIP with the clean HUD ZIP. The
browser is left at MODS for further testing. Evidence:
`dist/terrarium-clean-hud-installed.jpg` (ignored). No test walk was saved.

### Per-pass uniform upload cache

The browser ZIP now compares numeric, string and boolean uniform arguments,
including flat vectors/matrices, against snapshots within each scene pass.
Unchanged values skip the native upload. Changed tables are compared by their
contents rather than object identity, opaque image/Data resources bypass the
cache, and failed sends retry. The cache resets at beginScene, preserving
public-shader writes between passes, and tracks shaders separately. Native
builds retain uploads. All 177 ordinary sends and six active-shader sends
share the helper so effect toggles cannot bypass it.

Seventeen Python runtime/mod patch tests pass; all six modified official Lua
files compile under Lua 5.1. The behavior probe reduces 120 identical model
and sway uploads to two calls in one pass, then verifies matrix mutation,
effect reset, shader switching, failed sends, opaque resources, pass reset
and native behavior. The clean output
`TERRARIUM-1.30.1-web-value-cache.zip` was imported through MODS.

Blue loads and moving sprites, town Pokémon, lights and camera changes render.
Recent stationary draw samples remain around 40–60 ms; this is not yet a
demonstrated frame-rate improvement. Initial entry reports a 3,214 ms page
interval, with prior derived sprite caches already present, so it cannot be
compared directly to a cold entry. The launcher’s 15 FPS idle throttle was
traced to main.lua, not a changed gameplay setting.

A Rattata battle renders with the complete enemy name and left padding,
visually confirming the HUD correction in the browser’s 714×692 viewport.
The battle advances through Hydro Pump, faint and EXP text, and returns to
Route 1; the 3D camera is restored afterward. Battle rendering remains inside
update work (recent samples about 34–185 ms), so a fast draw log alone does
not prove smooth battle FPS. No test progress was saved. Evidence:
`dist/terrarium-value-cache-logs.json`, `dist/terrarium-value-cache-proof.jpg`
and `dist/terrarium-cache-battle-after.jpg` (ignored). A controlled cache
on/off comparison is still needed before claiming a performance gain.


### Timed uniform-cache comparison and rollback

An ignored diagnostic ZIP toggled only the per-pass value cache every 20
seconds while Blue remained stationary at Pallet in the 714x692 viewport,
35-degree camera, half resolution, Low shadows and post effects enabled.
The captured interval spans about 170 seconds and eight mode transitions.
Excluding the first 20 seconds and samples within two seconds of transitions,
nearest-time matching of profile intervals gives 59 cache-on and 58 cache-off
samples. Median draw time is 49.82 ms on versus 34.39 ms off (means 49.92 and
41.14 ms). Update medians also vary (18.16 versus 12.61 ms), so this is a noisy
browser comparison, not an isolated CPU microbenchmark.

Median sends fell from about 2,299 to 627, with 1,664 skips per frame, but the
Lua comparison/snapshot overhead did not deliver a frame-time improvement.
The value cache and its pass reset were removed from the distributed patch.
Uniform presence caching remains, including all six active-shader sends.
The original official archive is preserved; a fresh clean output is
`TERRARIUM-1.30.1-web-clean.zip`. The diagnostic archive is not a release.
Evidence: `dist/terrarium-cache-comparison.json` (ignored).

Sixteen runtime/mod patch tests and three split-loader tests pass after the
rollback. Both web and release CI jobs now run these checks with pinned Lupa
and an explicit Lua 5.1 import before building. Remote CI has not yet run on
these uncommitted changes. The proposed launcher overhaul is recorded in
[web-launcher-overhaul.md](proposals/web-launcher-overhaul.md); implementation
and all-game/mod/locked-60 acceptance gates remain open.


The clean ZIP was installed through the replacement dialog, retaining the
Blue enable state, then Blue's original save loaded into the 3D Pallet scene.
All six patched Lua files compile under Lua 5.1. The browser menu cap was
cycled through 30 (30.0 actual rendered FPS), 60 (58.8-60 actual rendered FPS)
and back to Unlocked. This checks selection/application in a light menu,
not locked voxel gameplay or game-timing accuracy. No test walk was saved.
Recent clean-world draw samples vary from about 45 to 89 ms, confirming the
large remaining performance gap. Evidence: `dist/terrarium-clean-overworld.jpg`
and `dist/terrarium-clean-overworld-logs.json` (ignored). Workflow regression
step placement was reviewed; a full remote workflow run remains pending.

## Voxel Ascendant 3.0.62 browser follow-up

Verified the official release at
https://github.com/Roxas2712/voxel-ascendant/releases/tag/v3.0.62.
The browser asset click did not produce a local file; GitHub CLI fetched the
same complete ZIP, then MODS imported it. No assets were stripped. The archive
is 482,324,707 bytes, 31,404 entries and 789,226,918 uncompressed bytes.
SHA-256 matches the official receipt:
`4b7e444de690ca20336996ddb72636b5ad20d6128a12001b7e089049c0124de3`.
No required dependencies; Kanto Ascendant and other integrations are optional.
Blue enables Voxel Ascendant alone among installed renderers. Red/Yellow are
disabled for baseline tests; other scopes were retained.

Import succeeds and survives reload, but logged a 23,692 ms worst update and
23,931 ms page interval. A subsequent window showed a 7,294 ms page interval.
Large-package startup/storage need profiling; installation alone does not
meet the usability gate.

Initial launch failed compiling lib/VoxelScene.lua, which starts with a UTF-8
BOM. Two official Lua files have this encoding, also gen2/lib/BattleScene.lua.
Sandbox.compile now removes a leading BOM before compilation AND bytecode
validation. Sandbox.loadFile handles BOM source through the same compiler.
Environment bindings and ordinary filesystem loading are retained; internal
BOM bytes are preserved, and BOM-prefixed bytecode is refused. Tests pass in
PUC Lua 5.1 and LuaJIT; the SDK sandbox suite passes 99/99. Seventeen Python
source/runtime/mod tests and three split-loader tests pass. The rebuilt
browser confirms the original unmodified Ascendant archive loads successfully.

Compared the baseline payload to tracked source after newline normalization:
only the seven already-repacked edited files differed before adding Sandbox.
The existing mouse-event fix is present. Some short automated clicks missed
launcher toggles while 150 ms presses worked; no new input fix is claimed.

Blue's original save loaded through Ascendant's start screen. Optional sprite
download prompts were canceled; the appearance wizard was deferred with Save
draft / later. Loading reported Save validation needs attention, then A
dismissed the animation and preparation/wizard screens led to the overworld.
Entry recorded 30.91 seconds with a 7.168-second maximum frame. This sequence
needs clearer progress/recovery behavior.

At 714x692, Pallet renders buildings, rain, vegetation, NPCs and replacement
characters. OFF/15/35/50/75/1ST/3RD camera modes respond and wrap. Third person
is blocked by house geometry at the save location, so it is not validated as
usable. Voxel, Cobble and 2D/original character selections switch. Two short
movement steps work but reveal a separate native-looking player image one
cell behind the replacement character, persisting after movement settles.
This was initially classified as an actor-alignment/render-ownership defect;
the follow-up below corrects that classification. Observed 3D snapshots are around 18-24 FPS, with slower
switches. Battle, map transitions, quality, Red/Yellow and sustained 30/60
checks remain open. No test progress was saved.

Ignored evidence: dist/voxel-ascendant-first-world.jpg,
dist/voxel-ascendant-third-person.jpg, dist/voxel-ascendant-alignment.jpg and
dist/voxel-ascendant-logs.json.

## Ascendant follower diagnosis and 30 FPS target

User priority is now steady 30 FPS; 60 FPS remains a later target.
Temporary full-package diagnostics logged every posed actor and disabled
the occlusion-silhouette pass. The extra figure remained visible. Logs show
one SPRITE_RED player and a distinct SPRITE_PIKACHU follower one cell behind,
with matching player native/render coordinates at rest. The mod's integrated
follower runtime deliberately clones SPRITE_MONSTER when optional species
walksheets are absent. This is generic follower artwork, not a duplicate
player or evidence of a render-ownership defect. Optional follower artwork
and flat-mode character appearance still need separate accuracy checks.
The complete official ZIP was restored through MODS; diagnostic logging and
the disabled silhouette pass are no longer installed.

The startup LOAD REPORT says the save was made with zero mods and one is
newly active. The earlier "Save validation needs attention" wording is not
evidence of save corruption. A clean replacement again paused the page for
about 23 seconds (22,548 ms worst displayed interval).

Controlled Blue transitions into the player's house and back to Pallet
succeeded with the original renderer and follower. Interior snapshots
reached about 51 FPS unlocked, and outdoor snapshots about 31-40 FPS.
No test movement was saved. MAX FPS was then set to 30 through VIDEO options.
Nineteen one-second capped samples, including menu exit and movement, had
median 26.6 FPS and range 9.4-30.1; this is not steady 30 FPS. Recent voxel
draw averages were about 23-29 ms and update averages about 5-10 ms, leaving
insufficient frame budget in slower windows. Flat mode at the same location
visibly reached 30.2 rendered FPS with a 60 Hz page and 17 ms worst interval.
Mode switches cause separate transient stalls. The built-in graphics check
was started with the economy/mobile device profile selected in the draft;
recommendations must be reviewed before claiming any quality improvement.

Ignored evidence: dist/vasc-follower-ghost-disabled.jpg,
dist/vasc-clean-indoor.jpg, dist/vasc-30fps-voxel.jpg,
dist/vasc-30fps-voxel-logs.json and dist/vasc-30fps-flat-logs.json.

The graphics check reached the battle-lighting phases, then stopped with
"Window size changed. Please test again at your preferred size." All paired
effect verdicts observed were uncertain (drift, stalls, scenario coverage or
insufficient samples), so no completed benchmark result is claimed. Reviewed
and applied the draft: 720p, shadows OFF, AA OFF, SKY water reflections and
world/battle extra lighting OFF. The complete official package remains installed.
Afterward, Route 1 movement still showed 22.6-28.8 FPS snapshots. Later windows
approached 30, but a Rattata encounter dropped sharply; its faint/experience
messages subsequently rendered around 14-23 FPS. This does not meet steady
30 FPS. No test game progress was saved.

Source inspection finds OverworldBattle.update called from the pipeline
update hook, where updateBattleFrame resolves actor textures and calls
BattleScene.render. The render cap currently gates love.draw, so it does not
directly throttle this presentation work in updates. Profile windows during
the encounter/fixture sequence show roughly 26-36 ms update averages with
1-3 ms draw averages. Next separate battle presentation cadence from gameplay
updates, then compare the same warmed scene; do not reduce simulation rate.
The optional lighting benchmark fixtures and actual encounter are different
workloads and should not be combined into a steady-world measurement.
Ignored evidence: dist/vasc-30fps-light.jpg and
dist/vasc-30fps-light-logs.json. Source/runtime regression tests remain 17/17
passing; git diff --check passes.

## Web battle presentation cadence

Added ports/web/patch_ascendant_mod.py for the exact 3.0.62 release. It creates
a separate full ZIP, changing only lib/OverworldBattle.lua and adding
lib/WebBattlePresentation.lua. All original asset CRCs are retained; output
is 482,325,488 bytes. After retirement checks and covered preparation, a Web
battle with a committed shot reuses that shot between capped presentation
deadlines. Visual dt accumulates across skipped callbacks. New battler/mon
identities force a fresh shot. Native, unlocked and uncommitted preparation
retain their existing behavior; simulation is outside this limiter.
The complete paced archive was installed through MODS with enable flags kept.

Nineteen Python source/mod/runtime tests pass, including Lua 5.1 and LuaJIT
cadence probes (30 shots from 120 callbacks), elapsed-time conservation,
cap changes, new mon ownership, hitches, unlocked and native paths. Both
actual patched Lua sources compile in both runtimes. CI's existing test glob
covers the new tests; a remote workflow run remains pending.

Blue loads, Route 1 movement works, and temporarily disabling Custom wild
Pokemon permits a native Rattata encounter. The MAP battle renders both
battlers and command/move UI. Warm windows include 30.2, 26.8, 29.2, 30.3,
29.6, 30.3, 29.8 and 30.1 FPS, with update averages around 16-20 ms in several
of those windows; later samples drop to 24-27 FPS. Cold/deployment phases
remain slower, and this is not a matched-scene before/after benchmark or proof
of steady 30. A pointer action intended for RUN did not produce a verified
escape; do not treat coordinate battle controls as validated. No test battle
progress was saved. Custom wild Pokemon still needs restoring to ON after
profiling. A temporary local-only VASC_LOCAL_TIMING_PROBE was installed to
read the existing in-memory runtime evidence via render.hud; its first
version used an event instead of that hook and was corrected. Remove it
when measurement is complete.

Ignored evidence: dist/vasc-paced-battle.jpg and
dist/vasc-paced-battle-logs.json. Next use the timing breakdown to identify
remaining capture/render cost, restore the temporary encounter setting and
remove the timing probe before broad accuracy/performance claims.

## Current 30 FPS work

Custom wild Pokemon was restored to ON, and the local timing probe was
disabled for Blue and then removed through MODS. Its recoverable ZIP and
logs remain in ignored dist/. No test game progress was saved.
The recorded Pallet windows attribute most measured work to VoxelScene.render
(for example 1,138.8 ms total across 47 calls, 1,000.6 ms self), with both
render-cost spikes and unattributed waits. The probe printed many evidence
lines and may itself have introduced stalls; it is not a clean benchmark.

With the probe removed, fixed 720p world samples include 26.1–30.1 FPS.
Applied a 50% scene-resolution trial, preserving shadows OFF, AA OFF, SKY
reflections and extra world/battle lighting OFF. Several consecutive windows
reach 30.0 FPS with 16.5–20.9 ms average draw costs, but other windows fall to
20.5–26.6 FPS. Resolution alone does not establish steady 30 FPS.

Fresh web sessions now default to 30 FPS; saved 60/unlocked choices and native
60 defaults are preserved. Added completed-frame mean/worst interval and late
interval counts to ?fps=1 logs. Late means over 125% of the selected frame
budget, allowing normal RAF jitter; average FPS alone does not prove stability.
Pacer behavior checks pass 43/43 in both Lua 5.1 and LuaJIT. Native display
and legacy-loop suites pass 49/49 and 16/16, web profile 61/61, Python patch
tests 19/19, split loader tests 3/3, and git diff --check passes.

Rebuilt the local payload and its 15 split parts. An ordinary reload retained
old diagnostics in the browser, while the served ZIP contained the new source.
An ignored steady30.html entry with a versioned game.js URL loaded the new
meter: launcher windows report ~33.3 ms mean and 0/31 late frames. This is
launcher validation, not a voxel gameplay stability claim. General build
asset cache invalidation still needs a production solution.

Ignored evidence: dist/vasc-local-timing-final-logs.json,
dist/vasc-30fps-half-resolution.jpg and
dist/vasc-30fps-half-resolution-logs.json.

The new meter also runs in the voxel world: 29.8–30.2 FPS windows still
contain 3–5 late intervals and worst intervals of 43.9–69.7 ms. A later
window contains a 920.7 ms interval and 906.6 ms worst update. This confirms
that near-30 averages alone hide the remaining instability.

Added scripts/patch_web_idbfs.py to the build. The pinned runtime's synchronous
local file inventory now processes at most 64 entries per task, yielding
after about 2 ms. Actual IndexedDB reconciliation remains unchanged. ENOENT
for an asset deleted between tasks is skipped; other failures retain the
callback error path. Node verifies exact 31,406-entry timestamp inventory,
bounded batches, completion exactly once, deletion during scanning, empty
directories and errors. Version guards/idempotence pass. All Python patch
tests now pass 21/21; generated love.js syntax and diff whitespace checks pass.
The shell runtime URL advances to version 3 so this runtime update can load.

The patched runtime boots the existing Blue ROM/save and installed mod list.
Controlled Blue VASC OFF/ON writes finish with Blue enabled again. Those
launcher actions still have 514.5/572.3 ms update peaks, so this scan patch
must not be represented as having eliminated all storage/launcher stalls.
Later idle launcher windows use the existing 15 FPS idle cap. No save progress
was written. Ignored evidence includes dist/vasc-30fps-frame-time-before-storage.json,
dist/vasc-30fps-storage-test-logs.json and dist/vasc-30fps-storage-test.jpg.

Final patched-runtime Pallet rain sample boots and renders the 50% scene
normally. Recent windows report 29.7–30.1 FPS, 17.7–21.0 ms average draw cost
and 3.5–4.9 ms average update cost. Completed-frame worst intervals remain
40.9–53.3 ms, with 0–9 late intervals per ~30 frames. The short sample is
near 30 FPS but still not perfectly steady, and is not a matched A/B proof.
Evidence: dist/vasc-30fps-storage-world.jpg and
dist/vasc-30fps-storage-world-logs.json. The test tab is left available with
the patched build running; gameplay progress remains unsaved.

## Follow-up audit and polish

The web VIDEO page no longer offers window mode, faithful window resolution
or VSYNC controls that the browser ignores. Layout controls and MAX FPS remain.
The menu regression suite now checks the actual web submenu and cycles its
30/60/unlocked values while retaining native controls (69/69 LuaJIT checks).

Build assets now share a content-derived version ID across game.js, love.js,
love.wasm and data requests. Split part names preserve URL queries and subpaths.
The stamper validates the complete template before writing and is idempotent.
Python patch tests pass 23/23; split loader tests pass 3/3. Generated game.js,
love.js and inline page scripts pass Node syntax checks.

The debug overlay distinguishes completed render FPS, completed-frame maximum
interval/late count, and page callback FPS/maximum interval. Render readings
expire after three seconds. Clock rollback resets pacing diagnostics, preventing
an old measurement epoch from contaminating new samples (45/45 checks under
both LuaJIT and Lua 5.1). The loop profile suite passes 61/61 under both runtimes.
The full menu suite was run under LuaJIT; standalone Lua 5.1 lacks its required
bit library in this local test environment.

The local split build was repacked and stamped as 27a6eef59be2e152. Browser
startup verifies that the versioned runtime and split payload load successfully
and that the three-line overlay is readable at the natural 714px viewport.
This audit does not establish perfectly steady 30 FPS; startup and game-loading
stalls remain visible.

Live Blue/VASC gameplay resumes in Pallet. The web VIDEO submenu visibly has
four working entries: UI LAYOUT, SCREEN POS, MAX FPS (30), and LOGIC CLOCK
(60Hz). No settings or gameplay progress were saved during this check. Recent
world samples include 28.9–30.0 FPS with maximum intervals of 43.5–63.6 ms;
these are short observations rather than a controlled performance comparison.
Proof: dist/web-audit-polish-video.jpg. The test tab remains available in the
voxel world.

## User-facing error recovery

Web picker cancellation is now a distinct bridge result. Cancelling ROM,
save, mod, importer, required-source, skin or cart selection clears routing
state and shows neutral cancellation feedback. Real read failures retain
their error details; native TV file-manager failure behavior is preserved.
Focused LuaJIT checks pass 36/36 and the existing TV cancellation suite 9/9.

Missing engine/data-loader downloads, synchronous boot exceptions and runtime
aborts now provide Reload rather than leaving Loading/Starting stuck. Fatal
page/graphics errors offer Reload; banners also have Dismiss, with keyboard
events isolated from game controls. Graphics loss feedback no longer promises
that unsaved progress is retained. Simultaneous same-name file drops receive
unique staging paths, preventing one file from overwriting another.

The real shell event handlers pass Node-backed recovery/drop tests, including
download failures, late loader completion, boot exceptions, runtime abort,
Escape dismissal, read failures and concurrent same-name file contents.
The complete Python patch suite passes 24/24. Inline JS syntax and diff checks
pass. Local final build ID: e3c975e8ace8f513.

Browser verification: an intentionally missing engine in an isolated temporary
page displays an enabled Reload button and explanatory message. The temporary
tab was closed. The final build boots normally with the existing Blue import
and save. Save-picker cancellation visibly displays “Import cancelled.” and
leaves the loaded save intact. No file was imported and no save progress was
written. Proof: dist/web-error-recovery.jpg and dist/web-import-cancel.jpg.

## Base-game audit without mods

Blue was booted with the launcher's temporary safe mode enabled, preserving
individual mod choices. The classic title/continue screens, loaded Pallet
world, party list, field-move action menu, both Pokémon summary pages, item
list, Town Map, house entry/exit and Pallet-to-Route-1 scrolling were checked
live. Text, level-100 stats, move PP and submenu returns displayed correctly.
No gameplay progress was saved. A live wild battle did not trigger in the
short movement sample, so in-browser battle verification remains incomplete.

Source audit found that Gen 1's Start-menu save confirmation ignored the
write result and always claimed success. It now reports SAVE failed and
waits for acknowledgment on a false/nil result or thrown storage exception.
Confirmed writes retain the success message, save sound and normal closing
behavior. The focused failure/success suite passes 20/20 checks.

Related regressions pass: Start cursor 6/6, party cancellation 10/10, bag
cancellation 42/42, Town Map cursor 14/14, warp sprite visibility 19/19,
wild encounter cooldown 88/88 and battle menu scaling 28/28 (LuaJIT).
The local payload is rebuilt with the actual updated StartMenu source,
verified byte-for-byte; build ID 8254ea3d25b531d2. Diff checks pass.
Proof of unmodded Route 1: dist/base-game-route-audit.jpg.

The test session returned to title and then the launcher without saving.
Safe mode was restored to OFF and visibly verified; individual mod toggles
were not edited. The launcher still lists NICK at 255:39 with 8 badges and
151 caught, matching the starting save. The rebuilt source is available on
the next page reload; this live gameplay audit used the preceding build.
