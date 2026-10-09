# Web launcher overhaul plan

Status: proposed implementation plan, 2026-10-08. The browser port is the
primary target. This plan does not certify all games/mods or locked 60 FPS.
See [current audit](../web-voxel-audit-2026-10-08.md) and
[build/hosting instructions](../../ports/web/BUILD.md).

## Outcomes and current constraints

An average player should import a supported game, continue a save, install a
compatible voxel mod and recover from a failed launch without understanding
engine internals. Today Games, Mods, Find, settings and save actions spread
these tasks across several screens. The game selector uses an initial and a
caret; installed mods display broad game enable counts even when the selected
Gen 1 game is disabled. Tall cards push important actions below the viewport.
The canvas UI also needs a deliberate accessibility strategy.

Keep import validation, queued actions, touch deduplication, per-game enable
state, save export and browser storage safeguards as implementation contracts.
LauncherView paints importer state; do not create a second independent copy
of that state in a new presentation layer.

## Navigation and core screens

| Area | Primary content and actions |
| --- | --- |
| Library | Red, Blue and Yellow named cards; Continue or Play; import game; visible active mod profile and last save |
| Game details | Saves, game information, active profile, controls and repair actions; unsupported files explain the supported choices |
| Mods | Installed and Discover tabs; search, compatibility filters, install/update progress, dependency resolution and per-game enable state |
| Saves | Current save, other slots, import/export and recovery; trainer, play time, badges and modification time |
| Settings | Graphics, controls, audio, accessibility and storage; advanced options collapsed |
| Help | First-play guide, input reference, storage explanation, troubleshooting and exportable diagnostics |

Use a labeled navigation rail on wide screens and a compact labeled bottom
bar on small screens. Keep Play/Continue visible without scrolling. Library
is the default destination; remember game/profile selection across reloads.
Move experimental online and skin features into secondary navigation with
clear availability labels. Avoid icon-only controls for essential tasks.

## Main journeys

1. **First play:** Start unlocks audio, then the empty Library offers Import
   game. Browse and drop share validation and progress. Show the detected
   version before extraction, then Ready and Play. Unsupported/corrupt input
   gets a specific explanation and Try another file. Never imply that the
   engine download includes a game.
2. **Continue:** A game card names the save and active profile. Continue loads
   that save directly. New game is a separate action and cannot overwrite a
   populated slot silently. A return to Library retains the selection.
3. **Voxel setup:** Discover shows measured browser compatibility per version
   and game. A details panel lists required dependencies and known limits.
   Install resolves required mods together, then offers Enable for Blue (or
   the selected game). Conflicting world renderers get an explicit profile
   choice. Installed, Enabled and Tested are distinct states.
4. **Update:** Preview version and affected profiles before replacement;
   preserve enable state/options. Validate the replacement before publishing
   it; keep a recoverable previous version where storage permits. Failure
   leaves the working version selected and offers retry.
5. **Save recovery:** Import previews target game/slot. Export remains one
   visible action. Explain that browser storage is device/site specific.
   Show Saving, Saved locally or Save failed from actual flush results.
   On startup, offer valid backups when the main save cannot load.
6. **Failed launch:** Show a readable cause, Return to Library, Retry and
   Launch without mods. A temporary recovery launch must preserve the user's
   normal profile. Diagnostic export includes versions and errors, with a
   preview; it excludes game files and save contents by default.

## Graphics and performance UX

Offer 30 FPS, 60 FPS and Unlocked as explicit independent selections.
Rendering caps must not change the game's simulation rate, animation rules,
input, audio or save timing. Preserve the selected cap through profile and
quality changes. Describe 60 as a target until measured release gates pass.

Quality presets expose resolution, shadows and effects together with an
Advanced panel. Explain visible tradeoffs and allow Reset. Apply changes as
one transaction; avoid writing settings once per individual control.
Optional performance information shows actual rendered FPS and stalls, not
only browser callback rate. Heavy scene preparation has progress and keeps
input/UI responsive; prevent partially built geometry hiding the player.

## Accessibility and presentation

Use readable type, consistent spacing, high contrast and states distinguishable
without color. Every essential action needs a visible label, focus indicator,
keyboard route and controller route. Support touch without hover or long-press
requirements and generous targets. Reduced motion removes decorative movement.

Prototype Library/import/mod details at 360x640, 714x692 and 1280x720 before
implementation. Validate long names, translated text, large text and empty,
loading, failure and success states. For screen readers, expose a semantic
HTML companion for launcher controls backed by the same importer commands;
keep focus and announcements synchronized with canvas navigation. Evaluate
this prototype before committing to a full HTML launcher migration.

## Implementation phases and acceptance gates

| Phase | Work | Acceptance gate |
| --- | --- | --- |
| 0: stability | Finish game/mod matrix, save persistence, frame pacing and build checks | Reproducible supported-version results; no silent save loss; known failures documented |
| 1: prototype | Library, import, game details, mod details, settings and recovery mockups | First-play/continue/mod/recovery tasks work with keyboard and touch at all three sizes |
| 2: foundation | Shared commands/state adapters, navigation, focus, status/progress components | Existing queued-action/touch dedup contracts retained; no duplicate imports or installs |
| 3: Library/saves | Game cards, continue/new-game separation, backup/export/recovery | Reload preserves saves; failed flush surfaced; overwrite and backup recovery verified |
| 4: Mods/settings | Catalog, dependencies, profile conflicts, updates and graphics presets | Failed installs retain working state; enable flags/options survive replacements; cap preserved |
| 5: accessibility | Semantic companion, controller mapping, responsive and localization polish | Complete journeys with keyboard, touch/controller and screen reader; no unreachable actions |
| 6: release | Static-host package, quick-start, diagnostics and clean-profile tests | Fresh artifact boots/imports/persists on supported browsers; package carries no user game/save files |

For each supported Red/Blue/Yellow version and claimed voxel mod combination,
verify introduction, save load, maps/transitions, collision/visibility,
battle HUD/animations, audio and return to overworld. Compare game behavior
against the corresponding unmodified game, using reproducible scenes.

A locked-60 release claim requires sustained actual rendered 60 FPS in a
specified browser/device at the stated quality, including representative
battle and map transitions; report warm and cold stalls separately. Verify
30 and Unlocked preserve game timing. Current Terrarium measurements fail
this gate, so performance work precedes the claim.

Release the UI phases independently behind a preview option until their gates
pass. Keep the existing launcher available for rollback during migration.
