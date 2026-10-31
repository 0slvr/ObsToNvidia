----------------------------------------------------------------------
-- MODULE 1: Replay Buffer Restarter
----------------------------------------------------------------------
local Restarter = {}
do
    local enabled = true
    local teardown_until = 0 -- ms; the buffer is left alone until then

    local WATCHDOG_MS = 250
    local GRACE_MS = 1000        -- wait this long for the STOPPED event before polling instead
    local MAX_STOP_WAIT_MS = 8000
    local RETRY_BASE_MS = 250    -- start retries wait 250, 500, 1000, 2000 ms, then give up
    local MAX_RETRIES = 3
    local STALE_MS = 25000
    local TEARDOWN_MS = 30000

    local phase = "idle" -- "idle" | "stopping" | "starting"
    local phase_started, last_start, retries = 0, 0, 0
    local watchdog

    local function now() return obs.os_gettime_ns() / 1e6 end
    local function is_active() return obs.obs_frontend_replay_buffer_active() end
    local function tearing() return now() < teardown_until end

    local function finish(warning)
        obs.timer_remove(watchdog)
        phase = "idle"
        if warning then obs.script_log(obs.LOG_WARNING, "Replay Buffer Restarter: " .. warning) end
    end

    local function start_buffer(fresh)
        last_start = now()
        if fresh then
            phase, phase_started, retries = "starting", last_start, 0
        else
            retries = retries + 1
        end
        obs.obs_frontend_replay_buffer_start()
    end

    local function step()
        if tearing() then
            finish()
        elseif phase == "stopping" then
            local waited = now() - phase_started
            if waited >= GRACE_MS and not is_active() then
                start_buffer(true)
            elseif waited >= MAX_STOP_WAIT_MS then
                finish("the buffer did not stop in time -- restart skipped.")
            end
        elseif phase == "starting" then
            if is_active() then
                finish()
            elseif now() - last_start >= RETRY_BASE_MS * 2 ^ retries then
                if retries >= MAX_RETRIES then
                    finish("the buffer did not come back -- it may be OFF, start it manually.")
                else
                    start_buffer(false)
                end
            end
        else
            obs.timer_remove(watchdog)
        end
    end

    watchdog = function()
        local ok, err = pcall(step)
        if not ok then finish("internal error: " .. tostring(err)) end
    end

    -- Cancel any restart in progress and leave the buffer alone for a while
    -- (OBS exiting, collection switch, self-update stopping the buffer).
    function Restarter.abort(ms)
        teardown_until = now() + (ms or TEARDOWN_MS)
        finish()
    end

    function Restarter.on_replay_saved()
        if not enabled or tearing() or not is_active() then return end
        if phase ~= "idle" and now() - phase_started < STALE_MS then return end
        phase, phase_started = "stopping", now()
        obs.timer_remove(watchdog)
        obs.timer_add(watchdog, WATCHDOG_MS)
        obs.obs_frontend_replay_buffer_stop()
    end

    function Restarter.on_event(event)
        if event == obs.OBS_FRONTEND_EVENT_EXIT
            or event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN
            or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING then
            Restarter.abort()
        elseif event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then
            teardown_until = 0
        elseif phase ~= "idle" then
            if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
                finish()
            elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED and phase == "stopping" then
                start_buffer(true)
            end
        end
    end

    function Restarter.script_defaults(settings)
        obs.obs_data_set_default_bool(settings, "restart_buffer_after_save", true)
    end

    function Restarter.script_update(settings)
        enabled = obs.obs_data_get_bool(settings, "restart_buffer_after_save")
    end

    function Restarter.script_unload()
        obs.timer_remove(watchdog)
        local interrupted = phase ~= "idle" and not tearing()
        phase = "idle"
        if interrupted and not is_active() then
            obs.obs_frontend_replay_buffer_start()
        end
    end
end

