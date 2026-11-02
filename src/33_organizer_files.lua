-- Creates dest_folder via a direct Win32 call (no cmd.exe / mkdir process).
-- Only handles a single-level create, same as the old "mkdir" call did;
-- OBS's own replay folder must already exist, we're just creating the
-- one game subfolder under it.
local function ensure_folder(win_folder)
    local wide_folder = utf8_to_wide(win_folder)
    local ok = kernel32.CreateDirectoryW(wide_folder, nil)
    if ok == 0 then
        local err = C.last_error()
        if err ~= C.ERROR_ALREADY_EXISTS then
            print("OBS Replay Organizer: CreateDirectoryW failed for '" .. win_folder ..
                  "' (error " .. tostring(err) .. ").")
        end
    end
end

-- True if a file already exists at this Windows path.
local function file_exists(win_path)
    local wide = utf8_to_wide(win_path)
    local attrs = kernel32.GetFileAttributesW(wide)
    return tonumber(attrs) ~= C.INVALID_FILE_ATTRIBUTES
end

-- Builds a destination path that doesn't collide with an existing file --
-- normally just "<base> <date> <time>.<ext>", but if two clips land in
-- the same folder within the same second (same base/date/time string),
-- this appends " (2)", " (3)", ... instead of one silently overwriting
-- the other.
local function unique_dest_path(win_dest_folder, base_no_ext, ext)
    local candidate = win_dest_folder .. "\\" .. base_no_ext .. "." .. ext
    if not file_exists(candidate) then
        return candidate
    end
    for n = 2, 999 do
        candidate = win_dest_folder .. "\\" .. base_no_ext .. " (" .. n .. ")." .. ext
        if not file_exists(candidate) then
            return candidate
        end
    end
    -- Astronomically unlikely (999 same-second collisions) -- just take
    -- the last candidate rather than looping forever.
    return candidate
end

local function log_move_failure(win_src, win_dest, attempts, err)
    print("OBS Replay Organizer: MoveFileExW failed moving '" .. win_src ..
          "' -> '" .. win_dest .. "' after " .. tostring(attempts) ..
          " attempt(s) (error " .. tostring(err) .. "). The clip was left where OBS saved it.")
end

local function is_lock_error(err)
    return err == C.ERROR_SHARING_VIOLATION or err == C.ERROR_LOCK_VIOLATION
end

-- Moves src into dest_folder under a unique name. Returns:
--   dest_path   -- moved right away
--   nil, true   -- the file was locked for the moment; retries are running on
--                  an OBS timer, and on_moved_later(dest_path) is called if
--                  one of them gets it through
--   nil         -- failed for good (already logged)
--
-- Right after the "replay saved" event the file can still be briefly held
-- open by OBS's own muxer, or locked for a moment by antivirus real-time
-- scanning. Retrying used to be done with a blocking 300 ms sleep x 6 on OBS's UI thread
-- -- up to 1.8 s of a frozen OBS. Now the first attempt is immediate and any
-- retries happen on a timer, so nothing blocks.
local function move_file(src, dest_folder, new_base_name, on_moved_later)
    local win_dest_folder = dest_folder:gsub("/", "\\")
    ensure_folder(win_dest_folder)

    local win_src = src:gsub("/", "\\")
    local ext = src:match("%.([^%.\\/]+)$") or "mp4"
    local date_part = os.date("%Y-%m-%d")
    local time_part = os.date("%H-%M-%S")
    -- Keep the full destination path under Windows' 260-char limit
    -- (bytes used as a conservative stand-in for characters).
    local tail = " " .. date_part .. " " .. time_part .. " (999)." .. ext
    local room = 250 - #win_dest_folder - 1 - #tail
    if room < 1 then room = 1 end
    if #new_base_name > room then
        local cut = new_base_name:sub(1, room)
        while #cut > 0 do
            local nxt = new_base_name:byte(#cut + 1)
            if nxt ~= nil and nxt >= 0x80 and nxt < 0xC0 then cut = cut:sub(1, -2) else break end
        end
        new_base_name = (cut:match("^(.-)[%s%.]*$") or cut)
        if new_base_name == "" then new_base_name = "Clip" end
    end
    local base_no_ext = new_base_name .. " " .. date_part .. " " .. time_part
    local win_dest = unique_dest_path(win_dest_folder, base_no_ext, ext)

    -- Direct Win32 move (no cmd.exe / "move" process, no shell spawn at all).
    -- C.MOVEFILE_COPY_ALLOWED mirrors the old fallback behavior for moves
    -- across drives. No C.MOVEFILE_REPLACE_EXISTING -- win_dest is guaranteed
    -- unique by unique_dest_path() above, so this never needs to (and
    -- never should) silently overwrite an existing clip.
    local wide_src = utf8_to_wide(win_src)
    local wide_dest = utf8_to_wide(win_dest)

    if kernel32.MoveFileExW(wide_src, wide_dest, C.MOVEFILE_COPY_ALLOWED) ~= 0 then
        return win_dest
    end
    local err = C.last_error()

    if not is_lock_error(err) or on_moved_later == nil then
        -- Some other error -- retrying won't help, fail fast. (Returning the
        -- destination unconditionally, as an old version did, made the
        -- caller log a confident "sorted X -> Y" for a move that had just
        -- failed; nil means "not moved".)
        log_move_failure(win_src, win_dest, 1, err)
        return nil
    end

    local attempt = 1
    local retry
    retry = function()
        attempt = attempt + 1
        if kernel32.MoveFileExW(wide_src, wide_dest, C.MOVEFILE_COPY_ALLOWED) ~= 0 then
            obs.timer_remove(retry)
            pending_move_timers[retry] = nil
            on_moved_later(win_dest)
            return
        end
        local retry_err = C.last_error()
        if not is_lock_error(retry_err) or attempt >= C.MOVE_RETRY_ATTEMPTS then
            obs.timer_remove(retry)
            pending_move_timers[retry] = nil
            log_move_failure(win_src, win_dest, attempt, retry_err)
        end
    end
    pending_move_timers[retry] = true
    obs.timer_add(retry, C.MOVE_RETRY_DELAY_MS)
    return nil, true
