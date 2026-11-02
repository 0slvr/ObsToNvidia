# Changelog

## [Unreleased]

### Added
- **Official game names.** Clip folders are now named after the game's real name, taken offline from Steam, Epic and GOG records or from the exe's own info, instead of the window title (which changes with FPS counters, servers and loading screens). Turn it off with *Use official game names*.
- **OBS Game Capture support.** A game hooked by a Game Capture source is always treated as a game.
- **Last game wins.** If you play, then switch to the desktop, Discord or a browser before saving, the clip is now filed under the last game you played in the past minute instead of "Desktop".
- **Teach a game by its exe name.** In the *Add* fields you can type the exe name shown in Task Manager (e.g. `MyGame`) without saving a clip first.
- **Custom title rules.** Add `title:<keyword>=<Folder Name>` lines to `known_games.txt`. They work for any program, and they are also how Java and Microsoft Store games (other than Minecraft) are recognised.

### Improved
- Games installed in Steam, Epic, GOG and other libraries are now detected even when windowed.
- Fullscreen games installed on any drive or folder are now detected.
- Name priority: your own names > built-in / `known_games.txt` > official name > window title > Steam install folder > Steam lookup.

### Fixed
- A helper tool you glance at while playing (Lossless Scaling, Voicemeeter, MSI Afterburner, Playnite...) can no longer take over a game's clip: these are never games, and a game must now be in front for at least 5 seconds (was 2) to count as the last game.
- Exe info that is really a company name (`... Inc.`, `... GmbH`) or an engine string (`Unreal Engine 5`, `Epic Online Services`) is no longer used as a game's folder name.
- A Java or Store program hooked by OBS Game Capture no longer makes every window of that program count as a game.
- Minecraft clips (any launcher or modpack) now go to a `Minecraft` folder instead of names like `Multiplayer (3rd-party Server)`.
- Old `javaw=...` or Store-app entries in the list no longer rename every Java program or Store app.
- Game launchers and common apps (Steam, Epic, Battle.net, Office, remote desktop, media players) are no longer mistaken for games.
