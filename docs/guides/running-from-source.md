# Running from source

Requires LÖVE 11.x. Place a ROM in the project folder and double-click
`Play-Mac.command` or `Play-Windows.bat`, or run:

```sh
scripts/setup.sh --rom "/path/to/Pokemon Red.gb"
scripts/run.sh
```

then `love .` for later launches.

Windows PowerShell scripts live in `scripts/`; test suites run with
`scripts/test.sh` (see its header for the tiers).
Runtime internals are in [architecture.md](../architecture.md).
