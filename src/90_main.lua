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

function script_properties()
    local props = obs.obs_properties_create()

    -- A checkable group's header checkbox is that module's on/off switch; its
    -- key is the one the module reads back in its own script_update.
    local restarter_group = obs.obs_properties_create()
    obs.obs_properties_add_group(props, "restart_buffer_after_save",
        "1) Replay Buffer Restarter", obs.OBS_GROUP_CHECKABLE, restarter_group)

    local sorter_group = obs.obs_properties_create()
    guard("Sorter.script_properties", Sorter.script_properties, sorter_group)
    obs.obs_properties_add_group(props, "sorter_enabled",
        "2) Replay Organizer", obs.OBS_GROUP_CHECKABLE, sorter_group)

    local alert_group = obs.obs_properties_create()
    guard("Alert.script_properties", Alert.script_properties, alert_group)
    obs.obs_properties_add_group(props, "alert_sound",
        "3) Clip Alert Sound", obs.OBS_GROUP_CHECKABLE, alert_group)

    -- Not checkable: it has its own "check automatically" checkbox inside.
    local updater_group = obs.obs_properties_create()
    guard("Updater.script_properties", Updater.script_properties, updater_group)
    obs.obs_properties_add_group(props, "updater_group",
        "4) Update Checker", obs.OBS_GROUP_NORMAL, updater_group)

    return props
end

-- Runs a lifecycle hook on every module, in this order, each under guard().
local MODULES = { { "Restarter", Restarter }, { "Alert", Alert }, { "Sorter", Sorter }, { "Updater", Updater } }
local function each_module(hook, ...)
    for _, m in ipairs(MODULES) do
        if m[2][hook] then guard(m[1] .. "." .. hook, m[2][hook], ...) end
    end
end

-- OBS only shows a description when the script defines a GLOBAL
-- script_description(); the per-module ones (Sorter/Alert/Updater) were never
-- called. Joins them in the same order as the groups in the Scripts window.
function script_description()
    local parts = {
        "<h3>1) Replay Buffer Restarter</h3><p>Restarts the Replay Buffer after every " ..
        "save so back-to-back clips never share overlapping footage.</p>",
    }
    for _, m in ipairs({ { "Sorter", Sorter }, { "Alert", Alert }, { "Updater", Updater } }) do
        if m[2].script_description then
            local ok, text = pcall(m[2].script_description)
            if ok and type(text) == "string" then parts[#parts + 1] = text end
        end
    end
    return table.concat(parts, "\n")
end

function script_defaults(settings) each_module("script_defaults", settings) end
function script_update(settings) each_module("script_update", settings) end

-- True in an OBS that is closing because of a self-update: stay passive.
local dormant_old_instance = false

local function on_frontend_event(event)
    if dormant_old_instance then return end
    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        -- Order matters: play the sound FIRST (it checks the clip is on disk at its
        -- original path, and must not wait for the Organizer, whose first-time Steam
        -- lookup can take seconds), then move the clip, then restart the buffer.
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