end

------------------------------------------------------------------
-- Is this foreground sample a game?  (also used on old history samples)
------------------------------------------------------------------
local function classify_game(info)
    if info == nil then return false end
    -- Exe unreadable (anti-cheat/protected) but fullscreen and titled: a game.
    if info.protected then return true end
    local exe_lower = info.exe_name:lower()
    if NON_GAME_EXES[exe_lower] and not name_map[exe_lower] then
        -- Browsers, Explorer, Discord, OBS, game launchers...: never a game, even
        -- if a stray entry exists in known_games.txt -- unless YOU named it with
        -- the "Add" button (name_map), which always wins.
        return false
    end
    -- A game you (or the built-in list) named is a game even windowed.
    if not GENERIC_HOST_EXES[exe_lower] and (name_map[exe_lower] or KNOWN_GAMES[exe_lower]) then return true end
    -- An exe that an OBS Game Capture source has hooked is rendering 3D graphics: a game.
    if C.on and C.on.seen_hooked[exe_lower] then return true end
    -- A Minecraft window (see is_minecraft_mode_title), under any launcher / java exe.
    if is_minecraft_mode_title(info.window_title) then return true end
    -- A window title that matches one of YOUR title: rules (known_games.txt / Add list).
    if C.user_title_rule(info.window_title) then return true end
    if GENERIC_HOST_EXES[exe_lower] then
        -- javaw / ApplicationFrameHost: only a game if the title says so
        -- (e.g. Minecraft); the exe alone can't tell.
        return title_rule_name(info.window_title) ~= nil
    end
    -- Unknown app. Installed in a game library (Steam, Epic, GOG, Riot, ...): a game,
    -- fullscreen OR windowed.
    if is_in_game_library(info.exe_path) then return true end
    -- Anywhere else: a game if it is fullscreen and not a system / Office / browser /
    -- per-user app (games installed on another drive or in a custom folder).
    if info.is_fullscreen and is_plausible_fullscreen_game(info.exe_path) then return true end
    return false
end

