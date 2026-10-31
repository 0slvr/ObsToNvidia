----------------------------------------------------------------------
-- MODULE 4: Update Checker  (shown as "4)" in the Scripts window)
----------------------------------------------------------------------
-- Compares this script's VERSION (see the top of the file) with the
-- VERSION inside the script attached to the latest GitHub Release, as
-- NUMBERS (1.10.0 is newer than 1.9.0). Only a release that is genuinely
-- newer is ever offered -- a locally edited copy, or a copy that is ahead
-- of the Release, is never "updated" back to an older file.
--
-- To publish an update:
--   1. bump  local VERSION = "x.y.z"  at the top of the script, and
--   2. publish a GitHub Release with the script attached (same filename).
--
-- When an update is found, a real Windows dialog asks what to do with it,
-- and nothing is written to disk without an answer:
--     Yes    -> install it now (old copy kept as SCRIPT_FILENAME .. ".bak")
--     No     -> skip this version; remembered across restarts, and a later
--               release is still offered normally
--     Cancel -> decide later; asked again on the next check
-- The dialog is held back while a fullscreen game is in the foreground and
-- shown once you're out of it, since interrupting a fullscreen game is the
-- exact thing the rest of this script exists to avoid.
--
-- Either way, OBS keeps whatever version it already loaded into memory
-- running until you reload this script or restart OBS -- there's no API
-- available to a script for hot-reloading itself, so that one manual step
-- can never be fully eliminated.
local Updater = {}
do
    -- GitHub gives every repo a permanent "latest release" alias URL
    -- that always points at whichever asset (by that exact filename)
    -- is attached to the most recently published Release -- no need to
    -- know the current tag name, and no need to touch the main branch
    -- at all. WinHTTP follows the redirect this URL issues (github.com
    -- -> objects.githubusercontent.com) automatically, since redirect
    -- following is WinHTTP's default behavior unless explicitly turned
    -- off (which this script never does).
    local GITHUB_OWNER    = "0slvr"
    local GITHUB_REPO     = "ObsToNvidia"
    local SCRIPT_FILENAME = "obs_to_nvidia.lua"
    local GITHUB_HOST     = "github.com"
    local LATEST_ASSET_PATH = "/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO ..
        "/releases/latest/download/" .. SCRIPT_FILENAME
    local RELEASES_URL    = "https://github.com/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO .. "/releases/latest"

    -- These requests run on OBS's UI thread (WinHTTP here is synchronous),
    -- so OBS is unresponsive while one is in flight. They used to allow up
    -- to 20 s for a single read; now the worst case is about 12 s for the
    -- script, and it only happens on a bad
    -- connection, once, ~10 s after OBS starts. (The receive timeout is per
    -- read, not for the whole download, so a normal transfer is unaffected.)
    -- "total" is a hard cap on the whole transfer (see https_get). The tiny
    -- version probe gets a short one; the full download a longer one, and it
    -- only happens when a newer version was actually found.
    local SCRIPT_DL_TIMEOUTS = { resolve = 2000, connect = 2000, send = 2000, receive = 6000, total = 10000 }
    local VERSION_PROBE_TIMEOUTS = { resolve = 1500, connect = 1500, send = 1500, receive = 2500,
        total = 4000, headers = "Range: bytes=0-4095\r\n" }

    local check_on_load = true
    -- "ask" (default) shows a dialog and does nothing without an answer,
    -- "auto" installs silently, "notify" only writes to the log.
    local update_mode = "ask"
    local update_checker -- forward-declared: registered with obs.timer_add below
    local retry_prompt   -- forward-declared: re-offers a deferred prompt
    local retry_auto_install -- forward-declared: re-attempts a deferred auto-install
    local last_check_result = "Not checked yet."

    -- Kept so the "skip this version" answer can be written back into the
    -- script's own saved settings and survive an OBS restart.
    local updater_settings = nil
    -- Version string the user chose to skip. Never offered again; a LATER
    -- version is still offered normally.
    local skipped_version = ""
    -- Set while an update is found, valid, and waiting for a moment when
    -- it's safe to interrupt the user (see the fullscreen check below).
    -- Fields: path, content, version.
    local pending_update = nil
    local prompt_attempts = 0
    local MAX_PROMPT_ATTEMPTS = 40   -- ~20 minutes at PROMPT_RETRY_MS
    local PROMPT_RETRY_MS = 30000
    local auto_install_attempts = 0
    local MAX_AUTO_INSTALL_ATTEMPTS = 40 -- ~20 minutes at AUTO_INSTALL_RETRY_MS
    local AUTO_INSTALL_RETRY_MS = 30000

    -- True while anything is capturing that a forced relaunch would cut
    -- off: a live stream, a recording, the Replay Buffer, or the virtual
    -- camera. obs_frontend_virtualcam_active() doesn't exist on every OBS
    -- build this script might run on, so it's called through pcall and
    -- treated as "not active" if the call itself fails, rather than
    -- blocking every auto-install forever on an API that isn't there.
    local function outputs_are_active()
        if obs.obs_frontend_streaming_active() or obs.obs_frontend_recording_active()
            or obs.obs_frontend_replay_buffer_active() then
            return true
        end
        local ok, active = pcall(obs.obs_frontend_virtualcam_active)
        return ok and active
    end

    -- ------------------------------------------------------------------
    -- Version comparison
    -- ------------------------------------------------------------------
    -- Reads  local VERSION = "1.2.3"  out of a script's text (nil if the
    -- script has none, e.g. a release made before versions existed).
    local function extract_version(content)
        return content:match('\nlocal VERSION%s*=%s*"([%d%.]+)"')
    end

    local function parse_version(v)
        local parts = {}
        for n in tostring(v):gmatch("%d+") do
            parts[#parts + 1] = tonumber(n)
        end
        return parts
    end

    -- > 0 if a is newer than b, < 0 if older, 0 if equal.
    local function compare_versions(a, b)
        local pa, pb = parse_version(a), parse_version(b)
        for i = 1, math.max(#pa, #pb) do
            local x, y = pa[i] or 0, pb[i] or 0
            if x ~= y then
                return (x > y) and 1 or -1
            end
        end
        return 0
    end

    -- Finds this exact running script file off disk, however the user
    -- happened to name it locally. Returns (path, content) so callers
    -- that only need the content can ignore the first value, and the
    -- install step below can write back to the exact same path.
    --
    -- debug.getinfo gives back the chunk name OBS loaded this script
    -- from, prefixed with "@". In practice that's usually the full
    -- path already -- but rather than assume that holds on every OBS
    -- version/platform, this tries the raw value from debug.getinfo
    -- first (it works as-is whenever it's already a full path), and
    -- only falls back to combining the global script_path() (the
    -- OBS-provided function -- note: NOT under the "obs." table --
    -- that returns this script's own directory, trailing slash
    -- included) with just the basename if the first attempt fails
    -- (i.e. debug.getinfo came back as a bare filename with no
    -- directory, so opening it directly would depend on the process's
    -- current working directory instead of the Scripts folder).
    local function read_own_script()
        local info = debug.getinfo(1, "S")
        if not info or not info.source then
            return nil, nil
        end
        local raw = info.source:gsub("^[@=]", "")
        if raw == "" then
            return nil, nil
        end

        -- script_path() is the folder OBS loaded this script from, as UTF-8,
        -- so it is tried first and read through the wide-character W helper:
        -- a Windows folder name with Arabic letters works. The raw
        -- debug.getinfo path (which can be ANSI-encoded) is the second try.
        local filename = raw:match("([^/\\]+)$") or raw
        local candidates = { script_path() .. filename, raw }
        for _, path in ipairs(candidates) do
            local content = W.read_file(path)
            if content then
                return path, content
            end
        end
        return nil, nil
    end

    -- Used only as a fallback below, when writing straight over the
    -- script's own file fails (typically because OBS itself -- and so
    -- this script -- lives under C:\Program Files\..., which a normal,
    -- non-elevated OBS process cannot write to). Same per-user OBS
    -- config folder the Sorter module uses for known_games.txt --
    -- Sorter.script_load() always runs before Updater.script_load() (see
    -- the combined script_load() near the end of this file), so that
    -- folder already exists by the time this is ever needed; this
    -- doesn't try to create it itself to avoid re-declaring the FFI
    -- directory-creation calls a second time in this module.
    local function fallback_update_path()
        local appdata = W.getenv("APPDATA")
        if not appdata or appdata == "" then
            return nil
        end
        return appdata .. "\\obs-studio\\script-data\\OBS-Clip-Suite\\" .. SCRIPT_FILENAME .. ".downloaded"
    end

    -- Sanity check on downloaded bytes BEFORE they are allowed anywhere
    -- near the user's script file. A redirect landing on an HTML page, a
    -- proxy/captive-portal login page, or a download cut short by a
    -- timeout must never replace a working script with something OBS
    -- can't even parse. Three cheap checks catch all of those:
    --   1. plausible size (this file is ~200 KB; anything tiny is wrong)
    --   2. it actually compiles as Lua
    --   3. it contains the markers that make it THIS script
    local function looks_like_this_script(content)
        if type(content) ~= "string" or #content < 50000 then
            return false, "the download was too small to be this script (likely an error page or a cut-off transfer)"
        end

        -- Parses only -- the chunk is never called. loadstring is the Lua
        -- 5.1 / LuaJIT name (which is what OBS runs); load is the 5.2+ one,
        -- kept as a fallback so this doesn't depend on which it is.
        local compile = loadstring or load
        local chunk, syntax_err = compile(content, "update-candidate")
        if not chunk then
            return false, "the download isn't valid Lua (" .. tostring(syntax_err) .. ")"
        end

        if not content:find("OBS Clip Suite", 1, true)
            or not content:find("function script_load", 1, true)
            or not content:find("OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED", 1, true) then
            return false, "the download doesn't look like the OBS Clip Suite script"
        end

        return true
    end

    local MOVEFILE_REPLACE_EXISTING = 0x1
    local MOVEFILE_WRITE_THROUGH    = 0x8

    -- Installs new script content over the local file ATOMICALLY: the new
    -- content is first written in full to "<script>.new", read back and
    -- compared, and only then swapped into place with a single
    -- MoveFileExW(REPLACE_EXISTING). The real script file is never opened
    -- for writing, so a power cut or a full disk can't leave a half-written
    -- script behind -- you either have the complete old file or the
    -- complete new one. The previous version is kept as "<script>.bak".
    local function write_updated_script(path, new_content)
        if not sorter_available then
            return false, "the Windows layer isn't available on this system"
        end

        -- Refuse outright rather than overwrite a working script with
        -- something unusable. This is the last line of defence before the
        -- user's own file is touched, so the check happens HERE as well as
        -- at the call site -- every path that writes the script goes
        -- through this function.
        local valid, reject_reason = looks_like_this_script(new_content)
        if not valid then
            return false, reject_reason
        end

        local tmp_path = path .. ".new"
        if not W.write_file(tmp_path, new_content) then
            W.remove(tmp_path)
            return false, "the update could not be written completely (check folder permissions, disk space, " ..
                "or whether the file is in use) -- your current script was not touched"
        end

        local written_back = W.read_file(tmp_path)
        if written_back ~= new_content then
            W.remove(tmp_path)
            return false, "the file on disk didn't match the downloaded update -- " ..
                "your current script was not touched"
        end

        -- Backups: ".bak" is always the file that was just replaced (handy,
        -- but overwritten by the next update), and ".bak-<version>" is a
        -- per-version copy that is NEVER overwritten by a different
        -- version's backup -- so a bad update followed by another one can't
        -- destroy the last known-good copy, and local edits survive.
        local backup_path = nil
        local old_content = W.read_file(path)
        if old_content then
            local old_version = extract_version(old_content) or "unknown"
            backup_path = path .. ".bak-" .. old_version
            if not W.write_file(backup_path, old_content) or W.read_file(backup_path) ~= old_content then
                W.remove(tmp_path)
                return false, "couldn't write a backup of your current script, so nothing was changed"
            end
            W.write_file(path .. ".bak", old_content)
        end

        local moved = kernel32.MoveFileExW(utf8_to_wide(tmp_path), utf8_to_wide(path),
            MOVEFILE_REPLACE_EXISTING + MOVEFILE_WRITE_THROUGH)
        if moved == 0 then
            local err = kernel32.GetLastError()
            W.remove(tmp_path)
            return false, "couldn't replace the script file (Windows error " .. tostring(err) ..
                ") -- your current script was not touched"
        end

        return true, backup_path
    end

