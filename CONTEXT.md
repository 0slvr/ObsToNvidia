# CONTEXT - read this first (for AI assistants and people)

OBS Lua script **obs_to_nvidia.lua** (OBS Clip Suite). The real script is the Lua in `src\`.
`Program.cs` is only the build tool that joins the parts into `dist\obs_to_nvidia.lua`.

## Rules
1. Edit ONLY files in `src\`. Never edit `dist\` (it is regenerated).
2. Make small, targeted edits (replace a specific block). Do not rewrite whole files.
3. **Do not open `20_alert_sounds_data.lua`** (1656 lines of base64 audio, nothing to edit there).
4. The parts are NOT separate modules. They are joined into ONE Lua chunk in the order of
   `src\_order.txt`, so a `local` must be defined in an earlier part than where it is used.
5. Blocks continue across files - do not add/remove a stray `do` / `end`:
   - `20_alert_sounds_data.lua` opens `do` (inside `local Alert = {}`); `21_alert_sound.lua` closes it.
   - `30_organizer_win32.lua` opens the Organizer's `do`; `33_organizer_files.lua` closes it.
     `32b_organizer_official_names.lua` sits inside that block and has its own balanced `do ... end`.
     `friendly_name()` (32) reaches it late-bound through `C.official_lookup`, so 32 does not need it defined earlier.
   - `40_updater_core.lua` opens the Updater's `do`; `42_updater_check.lua` closes it.
6. `VERSION` in `00_core.lua` is raised automatically by the Publish Release step - do not bump it by hand
   (unless the person asks).
7. The Updater replaces the single file `obs_to_nvidia.lua`, so the release must be the built `dist\` file.

## Files (build order)
| File | Lines | What is in it | Edit when... |
|---|---:|---|---|
| `00_core.lua` | 80 | header, `VERSION`, `ffi`, `W` file helpers, update marker | version, marker logic |
| `10_restarter.lua` | 120 | Module 1: Replay Buffer Restarter | restart-after-save behavior |
| `20_alert_sounds_data.lua` | 1656 | base64 sounds (DO NOT OPEN) | never |
| `21_alert_sound.lua` | 362 | Module 3: Clip Alert Sound (decode, play, settings) | alert sound logic/UI |
| `30_organizer_win32.lua` | 654 | Module 2 start: Win32 FFI, window title/class, foreground info | Win32 calls, window detection |
| `31_organizer_tracking.lua` | 708 | Organizer settings, foreground history, known games, folder names, "Add" button | game detection, name map, UI |
| `32_organizer_steam_names.lua` | 495 | Steam lookup, title cleanup, `friendly_name()` | how folder names are chosen |
| `32b_organizer_official_names.lua` | 330 | official names: Steam `appmanifest`, Epic `.item`, GOG `goggame-*.info`, exe ProductName, OBS Game Capture (all in table `C.on`) | which source names a game, hooked-game detection |
| `33_organizer_files.lua` | 253 | folder creation, `move_file`, Organizer hooks | moving/renaming clips |
| `40_updater_core.lua` | 287 | Module 4 start: GitHub config, version compare, write update file | repo, version rules |
| `41_updater_install.lua` | 372 | update prompt, staging, relaunch OBS | install/relaunch flow |
| `42_updater_check.lua` | 320 | `check_for_updates`, restore backup, Updater hooks | checking logic, Updater UI |
| `90_main.lua` | 206 | `script_properties`, `script_load`, frontend events, resume after update | OBS lifecycle |

## Shared names (defined once, used in several parts)
- `obs`, `VERSION`, `ffi` (nil if no FFI), `W` (file helpers) - `00_core.lua`
- `script_path()` - OBS built-in, used by core, Organizer, Updater
- `kernel32`, `user32`, `shell32`, `winhttp` - declared at the top of `30_organizer_win32.lua`,
  also used by `40_updater_*` and `90_main.lua`
- `Restarter`, `Alert`, `Sorter` (= Organizer), `Updater` - one table per module; `90_main.lua` calls
  their `script_properties / script_defaults / script_update / script_load / script_unload`
- `update_marker_path()`, `write_update_marker()`, `remove_update_marker()` - `00_core.lua`,
  used by Updater and `90_main.lua`

## Build
Visual Studio: open `obs_to_nvidia.sln`, Ctrl+Shift+B. Or `dotnet run`.
Result: `dist\obs_to_nvidia.lua`. If `luac`/`luajit` is on PATH, the build also checks the syntax
(`--no-check` skips it). `--copy-to <folder>` copies the result into your OBS scripts folder.

## Release
Visual Studio: run profile **Publish Release** (Ctrl+F5) = auto-bump VERSION + build + commit + push + GitHub Release
`vVERSION` with `dist\obs_to_nvidia.lua` attached, silently (log: `publish.log`). Needs `git` and `gh`. Details in `README.md`.
AI assistants: never run the publish step yourself - only the person publishes.