------------------------------------------------------------------
-- Main event handler
------------------------------------------------------------------
    function Sorter.on_replay_saved()
    if not sorter_enabled or not sorter_available then
        return
    end

    local path = get_last_replay_path()
    if path == nil then
        print("OBS Replay Organizer: couldn't get last replay path.")
        return
    end

    -- Always sorts into a subfolder of wherever OBS itself is already
    -- saving replays (same folder the Replay Buffer is configured to
    -- use) -- no manual setup needed.
    local base_folder = path:match("^(.*)[\\/][^\\/]+$")
    if base_folder == nil then
        print("OBS Replay Organizer: couldn't determine OBS's own replay folder from '" ..
              path .. "' — skipping.")
        return
    end

    -- The LAST game that was in front during the last minute (or less, if the Replay
    -- Buffer is shorter) decides: you played, maybe switched to another game, maybe
    -- went to the desktop / Discord / a browser, and then pressed save -- the clip is
    -- from the game you were playing last. Only a game that stayed in front for at
    -- least 5 seconds counts, so a window flashing past (or a helper tool you glance at
    -- while playing) is ignored.
    local info = get_recent_game(game_memory_seconds(), classify_game, 5)
    local is_game = info ~= nil
    local from_memory = false
    if is_game then
        -- Say in the log when the game was no longer in front at the moment of the save.
        local now_info = get_dominant_foreground(2)
        from_memory = not (now_info ~= nil and now_info.exe_name == info.exe_name)
    else
        -- No game in the last minute. Use whatever was in front over the last few
        -- seconds (see fg_history above); right after the script loaded there is no
        -- history yet, so fall back to the plain instantaneous check.
        info = get_dominant_foreground(lookback_s)
        if info == nil then
            info = get_foreground_info()
        end
        is_game = classify_game(info)
    end
    local game = "Desktop"
    if info == nil then
        print("OBS Replay Organizer: couldn't detect the foreground app — sorting into 'Desktop'.")
    elseif is_game then
        if info.protected then
            -- Exe unreadable (anti-cheat/protected) but the window is fullscreen
            -- and titled: named from the title.
            local by_title = C.user_title_rule(info.window_title)
            if is_minecraft_mode_title(info.window_title) then
                game = "Minecraft" -- same rule as friendly_name: the mode suffix is not a game name
            elseif by_title then
                game = by_title
            else
                game = extract_stable_app_name(info.window_title, true)
            end
        else
            game = friendly_name(info.exe_name, info.window_title, info.is_fullscreen, info.exe_path)
        end
    end
    game = sanitize(game)
    print("OBS Replay Organizer: detected exe='" .. (info and info.exe_name or "?") ..
          "' title='" .. tostring(info and info.window_title) ..
          "' fullscreen=" .. tostring(info and info.is_fullscreen) ..
          " game=" .. tostring(is_game) .. (from_memory and " (the last game seen in the past minute)" or ""))

    -- Keep the folder-name index (used by the "Add" fields above) fresh
    -- even for games that were never in any static list and were only
    -- ever identified from their window title -- so they become
    -- renameable by folder name too, as soon as one clip is saved.
    -- (Not for generic hosts like javaw / ApplicationFrameHost: renaming "by
    -- exe" would rename EVERY Java program or Store app, not just this game.)
    if is_game and info ~= nil and not info.protected and not GENERIC_HOST_EXES[info.exe_name:lower()] then
        last_seen_exe_by_folder[game:lower()] = info.exe_name:lower()
    end

    -- Fully automatic, no list to maintain: if the foreground app wasn't
    -- genuinely fullscreen (games running exclusive/borderless-fullscreen),
    -- or couldn't be detected at all, treat it as a regular app (browser,
    -- Discord, Explorer, etc.) and drop its clip into one shared
    -- "Desktop" subfolder, named "Desktop" too (not per-app folders or
    -- filenames) instead of the per-game sorted folders/names.
    local subfolder_name = is_game and game or "Desktop"
    local file_base_name = subfolder_name
    local dest_folder = base_folder .. "\\" .. subfolder_name
    -- Called right away when the move works at once, or later from a timer
    -- if the clip was briefly locked and a retry got it through.
    local function report_sorted(dest_path)
        if info ~= nil then
            -- Detected exe kept in the log purely for troubleshooting --
            -- renaming itself doesn't need this anymore (see "Add" fields
            -- above, which work from the folder name directly).
            print("OBS Replay Organizer: sorted '" .. path .. "' -> " .. dest_path ..
                  "  (detected exe: " .. info.exe_name .. ")")
        else
            print("OBS Replay Organizer: sorted '" .. path .. "' -> " .. dest_path)
        end
    end

    local dest_path, retrying = move_file(path, dest_folder, file_base_name, report_sorted)
    if retrying or dest_path == nil then
        -- Retrying: report_sorted fires later if a retry works. Otherwise
        -- move_file already logged the specific Win32 error and why it
        -- gave up; don't follow it with a bogus success line.
        return
    end
    report_sorted(dest_path)
end
end

