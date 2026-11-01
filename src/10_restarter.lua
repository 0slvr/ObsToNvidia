----------------------------------------------------------------------
-- MODULE 1: Replay Buffer Restarter  (adaptive, event-driven, self-healing)
--
-- Nothing to configure. It watches what actually happens and adapts:
--  * Never stops the buffer while a save is still being written
--    (SAVING / SAVED events), so hotkey spam can't catch it mid-save.
--  * Bursts: if you save in quick succession it waits a short quiet period
--    taken from your own rhythm; a single save restarts at once.
--  * Learns the pause between "stopped" and "start again", and how long your
--    PC takes to start the buffer (retries are timed from that, so a slow start
--    is never "helped" with a second start call). The learned values are
--    saved with the script settings and survive an OBS restart.
--  * Leaves the buffer alone if YOU stop it while a restart is pending.
--  * Self-healing: if the buffer doesn't come back, it keeps trying in the
--    background (growing intervals) instead of silently staying OFF; it also
--    restarts the buffer if our own stop completes late, after we gave up waiting.
--  * Circuit breaker: after 3 restart cycles in a row that needed recovery it
--    pauses itself (and says so in the log) instead of fighting a broken setup.
--    Toggle the module off and on again to resume.
----------------------------------------------------------------------
local Restarter = {}
do
    local enabled = true
    local auto_paused = false      -- circuit breaker
    local teardown_until = 0       -- ms; the buffer is left alone until then
    local settings_ref = nil       -- script settings, used to persist what was learned

    local WATCHDOG_MS = 100
    local GRACE_MS = 1000          -- wait this long for the STOPPED event before polling instead
    local MAX_STOP_WAIT_MS = 8000
    local MAX_RETRIES = 3          -- normal start retries before background recovery takes over
    local STALE_MS = 25000
    local TEARDOWN_MS = 30000
    local OUR_STOP_WINDOW_MS = 60000
    local BURST_GAP_MS = 3000      -- two saves closer than this count as a burst
    local MIN_QUIET_MS = 300
    local MAX_QUIET_MS = 2500
    local MAX_SETTLE_MS = 2000
    local RECOVER_STEPS_MS = { 2000, 4000, 8000, 15000, 30000 }
    local MAX_RECOVER_TRIES = 12
    local BREAKER_LIMIT = 3

    local phase = "idle" -- "idle" | "waiting" | "stopping" | "starting" | "recovering"
    local phase_started, last_start, first_start_at, retries = 0, 0, 0, 0
    local watchdog

    local pending_saves, last_saving_at = 0, 0
    local save_times = {}      -- timestamps of the last few saves (ms)
    local quiet_until = 0
    local stopped_at = nil     -- STOPPED arrived but the learned settle time hasn't passed yet
    local our_stop_until = 0   -- a STOPPED event before this time is the result of OUR stop
    local recover_n, recover_next = 0, 0
    local consecutive_bad = 0
    local starting_seen = false -- OBS confirmed (STARTING event) that it is busy starting the buffer

    -- learned values (persisted)
    local settle_ms = 0        -- pause between stop and start
    local start_ms = 600       -- how long the buffer takes to start on this PC
    local repeat_rate = 0      -- how often one save is followed by another within BURST_GAP_MS (0..1)

    local function now() return obs.os_gettime_ns() / 1e6 end
    local function is_active() return obs.obs_frontend_replay_buffer_active() end
    local function tearing() return now() < teardown_until end

    local function save_learned()
        if settings_ref ~= nil then
            obs.obs_data_set_string(settings_ref, "restarter_learned",
                string.format("%.0f;%.3f;%.0f", settle_ms, repeat_rate, start_ms))
        end
    end

    local function load_learned(settings)
        local text = obs.obs_data_get_string(settings, "restarter_learned")
        local a, b, c = (text or ""):match("^(%d+);([%d%.]+);(%d+)$")
        if a then
            settle_ms = math.min(MAX_SETTLE_MS, tonumber(a))
            repeat_rate = math.min(1, tonumber(b))
            start_ms = math.min(10000, math.max(200, tonumber(c)))
        end
    end

    local function finish(warning, keep_stop_flag)
        obs.timer_remove(watchdog)
        phase = "idle"
        stopped_at = nil
        if not keep_stop_flag then our_stop_until = 0 end
        if warning then obs.script_log(obs.LOG_WARNING, "Replay Buffer Restarter: " .. warning) end
    end

    -- Learns from how the last restart went.
    local function tune(retries_needed, took_ms)
        if retries_needed > 0 then
            settle_ms = math.min(MAX_SETTLE_MS, math.max(250, settle_ms * 2))
        else
            settle_ms = settle_ms * 0.7
            if settle_ms < 50 then settle_ms = 0 end
            start_ms = math.min(10000, math.max(200, start_ms * 0.7 + took_ms * 0.3))
        end
        save_learned()
    end

    local function succeeded()
        local clean = retries == 0
        tune(retries, now() - first_start_at)
        if clean then consecutive_bad = 0 end
        finish()
    end

    local function start_buffer(fresh)
        last_start = now()
        if fresh then
            phase, phase_started, retries = "starting", last_start, 0
            first_start_at = last_start
        else
            retries = retries + 1
        end
        stopped_at = nil
        starting_seen = false
        obs.obs_frontend_replay_buffer_start()
    end

    -- The normal restart failed: keep trying in the background, with growing
    -- gaps, so the buffer is never silently left OFF.
    local function begin_recovery(reason)
        consecutive_bad = consecutive_bad + 1
        settle_ms = math.min(MAX_SETTLE_MS, math.max(500, settle_ms * 2))
        save_learned()
        phase, recover_n, recover_next = "recovering", 0, now()
        stopped_at = nil
        obs.script_log(obs.LOG_WARNING, "Replay Buffer Restarter: " .. reason ..
            " -- retrying in the background.")
        if consecutive_bad >= BREAKER_LIMIT then
            auto_paused = true
            obs.script_log(obs.LOG_WARNING,
                "Replay Buffer Restarter: restarts failed " .. consecutive_bad ..
                " times in a row -- auto-restart paused for this session. Untick and tick " ..
                "\"1) Replay Buffer Restarter\" to resume.")
        end
        obs.timer_remove(watchdog)
        obs.timer_add(watchdog, WATCHDOG_MS)
    end

    local function begin_stop()
        if not is_active() then
            return finish()
        end
        phase, phase_started = "stopping", now()
        stopped_at = nil
        our_stop_until = now() + OUR_STOP_WINDOW_MS
        obs.obs_frontend_replay_buffer_stop()
    end

    local function step()
        if tearing() then
            finish()
        elseif phase == "waiting" then
            if pending_saves > 0 then
                if now() - last_saving_at > STALE_MS then
                    pending_saves = 0 -- a SAVED event got lost; don't wait forever
                else
                    return
                end
            end
            if now() >= quiet_until then
                begin_stop()
            end
        elseif phase == "stopping" then
            local waited = now() - phase_started
            if stopped_at then
                if now() - stopped_at >= settle_ms then
                    start_buffer(true)
                end
            elseif waited >= GRACE_MS and not is_active() then
                start_buffer(true)
            elseif waited >= MAX_STOP_WAIT_MS then
                -- Still not stopped. Leave it (a running buffer is harmless); if
                -- our stop completes later, on_event() restarts it.
                finish("the buffer did not stop in time -- restart skipped.", true)
            end
        elseif phase == "starting" then
            if is_active() then
                succeeded()
            else
                -- Retries are timed from how long a start normally takes here, so a
                -- slow-but-working start never gets a second start call on top of it.
                local wait = math.max(800, start_ms * 2) * 2 ^ retries
                if starting_seen then wait = math.max(wait, 8000) end -- OBS says it IS starting: just wait
                if now() - last_start >= wait then
                    if retries >= MAX_RETRIES then
                        begin_recovery("the buffer did not come back")
                    else
                        start_buffer(false)
                    end
                end
            end
        elseif phase == "recovering" then
            if is_active() then
                obs.script_log(obs.LOG_INFO, "Replay Buffer Restarter: the buffer is running again.")
                finish()
            elseif now() >= recover_next then
                if recover_n >= MAX_RECOVER_TRIES then
                    finish("gave up restarting the Replay Buffer -- start it manually.")
                else
                    recover_n = recover_n + 1
                    recover_next = now() + RECOVER_STEPS_MS[math.min(recover_n, #RECOVER_STEPS_MS)]
                    obs.obs_frontend_replay_buffer_start()
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
        pending_saves = 0
        finish()
    end

    function Restarter.on_replay_saved()
        if pending_saves > 0 then pending_saves = pending_saves - 1 end
        if not enabled or auto_paused or tearing() or not is_active() then return end
        if phase == "stopping" or phase == "starting" or phase == "recovering" then
            if now() - phase_started < STALE_MS then return end
        end

        -- Burst detection: how fast were the last saves pressed?
        local n = #save_times
        local quiet = 0
        if n >= 2 then
            local gap = save_times[n] - save_times[n - 1]
            if gap < BURST_GAP_MS then
                quiet = math.min(MAX_QUIET_MS, math.max(MIN_QUIET_MS, gap * 0.9))
            end
        end
        -- If you often press twice in a row, keep a short habit-based pause even
        -- for the first press of a burst (a restart would eat the second press).
        if repeat_rate > 0.25 then
            quiet = math.max(quiet, math.min(MAX_QUIET_MS, repeat_rate * 900))
        end
        quiet_until = now() + quiet

        phase, phase_started = "waiting", now()
        obs.timer_remove(watchdog)
        obs.timer_add(watchdog, WATCHDOG_MS)
        -- The stop is deliberately NOT issued from inside this event callback: it
        -- runs from the watchdog timer (next tick, <= 100 ms later), once OBS has
        -- finished delivering the SAVED event and the muxer has let go of the file.
    end

    function Restarter.on_event(event)
        if event == obs.OBS_FRONTEND_EVENT_EXIT
            or event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN
            or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING then
            Restarter.abort()
        elseif event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then
            teardown_until = 0
        elseif obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING ~= nil
            and event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING then
            -- A save has begun (OBS 30.2+; on older versions this event doesn't
            -- exist and the module simply relies on the quiet period).
            local t = now()
            if pending_saves > 0 and t - last_saving_at <= STALE_MS then
                -- OBS writes one clip at a time and ignores save presses (key held,
                -- double press) while one is being written -- yet still announces each
                -- press with SAVING. Those never get a SAVED event, so counting them
                -- left the restarter waiting for saves that never finish (and treating
                -- every press as a new burst), i.e. no restart for ~25 s after a spam.
                return
            end
            if #save_times > 0 then
                local followed = (t - save_times[#save_times]) < BURST_GAP_MS and 1 or 0
                repeat_rate = repeat_rate * 0.8 + followed * 0.2
            end
            pending_saves = pending_saves + 1
            last_saving_at = t
            save_times[#save_times + 1] = t
            if #save_times > 4 then table.remove(save_times, 1) end
            if phase == "waiting" then
                quiet_until = math.huge -- recomputed when this save finishes
            end
        elseif phase == "waiting" then
            -- Someone stopped the buffer while our restart was pending: that was
            -- you, not us. Leave it stopped.
            if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPING
                or event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
                finish()
            end
        elseif phase == "starting" or phase == "stopping" then
            if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTING then
                starting_seen = true
            elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
                succeeded()
            elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED and phase == "starting" then
                starting_seen = false   -- that start attempt ended without a running buffer: normal retry timing
            elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED and phase == "stopping" then
                if settle_ms > 0 then
                    stopped_at = now()   -- the watchdog starts it once the learned pause is over
                else
                    start_buffer(true)
                end
            end
        elseif phase == "idle" and event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED
            and now() < our_stop_until and enabled and not auto_paused and not tearing() then
            -- Our stop finished late (after we stopped waiting for it): bring the buffer back.
            our_stop_until = 0
            begin_recovery("the buffer stopped late after a restart request")
        end
    end

    function Restarter.script_defaults(settings)
        obs.obs_data_set_default_bool(settings, "restart_buffer_after_save", true)
        obs.obs_data_set_default_string(settings, "restarter_learned", "")
    end

    function Restarter.script_update(settings)
        local was_enabled = enabled
        settings_ref = settings
        enabled = obs.obs_data_get_bool(settings, "restart_buffer_after_save")
        if enabled and not was_enabled then
            auto_paused, consecutive_bad = false, 0   -- ticking the box again resumes it
        end
        load_learned(settings)
    end

    function Restarter.script_unload()
        obs.timer_remove(watchdog)
        local interrupted = (phase == "stopping" or phase == "starting" or phase == "recovering")
            and not tearing()
        phase = "idle"
        settings_ref = nil
        if interrupted and not is_active() then
            obs.obs_frontend_replay_buffer_start()
        end
    end
end
