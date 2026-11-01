----------------------------------------------------------------------
-- OBS lifecycle hooks
----------------------------------------------------------------------

-- Runs fn(...) under pcall so an error in one module can't skip the others
-- (or the Replay Buffer resume). Returns true on success.
local function guard(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        obs.script_log(obs.LOG_ERROR, "OBS Clip Suite: " .. what .. " failed: " .. tostring(err))
    end
    return ok
end

-- Last settings OBS gave us; used to decide which rows to show when the
-- window is built (OBS calls script_properties() without them).
local ui_settings = nil

-- Rows that only make sense while their feature's checkbox is on.
local SORTER_ROWS = { "steam_lookup_enabled", "new_rename", "add_mapping_btn" }
local ALERT_ROWS = { "clip_toast", "selected_sound_id", "custom_sound_path", "alert_volume", "test_alert_button" }

-- "fallbacks" are the section objects: used if the property isn't found from
-- the top level.
local function set_rows_visible(props, fallbacks, names, visible)
    for _, name in ipairs(names) do
        local prop = obs.obs_properties_get(props, name)
        if prop == nil then
            for _, grp in ipairs(fallbacks) do
                prop = obs.obs_properties_get(grp, name)
                if prop ~= nil then break end
            end
        end
        if prop ~= nil then
            -- Hidden while the feature's checkbox is off.
            obs.obs_property_set_visible(prop, visible)
        end
    end
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Three separate sections (Clips, Alerts, Updates). A feature's own rows are
    -- hidden while its checkbox is off. Each module's on/off switch is a plain
    -- checkbox; the keys are the same ones the modules read in script_update.
    local clips = obs.obs_properties_create()
    local alerts = obs.obs_properties_create()
    local updates = obs.obs_properties_create()
    local sections = { clips, alerts, updates }

    obs.obs_properties_add_bool(clips, "restart_buffer_after_save",
        "Restart the Replay Buffer after every save")
    local sort_cb = obs.obs_properties_add_bool(clips, "sorter_enabled",
        "Sort clips into a folder per game")
    guard("Sorter.script_properties", Sorter.script_properties, clips)

    local alert_cb = obs.obs_properties_add_bool(alerts, "alert_sound",
        "Play a sound when a clip is saved")
    guard("Toast.script_properties", Toast.script_properties, alerts)   -- right under the sound checkbox
    guard("Alert.script_properties", Alert.script_properties, alerts)

    guard("Updater.script_properties", Updater.script_properties, updates)

    -- Drop the text labels on the left (they push every checkbox to the right
    -- and clutter the window). What each row is stays clear from its content.
    local function relabel(section, name, text)
        local prop = obs.obs_properties_get(section, name)
        if prop ~= nil then obs.obs_property_set_description(prop, text) end
    end
    relabel(clips, "new_rename", "")
    relabel(clips, "add_mapping_btn", "Add rename  (type: old folder name = new name)")
    relabel(alerts, "selected_sound_id", "")
    relabel(alerts, "custom_sound_path", "")
    relabel(alerts, "alert_volume", "")
    relabel(updates, "update_mode", "")
    local vol = obs.obs_properties_get(alerts, "alert_volume")
    if vol ~= nil then obs.obs_property_float_set_suffix(vol, "% volume") end

    obs.obs_property_set_modified_callback(sort_cb, function(p, _prop, settings)
        pcall(set_rows_visible, p, sections, SORTER_ROWS, obs.obs_data_get_bool(settings, "sorter_enabled"))
        return true
    end)
    obs.obs_property_set_modified_callback(alert_cb, function(p, _prop, settings)
        pcall(set_rows_visible, p, sections, ALERT_ROWS, obs.obs_data_get_bool(settings, "alert_sound"))
        return true
    end)

    if ui_settings ~= nil then
        pcall(set_rows_visible, clips, sections, SORTER_ROWS, obs.obs_data_get_bool(ui_settings, "sorter_enabled"))
        pcall(set_rows_visible, alerts, sections, ALERT_ROWS, obs.obs_data_get_bool(ui_settings, "alert_sound"))
    end

    obs.obs_properties_add_group(props, "clips_group", "Clips", obs.OBS_GROUP_NORMAL, clips)
    obs.obs_properties_add_group(props, "alerts_group", "Alerts", obs.OBS_GROUP_NORMAL, alerts)
    obs.obs_properties_add_group(props, "updates_group", "Updates", obs.OBS_GROUP_NORMAL, updates)
    return props
end

-- Runs a lifecycle hook on every module, in this order, each under guard().
local MODULES = { { "Restarter", Restarter }, { "Alert", Alert }, { "Sorter", Sorter }, { "Updater", Updater }, { "Toast", Toast } }
local function each_module(hook, ...)
    for _, m in ipairs(MODULES) do
        if m[2][hook] then guard(m[1] .. "." .. hook, m[2][hook], ...) end
    end
end

-- No global script_description() on purpose: the Scripts window shows no
-- description text above the settings groups.

function script_defaults(settings) each_module("script_defaults", settings) end
function script_update(settings)
    ui_settings = settings
    each_module("script_update", settings)
end

-- True in an OBS that is closing because of a self-update: stay passive.
local dormant_old_instance = false

local function on_frontend_event(event)
    if dormant_old_instance then return end
    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        -- Order matters: play the sound FIRST (it checks the clip is on disk at its
        -- original path, and must not wait for the Organizer, whose first-time Steam
        -- lookup can take seconds), then move the clip, then restart the buffer.
        guard("Toast.on_replay_saved", Toast.on_replay_saved)
        guard("Alert.on_replay_saved", Alert.on_replay_saved)
        guard("Sorter.on_replay_saved", Sorter.on_replay_saved)
        guard("Restarter.on_replay_saved", Restarter.on_replay_saved)
    end
    -- Every event reaches the Restarter so it can follow STOPPED / STARTED.
    guard("Restarter.on_event", Restarter.on_event, event)
end

-- Is the process with this PID still running?
local function process_is_running(pid)
    if not sorter_available then return false end
    local h = kernel32.OpenProcess(0x00100000, 0, pid) -- SYNCHRONIZE
    if h == nil then
        -- Access denied (5) means it exists but belongs to a higher-privilege
        -- process (e.g. OBS run as admin): still running. Anything else: gone.
        return C.last_error() == 5
    end
    local r = kernel32.WaitForSingleObject(h, 0)
    kernel32.CloseHandle(h)
    return r == 0x102 -- WAIT_TIMEOUT: still running
end

-- New instance launched by a self-update: WAIT until the old OBS has really
-- exited, then (1) swap in the staged script, if any, and restart OBS once more
-- (OBS doesn't reload a changed script by itself); the last OBS lands back here
-- with nothing staged and (2) starts the Replay Buffer and confirms it.
local function resume_replay_buffer_after_relaunch(marker)
    local MAX_WAIT_S = 180   -- the old OBS may be sitting on a "quit?" prompt
    local MAX_RETRIES = 8
    local state = "waiting"  -- "waiting" -> "relaunch_wait" -> "relaunching" (or "applied" -> "starting")
    local waited_s, applied_s, retries, warned = 0, 0, 0, false
    local relaunch_tries = 0
    local tick

    local function stop() obs.timer_remove(tick) end

    local function begin_resume()
        state = "starting"
        remove_update_marker()
        if not marker.resume or obs.obs_frontend_replay_buffer_active() then
            return stop()
        end
        obs.obs_frontend_replay_buffer_start()
    end

    local function poll()
        if state == "waiting" then
            if process_is_running(marker.pid) then
                waited_s = waited_s + 1
                if not warned and waited_s >= 10 then
                    warned = true
                    obs.script_log(obs.LOG_WARNING,
                        "OBS Clip Suite: the previous OBS window is still open -- close it " ..
                        "(confirm the quit prompt) and the update will finish here.")
                end
                if waited_s >= MAX_WAIT_S then
                    stop()
                    remove_update_marker()
                    obs.script_log(obs.LOG_WARNING,
                        "OBS Clip Suite: the previous OBS never closed -- the update was NOT applied and " ..
                        "the Replay Buffer was NOT started here, to avoid double clips. Close the old " ..
                        "OBS and reload this script.")
                end
                return
            end
            -- The old OBS is gone: swap the staged script in now.
            if Updater.has_staged_update() then
                local ok, err = Updater.apply_staged_update()
                if ok then
                    -- OBS does not reload a script that changed on disk, so restart
                    -- once more: a third OBS loads the new file, waits for THIS one to
                    -- exit (the marker now holds this PID) and resumes the buffer.
                    obs.script_log(obs.LOG_INFO, "OBS Clip Suite: update applied -- restarting OBS once more to load it.")
                    state = "relaunch_wait"
                    relaunch_tries = 0
                    return
                end
                obs.script_log(obs.LOG_WARNING,
                    "OBS Clip Suite: couldn't apply the staged update (" .. tostring(err) .. ").")
            end
            return begin_resume()
        elseif state == "relaunch_wait" then
            -- This OBS is still starting up: its main window may not exist yet, so
            -- "couldn't find OBS's own main window" is normal for the first seconds.
            -- Keep trying (up to ~60 s) instead of giving up and leaving two OBS running.
            local rok, rerr = Updater.relaunch_obs(marker.resume)
            if rok then
                dormant_old_instance = true -- this OBS is closing: stay passive
                Restarter.abort()
                state = "relaunching"
                return
            end
            relaunch_tries = relaunch_tries + 1
            local transient = tostring(rerr):find("main window", 1, true) ~= nil
            if transient and relaunch_tries < 60 then
                return
            end
            obs.script_log(obs.LOG_WARNING,
                "OBS Clip Suite: couldn't restart OBS again (" .. tostring(rerr) .. ").")
            state = "applied" -- fall back: keep running, resume the buffer
            return
        elseif state == "relaunching" then
            return -- the next OBS takes over; nothing to do here
        elseif state == "applied" then
            -- The extra restart failed: carry on with what is in memory rather than leave the buffer off.
            applied_s = applied_s + 1
            if applied_s >= 5 then
                obs.script_log(obs.LOG_WARNING,
                    "OBS Clip Suite: the update is installed but OBS wasn't restarted -- restart OBS to use the new version.")
                begin_resume()
            end
            return
        end

        if obs.obs_frontend_replay_buffer_active() then
            stop()
            obs.script_log(obs.LOG_INFO,
                "OBS Clip Suite: Replay Buffer resumed after the self-update restart.")
            return
        end
        retries = retries + 1
        if retries > MAX_RETRIES then
            stop()
            obs.script_log(obs.LOG_WARNING,
                "OBS Clip Suite: couldn't confirm the Replay Buffer restarted after the " ..
                "self-update relaunch -- start it manually if it isn't already running.")
            return
        end
        obs.obs_frontend_replay_buffer_start()
    end

    -- An error must end the timer, not repeat every second forever.
    tick = function()
        local ok, err = pcall(poll)
        if not ok then
            stop()
            obs.script_log(obs.LOG_ERROR, "OBS Clip Suite: update resume failed: " .. tostring(err) ..
                " -- start the Replay Buffer manually if needed.")
        end
    end
    obs.timer_add(tick, 1000)
end

function script_load(settings)
    print("OBS Clip Suite v" .. VERSION .. " loaded (games-only organizer)")
    obs.obs_frontend_add_event_callback(on_frontend_event)
    guard("Sorter.script_load", Sorter.script_load)

    local marker
    if sorter_available then
        local ok, m = pcall(read_update_marker)
        marker = ok and m or nil
    end
    if marker and marker.pid == tonumber(kernel32.GetCurrentProcessId()) then
        -- This is the OLD instance, already on its way out. Stay passive:
        -- no update check, no resume, marker left for the new OBS.
        dormant_old_instance = true
        Restarter.abort()
        obs.script_log(obs.LOG_INFO, "OBS Clip Suite: update in progress -- this OBS stays passive.")
        return
    end

    -- Right after an update there is nothing to check for: just resume the buffer.
    if marker then
        guard("update resume", resume_replay_buffer_after_relaunch, marker)
    else
        guard("Updater.script_load", Updater.script_load)
    end
end

function script_unload()
    obs.obs_frontend_remove_event_callback(on_frontend_event)
    each_module("script_unload")
end
