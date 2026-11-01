# OBS Clip Suite

One OBS Studio script that makes OBS's normal Replay Buffer work like **NVIDIA instant replay (ShadowPlay)** on Windows:

- every clip is **separate**, with no overlapping footage,
- clips are **sorted into a folder per game**,
- and you get a **sound** when a clip is saved.

| | Module | What it does |
|---|---|---|
| 1 | **Replay Buffer Restarter** | Restarts the buffer after every save, so back-to-back clips never overlap. |
| 2 | **Replay Organizer** | Sorts each clip into a folder named after the game you were playing. |
| 3 | **Clip Alert Sound** | Plays a short sound whenever a clip is saved. |
| 4 | **Update Checker** | Updates the script for you from this repo's Releases. |

Everything lives in a single file: `obs_to_nvidia.lua`.

---

## Quick start

**You need:** Windows, OBS Studio, and the Replay Buffer enabled (`Settings > Output > Replay Buffer`) with a save hotkey.

1. Download `obs_to_nvidia.lua` from the [latest Release](../../releases/latest).
2. Put it somewhere permanent (not Downloads: OBS remembers the path).
3. In OBS: **Tools > Scripts > `+`** and pick the file.

![OBS Tools menu with the Scripts entry highlighted](images/tools-scripts-menu.png)

Each module has its own group with an on/off checkbox in its header.

![The Scripts window showing the four groups](images/scripts-window.png)

> Without Windows features, the Restarter and Alert Sound still work; the Organizer and updater switch themselves off.

---

<<<<<<< HEAD
## How it works
=======
1. The Alert plays its sound (first, so it is never delayed by the Organizer). It only plays for a real save: the `Saved` event plus the clip file being on disk.
2. The Organizer moves the clip into its folder.
3. The Restarter stops and restarts the Replay Buffer.
>>>>>>> fd041e9 (Release v2.20)

When a clip is saved, the modules run in this order: **Organizer → Alert Sound → Restarter**.
An error in one module never stops the others.

### 1) Replay Buffer Restarter
Nothing to configure.

- Waits for all saves in progress to finish before restarting.
- Handles quick bursts of saves and learns how long the buffer takes to start on your PC.
- If the buffer doesn't come back, it retries in the background (up to 12 times) and logs a warning instead of staying silently off.
- If you stop the buffer yourself, it stays stopped.
- After 3 restart cycles in a row that needed recovery, it pauses for the session. Untick and tick its checkbox to resume.

### 2) Replay Organizer
Sorts every clip into a folder named after the game or app.

- Reads the real foreground window with direct Win32 calls, so **fullscreen games are never minimized or kicked to the desktop**.
- Remembers the last few seconds, so a save right after you alt-tab still goes to the right game.
- Non-game apps go to a shared **Desktop** folder.
- Never overwrites a clip; works with non-ASCII (e.g. Arabic) names and paths.

**Custom names:** type the current folder name, type the new name, press **Add**.

**Where a game's name comes from** (first match wins):
your own names → built-in list / `known_games.txt` → window title → Steam folder name → Steam lookup.

- **Steam lookup** is optional (*Look up unknown games on Steam*). Results are saved in `known_games.txt`.
- `known_games.txt` is in `%APPDATA%\obs-studio\script-data\OBS-Clip-Suite`. Reload the script after editing it.

### 3) Clip Alert Sound
Off by default. Turn it on with the group's checkbox, then pick:

- one of **6 built-in sounds** (no extra files), or your own file (`.wav .mp3 .ogg .aac .flac`)
- the **volume** (0–100 %)
- **Test Alert Now** to hear it

### 4) Update Checker
Checks GitHub Releases about 10 seconds after OBS starts (can be turned off), or any time with **Check for Updates Now**. Only a *higher* version number is ever offered.

**When an update is found**, choose what happens:

| Mode | Behaviour |
|---|---|
| **Ask me first** (default) | Dialog: *Yes* = install, *No* = skip this version, *Cancel* = ask again later. |
| **Install it automatically** | Installs by itself. |
| **Only mention it in the log** | Just a log message. |

Nothing is installed or shown during a **stream, recording, Virtual Camera** or while a **fullscreen game** is in front. It waits until they're over. (The Replay Buffer doesn't block it.)

**What to expect:**
- OBS closes and opens **twice** during an update. This is normal: the second restart loads the new version.
- The Replay Buffer is stopped first and resumes automatically at the end.
- Your old script is backed up next to it as `obs_to_nvidia.lua.bak` and `.bak-<version>`.

**Restore previous version** brings the old script back and restarts OBS automatically. The newer version is added to the skipped list so you aren't asked about it again right away.

---

## Files created

| File | Purpose |
|---|---|
| `obs_to_nvidia.lua.bak`, `.bak-<version>` | Backups made by the updater |
| `obs_to_nvidia.lua.staged`, `.new` | Temporary files during an update |
| `obs_to_nvidia_update_state.tmp` | Temporary marker during an update |
| `known_games.txt` | Your extra game names and cached Steam results |

## Troubleshooting

**"No properties available" / `Error opening file: (null)` in the Script Log**
OBS couldn't read the script. Check that `obs_to_nvidia.lua` exists at the path shown in Tools > Scripts, remove the entry, and add the file again.
