    -- ------------------------------------------------------------------
    -- The update prompt
    --
    -- Three answers, not two, because "no" genuinely means two different
    -- things: "I don't want THIS version, stop asking" and "not right now,
    -- ask me again". Collapsing them into one button forces the user to
    -- either keep dismissing the same prompt at every OBS start, or lose
    -- the update permanently.
    --
    --   Yes    -> install now (writes the file, validated first)
    --   No     -> skip this version: its version number is remembered in
    --             the script's settings and never offered again. A LATER
    --             release has a different version, so updates keep
    --             working normally.
    --   Cancel -> decide later: nothing is remembered, so the same version
    --             is offered again on the next check / next OBS start.
    -- ------------------------------------------------------------------
    local function remember_skipped(version)
        skipped_version = version
        if updater_settings ~= nil then
            obs.obs_data_set_string(updater_settings, "skipped_update_version", version)
        end
    end

    C.SW_SHOWNORMAL = 1
    C.WM_CLOSE = 0x0010
    C.GW_OWNER = 4

    -- Finds OBS's own MAIN window. It can't just take the first visible
    -- window of this process: the Scripts window, dialogs and floating
    -- docks are also visible windows of this process, and closing one of
    -- those leaves OBS itself running -- next to the freshly launched copy.
    -- So only top-level windows with NO owner count (dialogs and floating
    -- docks are owned by the main window), and the title must contain
    -- "OBS" (the main window is titled "OBS 31.0.0 - Profile: ... ").
    -- Returns nil if no such window is found -- the caller then does not
    -- launch anything.
    local function find_own_main_window()
        local own_pid = kernel32.GetCurrentProcessId()
        local found = nil
        local cb = ffi.cast("WNDENUMPROC", function(hwnd, _lparam)
            if user32.IsWindowVisible(hwnd) ~= 0 and user32.GetWindow(hwnd, C.GW_OWNER) == nil then
                local pid = ffi.new("DWORD[1]")
                user32.GetWindowThreadProcessId(hwnd, pid)
                if pid[0] == own_pid then
                    local title_ok, title = pcall(Sorter.get_window_title, hwnd)
                    if title_ok and title and title:find("OBS", 1, true) then
                        found = hwnd
                        return 0 -- stop enumeration, we found it
                    end
                end
            end
            return 1 -- keep enumerating
        end)
        local ok, err = pcall(function()
            user32.EnumWindows(cb, 0)
        end)
        cb:free()
        if not ok then
            error(err)
        end
        return found
    end

    -- Launches a fresh copy of OBS, then asks this one to close normally
    -- -- the closest a script can get to "hot-reloading" itself, since no
    -- OBS API exists for a script to reload its own file into the
    -- already-running process. Returns true once the close request has
    -- been posted; OBS finishes its own shutdown asynchronously from
    -- here (same as if the user clicked the title-bar close button).
    --
    -- Order matters: (1) find the window to close BEFORE launching anything,
    -- so a failure there can't leave two instances running, (2) write the
    -- "resume the Replay Buffer" marker BEFORE launching, so the new
    -- instance can never start up and look for it too early, (3) launch,
    -- (4) close this one.
    local function relaunch_obs(resume_replay)
        if not sorter_available then
            return false, "the win32 layer isn't available on this system"
        end
        local marker_written = false
        local ok, err = pcall(function()
            local path_buf_len = 32760
            local wbuf = ffi.new("WCHAR[?]", path_buf_len)
            local len = kernel32.GetModuleFileNameW(nil, wbuf, path_buf_len)
            if len == 0 then
                error("couldn't determine OBS's own executable path")
            end

            local main_hwnd = find_own_main_window()
            if main_hwnd == nil then
                error("couldn't find OBS's own main window to close it gracefully")
            end

            -- Record "launched" + this (old) instance's PID BEFORE launching,
            -- so the new instance can never start up and look for it too
            -- early, and so a reloaded copy of this script inside the old
            -- instance knows the launch already happened.
            if W.exists(update_marker_path()) or resume_replay then
                if write_update_marker(kernel32.GetCurrentProcessId(), resume_replay, true) then
                    marker_written = true
                end
            end

            -- "--multi" lets the new instance start while this one is still
            -- shutting down. The new instance then WAITS for this process
            -- to exit before resuming the Replay Buffer, so the two never
            -- record at the same time.
            -- Start OBS in ITS OWN folder (a wrong working directory makes OBS fail
            -- to find its data files and exit, which looks like OBS "crashed" after
            -- the update) and with the SAME arguments it was started with (without
            -- them a --portable / --profile / --collection setup comes back as a
            -- different, empty OBS).
            local wdir = nil
            local dir_len = len
            while dir_len > 0 and wbuf[dir_len - 1] ~= 92 do dir_len = dir_len - 1 end -- 92 = "\\"
            if dir_len > 1 then
                wdir = ffi.new("WCHAR[?]", dir_len) -- zero-filled, so NUL-terminated
                ffi.copy(wdir, wbuf, (dir_len - 1) * ffi.sizeof("WCHAR"))
            end

            local wargs = utf8_to_wide("--multi")
            local args_ok, built = pcall(function()
                local cl = kernel32.GetCommandLineW()
                if cl == nil then return nil end
                local n = 0
                while cl[n] ~= 0 do n = n + 1 end
                local i = 0
                if cl[0] == 34 then -- quoted program path
                    i = 1
                    while i < n and cl[i] ~= 34 do i = i + 1 end
                    i = i + 1
                else
                    while i < n and cl[i] ~= 32 do i = i + 1 end
                end
                while i < n and cl[i] == 32 do i = i + 1 end
                -- Copy the inherited arguments, DROPPING any "--multi" token they
                -- already contain (left by an earlier update), so the command line
                -- doesn't grow by one more "--multi" on every update.
                local tmp = {}
                local tlen = 0
                local flag = "--multi"
                local k = i
                while k < n do
                    local token_start = (k == i) or cl[k - 1] == 32
                    local is_flag = false
                    if token_start then
                        is_flag = true
                        for j = 1, #flag do
                            if cl[k + j - 1] ~= flag:byte(j) then is_flag = false break end
                        end
                        if is_flag then
                            local after = k + #flag
                            if after < n and cl[after] ~= 32 then is_flag = false end
                        end
                    end
                    if is_flag then
                        k = k + #flag
                    else
                        tlen = tlen + 1
                        tmp[tlen] = cl[k]
                        k = k + 1
                    end
                end
                local extra = " --multi"
                local buf = ffi.new("WCHAR[?]", tlen + #extra + 1)
                for t = 1, tlen do
                    buf[t - 1] = tmp[t]
                end
                for e = 1, #extra do
                    buf[tlen + e - 1] = extra:byte(e)
                end
                return buf
            end)
            if args_ok and built ~= nil then
                wargs = built
            end

            local result = shell32.ShellExecuteW(nil, nil, wbuf, wargs, wdir, C.SW_SHOWNORMAL)
            if tonumber(ffi.cast("intptr_t", result)) <= 32 then
                error("ShellExecuteW couldn't start a new OBS instance")
            end

            user32.PostMessageW(main_hwnd, C.WM_CLOSE, 0, 0)
        end)
        if not ok then
            if marker_written then
                remove_update_marker() -- nothing was relaunched, so nothing should resume
            end
            return false, err
        end
        obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: closing this OBS instance to load the update just installed.")
        return true
    end

    -- Used by the NEW OBS (see 90_main.lua) to restart once more after it swapped
    -- the file in, because OBS doesn't reload a script that changed on disk.
    function Updater.relaunch_obs(resume)
        return relaunch_obs(resume)
    end

    -- Writes the downloaded script NEXT TO the live one as "<script>.staged"
    -- (verified by reading it back). The live file is NOT touched, so this
    -- OBS never reloads the script in the middle of an update.
    local function stage_update(path, content)
        local valid, why = looks_like_this_script(content)
        if not valid then
            return false, why
        end
        local sp = path .. ".staged"
        if not W.write_file(sp, content) or W.read_file(sp) ~= content then
            W.remove(sp)
            return false, "couldn't write the staged update next to the script (check folder permissions)"
        end
        return true
    end

    -- Swaps the staged file in (backup + atomic replace, same as before).
    -- Called by the NEW OBS, after the old one has exited. OBS won't reload the
    -- script by itself after the swap, so the caller restarts OBS once more.
    function Updater.has_staged_update()
        local path = read_own_script()
        return path ~= nil and W.exists(path .. ".staged")
    end

    function Updater.apply_staged_update()
        local path = read_own_script()
        if not path then
            return false, "couldn't locate this script's own file"
        end
        local sp = path .. ".staged"
        local content = W.read_file(sp)
        if not content then
            return false, "no staged update found"
        end
        local ok, err = write_updated_script(path, content)
        W.remove(sp)
        if ok and updater_settings ~= nil and err then
            obs.obs_data_set_string(updater_settings, "last_backup_path", err)
        end
        return ok, err
    end

    -- Stage 2 of an install: the Replay Buffer is already stopped (or was never
    -- running). Order: marker, stage the file (live file untouched), launch the
    -- new OBS with --multi, ask this one to close. The new OBS waits for this
    -- process to be gone, THEN swaps the file and resumes the Replay Buffer.
    local function do_install(path, content, resume)
        write_update_marker(kernel32.GetCurrentProcessId(), resume, false)
        local ok, err = stage_update(path, content)
        if not ok then
            remove_update_marker()
            if resume then
                obs.obs_frontend_replay_buffer_start()
            end
            return false, err
        end
        local relaunch_ok, relaunch_err = relaunch_obs(resume)
        if not relaunch_ok then
            remove_update_marker()
            -- No relaunch is in flight, so swapping the file here is safe:
            -- the new file is on disk but this OBS keeps running the old code
            -- until it is restarted (OBS doesn't reload changed scripts itself).
            local applied, apply_err = Updater.apply_staged_update()
            if applied then
                last_check_result = "Update installed, but couldn't restart OBS automatically (" ..
                    tostring(relaunch_err) .. ") -- the new version loads after you restart OBS."
            else
                W.remove(path .. ".staged")
                last_check_result = "Couldn't install the update (" .. tostring(apply_err) .. ")."
            end
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            if resume then
                obs.obs_frontend_replay_buffer_start() -- we stopped it; put it back
            end
        end
        return true, nil
    end

    local install_waiter = nil
    local late_resume_timer = nil

    -- The Replay Buffer was stopped for an update that then did NOT happen (it was
    -- too slow to stop). If it finishes stopping afterwards, nobody would start it
    -- again -- so watch for that and start it, for up to ~60 seconds.
    local function resume_buffer_when_stopped()
        if late_resume_timer ~= nil then
            obs.timer_remove(late_resume_timer)
        end
        local tries = 0
        local t
        t = function()
            tries = tries + 1
            if obs.obs_frontend_replay_buffer_active() then
                if tries >= 60 then
                    obs.timer_remove(t)
                    late_resume_timer = nil
                end
                return -- still active / still stopping: keep waiting
            end
            obs.timer_remove(t)
            late_resume_timer = nil
            obs.obs_frontend_replay_buffer_start()
            obs.script_log(obs.LOG_INFO, "OBS Clip Suite: Replay Buffer started again after the cancelled update.")
        end
        late_resume_timer = t
        obs.timer_add(t, 1000)
    end
    function Updater.cancel_late_resume()
        if late_resume_timer ~= nil then
            obs.timer_remove(late_resume_timer)
            late_resume_timer = nil
        end
    end

    local function install_pending()
        local path, content = pending_update.path, pending_update.content
        local ok, err
        Restarter.abort()
        if sorter_available and obs.obs_frontend_replay_buffer_active() then
            -- Stop the buffer BEFORE touching the file, and only swap once it
            -- is really off, so the old instance can't keep saving clips.
            obs.obs_frontend_replay_buffer_stop()
            local tries = 0
            local waiter
            waiter = function()
                tries = tries + 1
                if not obs.obs_frontend_replay_buffer_active() then
                    obs.timer_remove(waiter)
                    install_waiter = nil
                    local ok2, err2 = do_install(path, content, true)
                    if not ok2 then
                        last_check_result = "Couldn't install the update automatically (" .. tostring(err2) ..
                            "). Get it here: " .. RELEASES_URL
                        -- Same fallback as the no-buffer path: keep the download somewhere writable.
                        local fb = fallback_update_path()
                        if fb and W.write_file(fb, content) then
                            last_check_result = last_check_result .. " The new version was also saved to " .. fb ..
                                " -- copy it over the old file yourself."
                        end
                        obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
                    end
                elseif tries >= 50 then -- ~10 seconds
                    obs.timer_remove(waiter)
                    install_waiter = nil
                    last_check_result = "The Replay Buffer wouldn't stop in time, so the update was NOT installed. " ..
                        "It will be offered again next time."
                    obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
                    -- It may still finish stopping a moment later: make sure it comes back.
                    resume_buffer_when_stopped()
                end
            end
            install_waiter = waiter
            obs.timer_add(waiter, 200)
            return true
        end
        ok, err = do_install(path, content, false)
        if ok then
            return true
        end

        -- Couldn't write over the script's own file -- almost always a
        -- Program Files permissions issue. Save the copy already fetched
        -- somewhere writable so all that's left is a manual copy-over.
        local fallback = fallback_update_path()
        local saved_fallback = false
        if fallback then
            saved_fallback = W.write_file(fallback, pending_update.content)
        end
        if saved_fallback then
            last_check_result = "Couldn't write the update over " .. tostring(pending_update.path) ..
                " (" .. tostring(err) .. "). The new version was saved to " .. fallback ..
                " -- copy it over the old file yourself, or reinstall from " .. RELEASES_URL .. "."
        else
            last_check_result = "Couldn't install the update automatically (" .. tostring(err) ..
                "). Get it here: " .. RELEASES_URL
        end
        obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
        return false
    end

    -- Returns true when the prompt was answered (in any way), false when it
    -- has to be postponed and retried later.
    local function offer_pending_update(force)
        if pending_update == nil then
            return true
        end

        -- Never interrupt a fullscreen game. Everything else in this script
        -- is built around not pulling a fullscreen-exclusive game out to
        -- the desktop; a topmost modal dialog would do exactly that, and at
        -- the worst possible moment. "force" is set only for the manual
        -- "Check for Updates Now" button, where the user is demonstrably
        -- sitting in the Scripts window.
        -- Same for a live stream / recording / virtual camera: "Yes" would cut
        -- them off, so the dialog waits until they are over.
        if not force and (Sorter.foreground_is_fullscreen() or outputs_are_active()) then
            return false
        end

        -- A dialog is already on screen (the modal one can let timers run):
        -- never open a second one on top of it.
        if Updater.prompt_open then
            return false
        end

        local message =
            "A new version of OBS Clip Suite is available.\n\n" ..
            "Your version:  " .. VERSION .. "\n" ..
            "New version:   " .. tostring(pending_update.version) .. "\n\n" ..
            "Yes     -  Install it now\n" ..
            "No      -  Skip this version (don't ask about it again)\n" ..
            "Cancel  -  Decide later (ask me again next time)\n\n" ..
            "Your current file is backed up next to it (.bak-" .. VERSION .. "),\n" ..
            "and the Scripts window has a \"Restore previous version\" button.\n\n" ..
            "Choosing Yes restarts OBS right away. The Replay Buffer is\n" ..
            "stopped first and started again automatically, but a live\n" ..
            "stream or recording will be cut off -- finish or save\n" ..
            "anything important first."

        Updater.prompt_open = true
        local ask_ok, answer = pcall(Sorter.ask_yes_no_cancel, message, "OBS Clip Suite - update available")
        Updater.prompt_open = false
        if not ask_ok then
            last_check_result = "Couldn't show the update dialog (" .. tostring(answer) .. ") -- nothing was changed."
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            pending_update = nil
            return true
        end
        -- The timer-driven path may have cleared the update while the dialog was open.
        if pending_update == nil then
            return true
        end

        if answer == nil then
            -- No dialog could be shown (non-Windows OBS, FFI unavailable).
            -- Falling back to installing without consent would be exactly
            -- the behaviour this change exists to remove, so just report it.
            last_check_result = "An update is available, but this system can't show the " ..
                "confirmation dialog -- nothing was changed. Get it here: " .. RELEASES_URL
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            pending_update = nil
            return true
        end

        if answer == Sorter.MB_IDYES then
            install_pending()
        elseif answer == Sorter.MB_IDNO then
            remember_skipped(pending_update.version)
            last_check_result = "Version " .. tostring(pending_update.version) .. " was skipped at your " ..
                "request. A newer release will still be offered."
            obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
        else
            last_check_result = "An update is available and was postponed -- you'll be asked " ..
                "again on the next check."
            obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
        end

        pending_update = nil
        return true
    end

    -- Retries a prompt that was held back because a game was fullscreen or a
    -- stream / recording was active.
    -- Gives up after MAX_PROMPT_ATTEMPTS so a machine left in a game
    -- overnight doesn't keep a timer alive forever; the update is simply
    -- offered again on the next check.
    retry_prompt = function()
        if pending_update == nil then
            obs.timer_remove(retry_prompt)
            return
        end
        prompt_attempts = prompt_attempts + 1
        if prompt_attempts > MAX_PROMPT_ATTEMPTS then
            obs.timer_remove(retry_prompt)
            pending_update = nil
            last_check_result = "An update is available but a fullscreen app or a stream/recording " ..
                "stayed active -- it'll be offered again next time."
            return
        end
        if offer_pending_update(false) then
            obs.timer_remove(retry_prompt)
        end
    end

    -- Retries an "auto" mode install that was held back because outputs
    -- were active or a game was fullscreen. Gives up after
    -- MAX_AUTO_INSTALL_ATTEMPTS so a PC left recording/streaming
    -- overnight doesn't keep a timer alive forever; the update is simply
    -- picked up on the next check instead.
    retry_auto_install = function()
        if pending_update == nil then
            obs.timer_remove(retry_auto_install)
            return
        end
        auto_install_attempts = auto_install_attempts + 1
        if auto_install_attempts > MAX_AUTO_INSTALL_ATTEMPTS then
            obs.timer_remove(retry_auto_install)
            pending_update = nil
            last_check_result = "An update was staged but outputs stayed active for too long -- " ..
                "it'll be picked up again on the next check."
            obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
            return
        end
        if outputs_are_active() or Sorter.foreground_is_fullscreen() then
            return
        end
        obs.timer_remove(retry_auto_install)
        install_pending()
        pending_update = nil
    end

