    -- manual = true when triggered from the "Check for Updates Now"
    -- button (always logs a result, even "up to date"); false when
    -- triggered automatically on script_load (stays quiet unless a
    -- newer version is actually found, so a normal OBS launch with no
    -- update doesn't spam the log every time).
    function Updater.check_for_updates(manual)
        if Updater.prompt_open then
            return -- an update/restore dialog is already on screen
        end
        local own_path, local_content = read_own_script()
        if not local_content then
            last_check_result = "Couldn't read this script's own file from disk -- skipped."
            if manual then
                obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            end
            return
        end

        -- The Organizer owns the WinHTTP plumbing; if it couldn't
        -- initialise (non-Windows OBS, no FFI) there is nothing to call.
        if type(Sorter.https_get) ~= "function" then
            last_check_result = "Update checking needs the Windows networking layer, which isn't available here."
            if manual then
                obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            end
            return
        end

        -- Step 1: a tiny probe. Only the first 4 KB of the release file is
        -- requested (HTTP Range) -- enough to contain the VERSION line near
        -- the top. This is what runs on every OBS start, so a slow
        -- connection costs a few seconds at most instead of a full ~290 KB
        -- download on OBS's UI thread.
        local probe = Sorter.https_get(GITHUB_HOST, LATEST_ASSET_PATH, VERSION_PROBE_TIMEOUTS)
        local probe_version = probe and extract_version(probe) or nil
        if probe_version ~= nil then
            if compare_versions(probe_version, VERSION) <= 0 then
                if compare_versions(probe_version, VERSION) == 0 then
                    last_check_result = "Up to date -- you have version " .. VERSION ..
                        ", the same as the latest Release."
                else
                    last_check_result = "You have version " .. VERSION .. ", which is newer than the latest " ..
                        "Release (" .. probe_version .. ") -- nothing to install."
                end
                if manual then
                    obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
                end
                return
            end
            if skipped_version ~= "" and skipped_version == probe_version then
                last_check_result = "Version " .. probe_version .. " is available, but you chose to skip it. " ..
                    "Use \"Un-skip\" or Check for Updates Now to reconsider it."
                if manual then
                    obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
                end
                return
            end
        elseif not manual then
            -- Probe failed (offline / GitHub unreachable) on the automatic
            -- startup check: don't escalate to a big download, just try
            -- again at the next start.
            last_check_result = "Couldn't reach GitHub for the startup update check (offline?) -- will retry next time."
            return
        end

        -- Step 2: a newer version exists (or this is a manual check whose
        -- probe couldn't read a version): download the whole script.
        -- If the server ignored the Range header and the probe already
        -- returned the whole file, there's no need to download it again.
        local remote_content = (probe and #probe >= 50000) and probe
            or Sorter.https_get(GITHUB_HOST, LATEST_ASSET_PATH, SCRIPT_DL_TIMEOUTS)
        if not remote_content then
            last_check_result = "Couldn't reach GitHub to check for updates (offline, or no " ..
                "Release with a '" .. SCRIPT_FILENAME .. "' asset exists yet)."
            if manual then
                obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            end
            return
        end

        -- Anything that isn't this script produces garbage below: a
        -- captive-portal login page, a GitHub error page, a transfer that
        -- ended early.
        local valid, reject_reason = looks_like_this_script(remote_content)
        if not valid then
            last_check_result = "Got a response from GitHub, but it wasn't a usable copy of the " ..
                "script (" .. tostring(reject_reason) .. ") -- nothing was changed. " ..
                "Check manually at " .. RELEASES_URL
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            return
        end

        local remote_version = extract_version(remote_content)
        if remote_version == nil then
            last_check_result = "The latest Release has no version number in it, so it can't be " ..
                "compared with yours (" .. VERSION .. ") -- nothing was changed."
            if manual then
                obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            end
            return
        end

        local cmp = compare_versions(remote_version, VERSION)
        if cmp <= 0 then
            if cmp == 0 then
                last_check_result = "Up to date -- you have version " .. VERSION ..
                    ", the same as the latest Release."
            else
                last_check_result = "You have version " .. VERSION .. ", which is newer than the latest " ..
                    "Release (" .. remote_version .. ") -- nothing to install."
            end
            if manual then
                obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
            end
            return
        end

        -- The user already said no to exactly this version.
        if skipped_version ~= "" and skipped_version == remote_version then
            last_check_result = "Version " .. remote_version .. " is available, but you chose to skip it. " ..
                "Use \"Un-skip\" or Check for Updates Now to reconsider it."
            if manual then
                obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
            end
            return
        end

        if update_mode == "notify" then
            last_check_result = "Version " .. remote_version .. " is available on GitHub (you have " ..
                VERSION .. "). Get it here: " .. RELEASES_URL
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            return
        end

        pending_update = {
            path = own_path,
            content = remote_content,
            version = remote_version,
        }

        if update_mode == "auto" then
            -- Explicitly opted into installing without being asked --
            -- but that consent covers installing unattended, not
            -- cutting off a live stream / recording / virtual camera or
            -- yanking a fullscreen game to the desktop. (The Replay
            -- Buffer does not hold it back: the installer stops it and
            -- the new OBS starts it again.) relaunch_obs()
            -- posts C.WM_CLOSE, and if outputs are active OBS's own
            -- shutdown path pops its "Active Outputs" confirmation --
            -- a modal dialog nobody is there to answer during an
            -- unattended auto-install. So: hold off and retry later
            -- instead, the same way "ask" mode already holds off a
            -- fullscreen prompt.
            auto_install_attempts = 0
            if outputs_are_active() or Sorter.foreground_is_fullscreen() then
                last_check_result = "An update is staged but is being held back because a " ..
                    "stream/recording is active (or a game is fullscreen) -- " ..
                    "it'll install automatically once that's no longer the case."
                obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
                obs.timer_remove(retry_auto_install)
                obs.timer_add(retry_auto_install, AUTO_INSTALL_RETRY_MS)
                return
            end
            install_pending()
            pending_update = nil
            return
        end

        -- "ask" -- the default. If a fullscreen game is up, hold the
        -- dialog back and keep trying on a timer instead of stealing
        -- focus mid-game.
        prompt_attempts = 0
        if not offer_pending_update(manual) then
            last_check_result = "Version " .. remote_version .. " is available -- you'll be asked as " ..
                "soon as you're out of fullscreen and no stream/recording is running."
            obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
            obs.timer_remove(retry_prompt)
            obs.timer_add(retry_prompt, PROMPT_RETRY_MS)
        end
    end

    -- One-shot delayed check on load, via a timer rather than a direct
    -- call from script_load. script_load runs synchronously while OBS
    -- is still starting up, so a blocking network call there would hold
    -- up OBS's own startup; firing it a few seconds later off a timer
    -- keeps load-time itself instant.
    update_checker = function()
        obs.timer_remove(update_checker)
        if check_on_load then
            Updater.check_for_updates(false)
        end
    end

    -- Puts the backup made by the last update back in place (validated like
    -- any other candidate, and the file being replaced is itself backed up
    -- first), then restarts OBS the same way an update does. This is the
    -- manual rollback for an update that compiles but misbehaves.
    function Updater.restore_previous_version()
        local backup_path = updater_settings and obs.obs_data_get_string(updater_settings, "last_backup_path") or ""
        if backup_path == "" then
            last_check_result = "No backup recorded -- nothing to restore."
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            return
        end
        local own_path = read_own_script()
        local backup_content = W.read_file(backup_path)
        if not own_path or not backup_content then
            last_check_result = "Couldn't read the backup (" .. backup_path .. ") -- nothing was changed."
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            return
        end
        local backup_version = extract_version(backup_content) or "previous"
        -- Restoring to something OLDER than WAIT_PROTOCOL_VERSION: that version
        -- doesn't know the "wait for the old OBS to exit" restart, so a relaunch
        -- would make two OBS instances fight over the Replay Buffer. For those,
        -- the file is swapped in place and OBS reloads the script by itself.
        local old_protocol = backup_version ~= "previous"
            and compare_versions(backup_version, WAIT_PROTOCOL_VERSION) < 0
        local message
        if old_protocol then
            message = "Restore OBS Clip Suite version " .. backup_version .. " (you are on " .. VERSION .. ")?\n\n" ..
                "This is an older version, so OBS is NOT restarted: the file is\n" ..
                "replaced and the script reloads by itself (restart OBS yourself\n" ..
                "if it doesn't).\n\n" ..
                "Yes  -  Restore it\n" ..
                "No / Cancel  -  Do nothing"
        else
            message = "Restore OBS Clip Suite version " .. backup_version .. " (you are on " .. VERSION .. ")?\n\n" ..
                "Yes  -  Restore it and restart OBS now (the Replay Buffer is stopped and resumed)\n" ..
                "No / Cancel  -  Do nothing"
        end
        if Updater.prompt_open then
            return
        end
        Updater.prompt_open = true
        local ask_ok, answer = pcall(Sorter.ask_yes_no_cancel, message, "OBS Clip Suite - restore previous version")
        Updater.prompt_open = false
        if not ask_ok or answer ~= Sorter.MB_IDYES then
            return
        end

        -- Going back to an older version: the newer one is still on GitHub, so
        -- the next check would offer it again within seconds. Put the version
        -- we are leaving on the "skipped" list so that doesn't happen. (A still
        -- newer release is offered normally; "Un-skip" undoes this.)
        if compare_versions(VERSION, backup_version) > 0 then
            remember_skipped(VERSION)
        end

        if old_protocol then
            local ok, err = write_updated_script(own_path, backup_content)
            if ok then
                if err and updater_settings ~= nil then
                    obs.obs_data_set_string(updater_settings, "last_backup_path", err)
                end
                last_check_result = "Restored version " .. backup_version .. " -- the script is reloading " ..
                    "(restart OBS if it doesn't)."
            else
                last_check_result = "Couldn't restore the previous version (" .. tostring(err) .. ")."
            end
            obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
            return
        end

        pending_update = { path = own_path, content = backup_content, version = backup_version }
        -- This writes the current file to its own .bak-<version> first, so
        -- restoring is itself reversible.
        install_pending()
        pending_update = nil
    end

    function Updater.script_description()
        return "<h3>4) Update Checker</h3>"
    end

    function Updater.script_properties(props)
        obs.obs_properties_add_bool(props, "check_updates_on_load",
            "Check for updates automatically when OBS starts")

        -- Installing over the user's own script file without asking is a
        -- big thing to do silently, so asking is the default; the
        -- unattended behaviour is available for anyone who deliberately
        -- wants it.
        local mode = obs.obs_properties_add_list(props, "update_mode",
            "When an update is found", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
        obs.obs_property_list_add_string(mode, "Ask me first (recommended)", "ask")
        obs.obs_property_list_add_string(mode, "Install it automatically", "auto")
        obs.obs_property_list_add_string(mode, "Only mention it in the log", "notify")

        -- Hidden: remembers which version was skipped via the dialog's
        -- "No" button, so the answer survives an OBS restart. Not something
        -- to edit by hand, but it must live in the saved settings to
        -- persist at all.
        local skipped = obs.obs_properties_add_text(props, "skipped_update_version",
            "Skipped version", obs.OBS_TEXT_DEFAULT)
        obs.obs_property_set_visible(skipped, false)

        obs.obs_properties_add_button(props, "clear_skipped_btn", "Un-skip the version I skipped",
            function()
                if updater_settings ~= nil then
                    obs.obs_data_set_string(updater_settings, "skipped_update_version", "")
                end
                skipped_version = ""
                last_check_result = "Skipped version cleared -- it will be offered again on the next check."
                obs.script_log(obs.LOG_INFO, "OBS Clip Suite: " .. last_check_result)
                return true
            end)

        obs.obs_properties_add_button(props, "restore_backup_btn", "Restore previous version",
            function()
                Updater.restore_previous_version()
                return true
            end)

        obs.obs_properties_add_button(props, "check_updates_btn", "Check for Updates Now",
            function()
                Updater.check_for_updates(true)
                return true -- true = refresh the properties UI so the status line below updates
            end)

        local status = obs.obs_properties_add_text(props, "update_status",
            "Version " .. VERSION .. " -- last check: " .. last_check_result,
            obs.OBS_TEXT_INFO)
        obs.obs_property_set_enabled(status, false)
    end

    function Updater.script_defaults(settings)
        obs.obs_data_set_default_bool(settings, "check_updates_on_load", true)
        obs.obs_data_set_default_string(settings, "update_mode", "ask")
        obs.obs_data_set_default_string(settings, "skipped_update_version", "")
        obs.obs_data_set_default_string(settings, "last_backup_path", "")
        obs.obs_data_set_default_string(settings, "backup_list", "")
    end

    function Updater.script_update(settings)
        updater_settings = settings
        check_on_load = obs.obs_data_get_bool(settings, "check_updates_on_load")
        skipped_version = obs.obs_data_get_string(settings, "skipped_update_version") or ""

        update_mode = obs.obs_data_get_string(settings, "update_mode")
        if update_mode ~= "ask" and update_mode ~= "auto" and update_mode ~= "notify" then
            update_mode = "ask"
        end
    end

    -- ".staged" / ".new" files left behind by an interrupted update. Only called
    -- when no update is in progress (no marker), so nothing live is deleted.
    function Updater.cleanup_leftovers()
        local path = read_own_script()
        if not path then return end
        for _, suffix in ipairs({ ".staged", ".new" }) do
            if W.exists(path .. suffix) then
                W.remove(path .. suffix)
                obs.script_log(obs.LOG_INFO, "OBS Clip Suite: removed a leftover " .. suffix .. " file from an interrupted update.")
            end
        end
    end

    function Updater.script_load()
        Updater.cleanup_leftovers()
        -- 10 seconds after load: the check can end in a modal dialog, and
        -- a few seconds in, OBS is often still bringing up its UI, loading
        -- the scene collection and starting outputs -- a topmost window
        -- landing in the middle of that is both jarring and easy to
        -- dismiss by accident. This also gives the network stack more room
        -- to come up, so the first check is less likely to fail outright.
        obs.timer_add(update_checker, 10000)
    end

    function Updater.script_unload()
        obs.timer_remove(update_checker)
        -- A deferred prompt must not outlive the script, or its timer would
        -- keep firing against a dead module after a reload.
        obs.timer_remove(retry_prompt)
        obs.timer_remove(retry_auto_install)
        Updater.cancel_late_resume()
        Updater.prompt_open = false
        if install_waiter ~= nil then
            obs.timer_remove(install_waiter)
            install_waiter = nil
        end
        pending_update = nil
        updater_settings = nil
    end
end

