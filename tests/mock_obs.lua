-- A tiny fake of OBS's Lua API with a VIRTUAL clock and timers, so the real
-- source parts can be run and timed in milliseconds without OBS.
local M = {}

function M.new()
    local o = {}
    local clock_ns = 0
    local timers = {}      -- fn -> { ms = interval, due = ns }
    local queue = {}       -- scheduled frontend events { at = ns, fn = function }
    local settings = {}
    local state = { active = true, streaming = false, recording = false }
    o.state, o.calls, o.logs = state, { start = {}, stop = {} }, {}

    o.LOG_INFO, o.LOG_WARNING, o.LOG_ERROR = 1, 2, 3
    local names = { "REPLAY_BUFFER_SAVING", "REPLAY_BUFFER_SAVED", "REPLAY_BUFFER_STARTING",
        "REPLAY_BUFFER_STARTED", "REPLAY_BUFFER_STOPPING", "REPLAY_BUFFER_STOPPED", "EXIT",
        "SCRIPTING_SHUTDOWN", "SCENE_COLLECTION_CHANGING", "SCENE_COLLECTION_CHANGED" }
    for i, n in ipairs(names) do o["OBS_FRONTEND_EVENT_" .. n] = i end

    function o.os_gettime_ns() return clock_ns end
    function o.timer_add(fn, ms) timers[fn] = { ms = ms, due = clock_ns + ms * 1e6 } end
    function o.timer_remove(fn) timers[fn] = nil end
    function o.script_log(level, text) o.logs[#o.logs + 1] = text end
    function o.obs_frontend_replay_buffer_active() return state.active end
    function o.obs_frontend_streaming_active() return state.streaming end
    function o.obs_frontend_recording_active() return state.recording end
    function o.obs_data_set_default_bool() end
    function o.obs_data_set_default_string() end
    function o.obs_data_set_string(_, k, v) settings[k] = v end
    function o.obs_data_get_string(_, k) return settings[k] or "" end
    function o.obs_data_get_bool() return true end

    -- Frontend events reach `deliver(event)`, set by the test.
    function o.emit_in(ms, event) queue[#queue + 1] = { at = clock_ns + ms * 1e6, ev = event } end
    function o.obs_frontend_replay_buffer_stop()
        o.calls.stop[#o.calls.stop + 1] = clock_ns / 1e6
        state.active = false
        o.emit_in(200, o.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED)
    end
    function o.obs_frontend_replay_buffer_start()
        o.calls.start[#o.calls.start + 1] = clock_ns / 1e6
        o.emit_in(600, o.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED)
        state.starting = true
    end

    function o.now_ms() return clock_ns / 1e6 end
    function o.advance(ms, deliver)
        local target = clock_ns + ms * 1e6
        while clock_ns < target do
            clock_ns = clock_ns + 10 * 1e6
            -- due frontend events
            local pending = queue
            queue = {}
            for _, e in ipairs(pending) do
                if e.at <= clock_ns then
                    if e.ev == o.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then state.active = true end
                    deliver(e.ev)
                else
                    queue[#queue + 1] = e
                end
            end
            -- due timers (copy: callbacks add/remove timers)
            local due = {}
            for fn, t in pairs(timers) do if t.due <= clock_ns then due[#due + 1] = fn end end
            for _, fn in ipairs(due) do
                local t = timers[fn]
                if t then
                    t.due = clock_ns + t.ms * 1e6
                    fn()
                end
            end
        end
    end
    return o
end

return M
