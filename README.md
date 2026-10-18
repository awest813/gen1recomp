# G1R Deluxe

G1R Deluxe (Gen1Recomp) is a native [LÖVE](https://love2d.org) recreation of Pokémon Red, Blue, Yellow, Gold, Silver, Crystal, FireRed, LeafGreen, Ruby, Sapphire, and Emerald. The engine is hand-written Lua, ported from the [pret](https://github.com/pret) disassemblies. Graphics, audio programs, and game data are decoded on your machine from a ROM you already own. This repository does not include a ROM, does not emulate the Game Boy, and does not download a disassembly.

<p align="center"><img src="assets/logo/logo.png" alt="G1R Deluxe"></p>

> [!CAUTION]
> This project is not affiliated with `gen1recomp.com`. That site is not run by this project, was not authorized to speak for it, and has hosted adware. Do not download anything from it. The official sources are this GitHub repository, the [Discord](https://bois.icu), and <https://gen1re.com>.

<p align="center">

<a href="https://bois.icu"><img src="https://img.shields.io/badge/Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord"></a>
<a href="https://www.youtube.com/@bryanthaboi"><img src="https://img.shields.io/badge/YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white" alt="YouTube"></a>
<a href="https://www.tiktok.com/@bryanthaboi"><img src="https://img.shields.io/badge/TikTok-000000?style=for-the-badge&logo=tiktok&logoColor=white" alt="TikTok"></a>
<a href="https://x.com/bryanthaboi"><img src="https://img.shields.io/badge/X-000000?style=for-the-badge&logo=x&logoColor=white" alt="X"></a>
<a href="https://bsky.app/profile/bryanthaboi.live"><img src="https://img.shields.io/badge/Bluesky-0285FF?style=for-the-badge&logo=bluesky&logoColor=white" alt="Bluesky"></a>
<a href="https://www.instagram.com/bryanthaboi"><img src="https://img.shields.io/badge/Instagram-E4405F?style=for-the-badge&logo=instagram&logoColor=white" alt="Instagram"></a>

</p>

<p align="center">
<a href="https://www.polygon.com/pokemon-red-blue-3d-voxel-mod-battle-pixels-gameplay-footage-remake/"><img src="https://img.shields.io/badge/AS%20SEEN%20ON-POLYGON-ea2e49?style=for-the-badge" alt="As seen on Polygon"></a>
<a href="https://kotaku.com/pokemon-red-blue-recompilation-project-voxel-3d-mod-2000720281"><img src="https://img.shields.io/badge/AS%20SEEN%20ON-KOTAKU-ea2e49?style=for-the-badge" alt="As seen on Kotaku"></a>
<a href="https://www.digitalfoundry.net/news/2026/07/pokemon-yellow-voxel-mod-turns-the-original-gameboy-code-into-a-stunning-world"><img src="https://img.shields.io/badge/AS%20SEEN%20ON-DIGITAL%20FOUNDRY-ea2e49?style=for-the-badge" alt="As seen on Digital Foundry"></a>
<a href="https://www.androidauthority.com/unofficial-android-port-pokemon-red-blue-yellow-3692724/"><img src="https://img.shields.io/badge/AS%20SEEN%20ON-ANDROID%20AUTHORITY-ea2e49?style=for-the-badge" alt="As seen on Android Authority"></a>
<a href="https://www.xda-developers.com/this-amazing-pokemon-red-and-blue-voxel-mod-adds-a-3d-perspective-without-an-emulator/"><img src="https://img.shields.io/badge/AS%20SEEN%20ON-XDA%20DEVELOPERS-ea2e49?style=for-the-badge" alt="As seen on XDA Developers"></a>
</p>

AI use on this project is disclosed in [AIDisclosure.md](AIDisclosure.md).

## Play in the browser

The web port is the same engine, compiled to WebAssembly with [love.js](https://github.com/Davidobot/love.js) in compatibility mode. Compatibility mode is what GitHub Pages can host: the page needs no `SharedArrayBuffer` and no COOP/COEP headers. Threaded love.js games (Forgotten Saga, 2dengine, LoveIDE) add a service worker to fake those headers. This build does not, because its workers already run on the main thread.

Red, Blue, and Yellow are supported. Gold, Silver, and Crystal import and play (beta). Emerald imports and plays its intro; some Gen 3 screens still need LuaJIT's FFI. Details and controls are in [docs/platforms/web.md](docs/platforms/web.md).

Publishing this repository:

1. **Settings > Pages > Source**: GitHub Actions. Do this once.
2. **Actions > web > Run workflow**, tick **deploy**, and run it. The workflow has to be on the default branch before GitHub will show it.

After that deploy, the game is at:

**https://awest813.github.io/gen1recomp/**

Open the page, press **Start** (browsers block sound until you do), then **Import ROM** and choose your legally obtained `.gb` / `.gbc` / `.gba` file. The file is read in the browser and is never uploaded. Saves stay in that browser's storage. Use **Export save** on the launcher if you want a `.sav` you can keep.

A second tab shows "Already open" so two copies cannot overwrite one save. `?game=blue` boots Blue directly. `?fps=1` shows the frame rate.

The site artifact is also attached to every **web** workflow run as `gen1recomp-web`, and release builds ship `gen1recomp-<version>-web.zip`. Unzip either one and serve the directory over HTTP. `file://` will not load the wasm.

## Play on a computer or phone

1. Download the build for your platform from the [latest release](https://github.com/bryanthaboi/gen1recomp/releases/latest).
2. Launch it. The package contains no ROM, so the launcher asks for one.
3. Choose a legally obtained `.gb`, `.gbc`, or `.gba` file, a `.zip` / `.7z` that holds one (where that build supports archives), or drop the file onto the window. Import takes a few seconds and the game starts.
4. Repeat for any other game you own. Each one gets its own launcher tab.

Your ROM is checked, used during import, and released from memory. It is never copied into the cache. Later launches load the generated cache. Music, sound effects, and cries are synthesized while the game runs. All eleven games can be imported side by side. Gen 2 support is still under construction. FireRed, LeafGreen, Ruby, Sapphire, and Emerald are in beta.

Install notes: [Linux](docs/platforms/linux.md), [iOS](docs/platforms/ios.md), [Xbox Dev Mode](docs/platforms/xbox.md), [handhelds](docs/platforms/handhelds.md), [Nintendo Switch](docs/platforms/switch.md), [PlayStation 4](docs/platforms/ps4.md).

**Windows Defender** sometimes flags the Windows build with a generic detection such as `Trojan:Win32/Wacatac!ml`. That is a known false positive: the exe is the official LÖVE runtime with the game archive appended, and Defender distrusts unsigned executables with appended data. Every release publishes `sha256sums.txt`. You can also check a flagged file on [VirusTotal](https://www.virustotal.com).

## Accepted ROMs

Only these canonical US English revisions are accepted. The importer checks the SHA-1 before it creates any game data.

| Game | Revision | ROM size | SHA-1 |
| --- | --- | --- | --- |
| Red | - | 1 MiB | `ea9bcae617fdf159b045185467ae58b2e4a48b9a` |
| Blue | - | 1 MiB | `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2` |
| Yellow | - | 1 MiB | `cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1` |
| Gold | - | 2 MiB | `d8b8a3600a465308c9953dfa04f0081c05bdcb94` |
| Silver | - | 2 MiB | `49b163f7e57702bc939d642a18f591de55d92dae` |
| Crystal | 1.0 | 2 MiB | `f4cd194bdee0d04ca4eac29e09b8e4e9d818c133` |
| Crystal | 1.1 | 2 MiB | `f2f52230b536214ef7c9924f483392993e226cfb` |
| FireRed | 1.0 | 16 MiB | `41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc` |
| FireRed | 1.1 | 16 MiB | `dd5945db9b930750cb39d00c84da8571feebf417` |
| LeafGreen | 1.0 | 16 MiB | `574fa542ffebb14be69902d1d36f1ec0a4afd71e` |
| LeafGreen | 1.1 | 16 MiB | `7862c67bdecbe21d1d69ce082ce34327e1c6ed5e` |
| Emerald | 1.0 | 16 MiB | `f3ae088181bf583e55daf962a92bb46f4f1d07b7` |
| Ruby | 1.0 | 16 MiB | `f28b6ffc97847e94a6c21a63cacf633ee5c8df1e` |
| Ruby | 1.1 | 16 MiB | `610b96a9c9a7d03d2bafb655e7560ccff1a6d894` |
| Ruby | 1.2 | 16 MiB | `5b64eacf892920518db4ec664e62a086dd5f5bc8` |
| Sapphire | 1.0 | 16 MiB | `3ccbbd45f8553c36463f13b938e833f652b793e4` |
| Sapphire | 1.1 | 16 MiB | `4722efb8cd45772ca32555b98fd3b9719f8e60a9` |
| Sapphire | 1.2 | 16 MiB | `89b45fb172e6b55d51fc0e61989775187f6fe63c` |

## Controls

| Action | Keyboard | Controller |
| --- | --- | --- |
| Move | Arrow keys / WASD | D-pad / left stick |
| A | Z / Enter / Space | A |
| B | X / Backspace | B |
| Start | Escape | Start |
| Select | Tab / Shift | Back / Select |

Rebind these in-game under **OPTIONS > CONTROLS**.

| Key | What it does |
| --- | --- |
| `-` / `=` | Zoom out / in (overworld; also the mouse wheel) |
| `1` / `0` | Game speed up / down (controller: R2 faster, L2 slower) |
| `2` | Cycle colors |
| `3` | Cycle tilt (free-roam overworld) |
| `4` | Cycle zoom through every level (free-roam overworld) |
| `F1` | Save |
| `F2` | Load |
| `F10` | Open / close the mod manager |

Colors, tilt, zoom, shader FX, game speed, and void fill are also in the Options menu and persist in `options.lua`.

**OPTIONS > PERFORMANCE** scales optional extras for weaker hardware (HIGH, BALANCED, LOW, or AUTO). It changes presentation only. Details are in [docs/new-features.md](docs/new-features.md).

On a phone, the browser build shows on-screen buttons the first time you touch the game. iPhone browsers have no page fullscreen; use **Share > Add to Home Screen** instead.

## Documentation

Guides, platform notes, and the engine map live in [docs](docs/README.md). The [wiki](https://github.com/bryanthaboi/gen1recomp/wiki) has the modding book, link play, the save editor, and developer setup.

- [Rulesets](docs/guides/rulesets.md)
- [Online play](docs/guides/online-play.md)
- [Launch options](docs/guides/launch-options.md)
- [Portable mode](docs/guides/portable-mode.md)
- [Running from source](docs/guides/running-from-source.md)
- [Modding](docs/modding-overview.md)
- [Architecture](docs/architecture.md)
- [Browser build](ports/web/BUILD.md)

## Bugs

A warp that drops you in the wrong place, battle math that does not match the original, text in the wrong box: [open a bug report](https://github.com/bryanthaboi/gen1recomp/issues/new?template=bug_report.yml). A screenshot saves a round trip. If you cannot get one, the form asks you to describe what you saw.

## License

See [LICENSE.MD](LICENSE.MD).

## Special thanks

This project depends on [pret](https://github.com/pret) and the [pokered](https://github.com/pret/pokered) disassembly.

<p align="center"><a href="https://boisclub.games"><img src="assets/logo/bcg.png" alt="Bois Club Games"></a></p>
