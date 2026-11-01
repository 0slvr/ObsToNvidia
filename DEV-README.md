# obs_to_nvidia - dev project

Edit the parts in `src\`, then build. The result is ONE file:
`dist\obs_to_nvidia.lua` - that is the file you release / add to OBS.

| File | What |
|---|---|
| `00_core.lua` | header, VERSION, `W` helpers, update marker |
| `10_restarter.lua` | Module 1: Replay Buffer Restarter |
| `20_alert_sounds_data.lua` | base64 sounds (huge, no need to open) |
| `21_alert_sound.lua` | Module 3: Clip Alert Sound |
| `30_organizer_win32.lua` ... `33_organizer_files.lua` | Module 2: Replay Organizer (4 parts) |
| `40_updater_core.lua` ... `42_updater_check.lua` | Module 4: Update Checker (3 parts) |
| `90_main.lua` | OBS lifecycle hooks (`script_properties`, `script_load`, ...) |

See `CONTEXT.md` for the full map, shared locals and editing rules.

Order is set in `src\_order.txt`. The parts are NOT standalone modules:
they are joined into a single Lua chunk and share locals, same as before.

Build: open `obs_to_nvidia.sln` in Visual Studio -> Ctrl+Shift+B (or F5).
If `luac` or `luajit` is on PATH the build also checks Lua syntax (`--no-check` skips it).
Optional: `dotnet run -- --copy-to "C:\path\to\OBS\scripts"` also copies the result there.
Bump `VERSION` in `00_core.lua` for each release.

## One-click release (Visual Studio)

1. In the toolbar's run dropdown choose **Publish Release**, then press **Ctrl+F5** (or F5).
2. That's all: no console window and no question. It raises `VERSION` by one automatically
   (2.5 -> 2.6, 2.5.3 -> 2.5.4), builds, commits + pushes the sources, and creates the GitHub Release
   `vX.Y.Z` with `dist\obs_to_nvidia.lua` attached. OBS users then get the update prompt.
3. Success is silent: see the Output window (Debug) or `publish.log` in the project folder.
   A failure shows an error message box with the reason.
4. You never edit `VERSION` yourself. (Bigger jump, e.g. 3.0? Set `VERSION` by hand to the version
   BEFORE the one you want, e.g. "2.99".)

Safety: if anything fails after the bump, `VERSION` is put back; it refuses if the new version already exists on GitHub.
There is NO confirmation, so only press it when the built file was tested in OBS.
To get a confirmation again, remove `--yes` from `Properties\launchSettings.json`.

### First-time setup (once)
- Install Git and GitHub CLI: `winget install Git.Git` and `winget install GitHub.cli`
- Log in: `gh auth login`
- This folder must be a git clone of the repo `0slvr/ObsToNvidia` (the Update Checker is set to that repo):
  `git clone https://github.com/0slvr/ObsToNvidia.git`, then copy this project's files into the clone and open the `.sln` from there.
  (Or in this folder: `git init`, `git remote add origin https://github.com/0slvr/ObsToNvidia.git`, `git pull origin main --allow-unrelated-histories`.)

## Tests

`tests\run_tests.lua` runs the real parts from `src\` against a fake OBS (virtual clock + timers) and a fake WinHTTP,
so the Restarter timing, the foreground-app choice and the Steam lookup can be checked without OBS or Windows:

    luajit tests/run_tests.lua          (any Lua 5.1-5.4 works too)

Run it before **Publish Release**. It exits with a non-zero code if a check fails.
