--[[
OBS Clip Suite -- one Tools > Scripts entry (add this single file).
On every Replay Buffer save, in this order: Replay Organizer (per-game folder,
Windows only) -> Clip Alert Sound (off by default) -> Restarter (stops + starts
the buffer so clips don't overlap). The Update Checker updates this script from
GitHub Releases. Each module has its own group and on/off checkbox.
--]]

-- Bump on every GitHub Release (compared numerically: 1.10.0 > 1.9.0).
local VERSION = "2.9"

obs = obslua

-- No FFI (non-LuaJIT build): the Organizer disables itself, the rest keeps working.
local ffi_ok, ffi = pcall(require, "ffi")
if not ffi_ok then ffi = nil end

-- io-based fallbacks; replaced by UTF-16 versions once the Win32 layer is up
-- (Organizer block) so non-ASCII (e.g. Arabic) paths work.
local W = {}
function W.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end
function W.write_file(path, content, append)
    local f = io.open(path, append and "ab" or "wb")
    if not f then return false end
    local ok = f:write(content)
    local closed = f:close()
    return (ok and closed) and true or false
end
function W.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end
function W.remove(path)
    return os.remove(path) and true or false
end
function W.getenv(name)
    return os.getenv(name)
end

-- Update marker (next to the script, written before a self-update swaps it):
-- PID of the OBS that started the update, resume flag, "launched" flag, timestamp.
-- Marker PID == own PID -> this is the OLD instance and stays passive; otherwise
-- it is the NEW one and resumes the Replay Buffer. A marker older than
-- MARKER_MAX_AGE_S is a leftover of an interrupted update and is deleted, so a
-- reused PID can never make a healthy OBS go passive.
local UPDATE_MARKER_NAME = "obs_to_nvidia_update_state.tmp"
local MARKER_MAX_AGE_S = 900
local function update_marker_path()
    return script_path() .. UPDATE_MARKER_NAME
end
local function remove_update_marker()
    W.remove(update_marker_path())
end
local function write_update_marker(pid, resume, launched)
    return W.write_file(update_marker_path(),
        string.format("%d\n%d\n%d\n%d\n", pid, resume and 1 or 0, launched and 1 or 0, os.time()))
end
local function read_update_marker()
    local c = W.read_file(update_marker_path())
    if not c then return nil end
    local pid, resume, launched, stamp = c:match("^(%d+)\n([01])\n([01])\n?(%d*)")
    if not pid then return nil end
    stamp = tonumber(stamp)
    if not stamp then
        -- Written by an older version without a timestamp: stamp it now so it ages out too.
        write_update_marker(tonumber(pid), resume == "1", launched == "1")
    elseif math.abs(os.time() - stamp) > MARKER_MAX_AGE_S then
        remove_update_marker()
        return nil
    end
    return { pid = tonumber(pid), resume = (resume == "1") }
end

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

----------------------------------------------------------------------
-- MODULE 3: Clip Alert Sound  (shown as "3)" in the Scripts window)
----------------------------------------------------------------------
local Alert = {}
do
    -- Six short built-in notification sounds, embedded as base64 OGG
    -- Vorbis (mono, short clips) so this single .lua file needs no
    -- external "sounds" folder and stays small -- decoded lazily to a
    -- temp file the first time each one is actually selected and
    -- played, then cached for the rest of the OBS session.
local B64_MODERN_SUCCESS = table.concat({
    "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",
    "5pmeyWGUpVu6QI+IjgBwdpsADg=="
})

local B64_PURCHASE = table.concat({
    "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",
    "EnhjxwBwJwAO"
})

local B64_UI_CHIME = table.concat({
    "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",
    "QVIDRqskAENQAA4O"
})

local B64_UI_BLOOM = table.concat({
    "T2dnUwACAAAAAAAAAACzDG4cAAAAABHPFeQBHgF2b3JiaXMAAAAAAUSsAAAAAAAA8E8BAAAAAAC4",
    "AU9nZ1MAAAAAAAAAAAAAswxuHAEAAADVvzTOD0D/////////////////kQN2b3JiaXMNAAAATGF2",
    "ZjYwLjE2LjEwMAEAAAAfAAAAZW5jb2Rlcj1MYXZjNjAuMzEuMTAyIGxpYnZvcmJpcwEFdm9yYmlz",
    "JkJDVgEACAAAgCJMGMSA0JBVAAAQAACgrDeWe8i99957gahHFHuIvffee+OsR9B6iLn33nvuvaca",
    "e8u9995zIDRkFQAABACAKQiacuBC6r33HhnmEVEaKse99x4ZhYkwlBmFPZXaWushk9xC6j3nHggN",
    "WQUAAAIAQAghhBRSSCGFFFJIIYUUUkgppZhiiimmmGLKKaccc8wxxyCDDjropJNQQgkppFBKKqmk",
    "lFJKLdZac+69B91z70H4IIQQQgghhBBCCCGEEEIIQkNWAQAgAAAEQgghZBBCCCGEFFJIIaaYYsop",
    "p4DQkFUAACAAgAAAAABJkRTLsRzN0RzN8RzPESVREiXRMi3TUjVTMz1VVEXVVFVXVV1dd23Vdm3V",
    "lm3XVm3Vdm3VVm1Ztm3btm3btm3btm3btm3btm0gNGQVACABAKAjOZIjKZIiKZLjOJIEhIasAgBk",
    "AAAEAKAoiuM4juRIjiVpkmZ5lmeJmqiZmuipngqEhqwCAAABAAQAAAAAAOB4iud4jmd5kud4jmd5",
    "mqdpmqZpmqZpmqZpmqZpmqZpmqZpmqZpmqZpmqZpmqZpmqZpmqZpmqZpmqZpQGjIKgBAAgBAx3Ec",
    "x3Ecx3EcR3IkBwgNWQUAyAAACABAUiTHcixHczTHczxHdETHdEzJlFTJtVwLCA1ZBQAAAgAIAAAA",
    "AABAEyxFUzzHkzzPEzXP0zTNE01RNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3TNE3T",
    "NE1TFIHQkFUAAAQAACGdZpZqgAgzkGEgNGQVAIAAAAAYoQhDDAgNWQUAAAQAAIih5CCa0JrzzTkO",
    "muWgqRSb08GJVJsnuamYm3POOeecbM4Z45xzzinKmcWgmdCac85JDJqloJnQmnPOeRKbB62p0ppz",
    "zhnnnA7GGWGcc85p0poHqdlYm3POWdCa5qi5FJtzzomUmye1uVSbc84555xzzjnnnHPOqV6czsE5",
    "4Zxzzonam2u5CV2cc875ZJzuzQnhnHPOOeecc84555xzzglCQ1YBAEAAAARh2BjGnYIgfY4GYhQh",
    "piGTHnSPDpOgMcgppB6NjkZKqYNQUhknpXSC0JBVAAAgAACEEFJIIYUUUkghhRRSSCGGGGKIIaec",
    "cgoqqKSSiirKKLPMMssss8wyy6zDzjrrsMMQQwwxtNJKLDXVVmONteaec645SGultdZaK6WUUkop",
    "pSA0ZBUAAAIAQCBkkEEGGYUUUkghhphyyimnoIIKCA1ZBQAAAgAIAAAA8CTPER3RER3RER3RER3R",
    "ER3P8RxREiVREiXRMi1TMz1VVFVXdm1Zl3Xbt4Vd2HXf133f141fF4ZlWZZlWZZlWZZlWZZlWZZl",
    "CUJDVgEAIAAAAEIIIYQUUkghhZRijDHHnINOQgmB0JBVAAAgAIAAAAAAR3EUx5EcyZEkS7IkTdIs",
    "zfI0T/M00RNFUTRNUxVd0RV10xZlUzZd0zVl01Vl1XZl2bZlW7d9WbZ93/d93/d93/d93/d939d1",
    "IDRkFQAgAQCgIzmSIimSIjmO40iSBISGrAIAZAAABACgKI7iOI4jSZIkWZImeZZniZqpmZ7pqaIK",
    "hIasAgAAAQAEAAAAAACgaIqnmIqniIrniI4oiZZpiZqquaJsyq7ruq7ruq7ruq7ruq7ruq7ruq7r",
    "uq7ruq7ruq7ruq7ruq7rukBoyCoAQAIAQEdyJEdyJEVSJEVyJAcIDVkFAMgAAAgAwDEcQ1Ikx7Is",
    "TfM0T/M00RM90TM9VXRFFwgNWQUAAAIACAAAAAAAwJAMS7EczdEkUVIt1VI11VItVVQ9VVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV1TRN0zSB0JCVAAAQAAANOvgae8mYxJJ7aIxCDHrr",
    "mHOOes2MIshx7BAziHkLlSMEeY2ZRIhxIDRkRQAQBQAAGIMcQ8wh55ykTlLknKPSUWqcc5Q6Sh2l",
    "FGvKtaNUYku1Ns45Sh2ljFLKtbTaUUq1phoLAAAIcAAACLAQCg1ZEQBEAQAQCCGlkFJIKeaccg4p",
    "pZxjziGmlHPKOeWcg9JJqZxz0jkpkVLKOeWccs5J6ZxUzjkpnYQCAAACHAAAAiyEQkNWBABxAgAO",
    "x/E8SdNEUdI0UfRM0XU90XRdSdNMUxNFVdVEUVVNV7Vt0VRlW9I009REUVU1UVRVUTVt2VRV2/ZM",
    "05ZN19VtUVV1W7ZtYXht2/c907RtUVVt3XRdW3dt2fdlW9eNR9NMUxNFV9VEUXVNV9VtU3VtXRNF",
    "1xVVV5ZF1ZVlV5Z1X5Vl3ddE0XVF1ZRdUXVlW5Vd33ZlWfdN1/V1VZaFX5Vl4bd1XRhu3zeeUVV1",
    "X5Vd31dl2Rdu3TZ+2/eFZ9I009RE0VU10VRd01V13XRd29ZE0XVFV7Vl0VRd2ZVt31dd2fY1UXRd",
    "0VVlWXRVWVZl2fddWfZ1UVV9W5Vl31dd2fdt3xeG2dZ94XRdXVdl2RdWWfZ929eV5dZ14fhM07ZN",
    "19V103V93/Z1Z5l1XfhF1/V9VZZ9Y7VlX/iF36n7xvGMqqrrqu0KvyrLwrALu/Pcvi+Uddv4bd1n",
    "3L6P8eP8xpFr28Ix67Zz3L6uLL/zM35lWHqmadum6/q66bq+L+u6Mdy+rxRV1ddVWzaG1ZWF4xZ+",
    "49h94ThG1/V9VZZ9Y7VlYdh933h+YXie17aN4fZ9ymzrRh98n/LMuo3t+8Zy+zrnd47O8AwJAAAY",
    "cAAACDChDBQasiIAiBMAYBByDjEFIVIMQgghpQ5CShFjEDLnpGTMSQmlpBZKSS1iDELmmJTMOSmh",
    "lJZCKS2FEloLpcQWSmmttVZrai3WEEproZQYQyktptZqTK3VGjEGIXNOSuaclFJKa6GU1jLnqHQO",
    "UuogpJRSarGkFGPlnJQMOiodhJRKKjGVlGIMqcRWUoq1pFRja7HlFmPOoZQWSyqxlZRibTHlGGPM",
    "OWIMQuaclMw5KaGU1kpJLVbOSekgpJQ5KKmkFGMpKcXMOUkdhJQ66CiVlGJMLcUWSomtpFRjKanF",
    "FmPOLcVYQ0ktlpRiLSnF2GLMucWWWwehtZBKjKGUGFuMObfWag2lxFhSirWkVGOMtfYYY86hlBhL",
    "KjWWlGJtNfbaYqw5tZZrarHmFmPPteXWa869p9ZqTbHl2mLMPeYYZM25Bw9Ca6GUFkMpMbbWam0x",
    "5hxKia2kVGMpKdYYY84t1tpDKTGWlGItKdUaY8w51thrai3XFmPPqcWaa87Bx5hjTy3WHGPMPcWW",
    "a82595pbkAUAAAw4AAAEmFAGCg1ZCQBEAQAQhCjFGIQGIcack9AgxJhzUirGnIOQSsWYcxBKypyD",
    "UEpKmXMQSkkplJJKSq2FUkpKqbUCAAAKHAAAAmzQlFgcoNCQlQBAKgCAwXEsy/NEUTVl2bEkzxNF",
    "01RV23Ysy/NE0TRV1bYtzxNF01RV19V1y/NE0VRV1XV13RNF1VRV15Vl3/dE0TRV1XVl2fdN03RV",
    "15Vl2/Z90zRV13VlWbZ9YXVV15Vl29ZtY1hV13Vl2bZtXTlu3dZ14ReGYZjauu77vi8Mx/BMAwDA",
    "ExwAgApsWB3hpGgssNCQlQBABgAAYQxCBiGFDEJIIYWUQkgpJQAAYMABACDAhDJQaMhKACAVAAAg",
    "xFprrbXWWmKptdZaa621hkprrbXWWmuttdZaa6211lprrbXWWmuttdZaa6211lprrbWUUkoppZRS",
    "SimllFJKKaWUUkoppZRSSimllFJKKaWUUkoppZRSSimllFJKKaWUUkoppZRSSikVAOhX4QDg/2DD",
    "6ggnRWOBhYasBADCAQAAY5RiDDrpJKTUMOUYhFJSSaWVRjHnIJSSUkqtVc5JSKWl1lqLsXJOSkkp",
    "tRZbjB2ElFpqLcYYY+wgpJRaazHGGGMopaUYY6wx1lpDSam1GGOMNddaUmotxlprrbn3klKLMcZc",
    "a+65l9ZirLXmnHPOPbUWY60159xz8Km1GGPOtffee1CtxVhrrjkH4XsBANwNDgAQCTbOsJJ0Vjga",
    "XGjISgAgJACAQIgxxpxzDkIIIURKMeaccxBCCCGESCnGnHMOQgghhJAx5pxzEEIIoZRSMsaccw5C",
    "CCWUUErmnHMQQgihlFJKyZxzDkIIIZRSSikddBBCCKGUUkoppXMOQgihlFJKKaWEEEIopZRSSiml",
    "lBBCCKWUUkoppZQSQgillFJKKaWUUkIIoZRSSimlpFJKCKGUUkoppZRSSgkhlFJKKaWUUkopoYRS",
    "SimllFJKKSWUUEoppZRSSiqlFAAAcOAAABBgBJ1kVFmEjSZceAAKDVkJAAABACDOWmwpRkYx5yCG",
    "yCDEIIYKKcWctQwpgxymTCmElJXOMYaIkxZbCxUDAABAEABAIGQCgQIoMJABAAcICVIAQGGBoUOE",
    "CBCjwMC4uLQBAAhCZIZIRCwGiQnVQFExHQAsLjDkA0CGxkbaxQV0GeCCLu46EEIQghDE4gAKSMDB",
    "CTc88YYn3OAEnaJSBwEAAAAAcAAADwAAxwYQEdEcR4fHB0iIyAhJSQAAAAAA4ADABwDAYQJERDTH",
    "0eHxARIiMkJSEgAAAAAAAAAAAAQEBAAAAAAAAgAAAAQET2dnUwAAwK0AAAAAAACzDG4cAgAAADXR",
    "fdZBAQEfIyIkIyIoMOGCepIvLi8xNSovM+SRgocwMTAyLTPjkIF5c3l0dH16l56lp6WopqWaoaGm",
    "npuUnp+dk52QlpkAANwcqXbSz0UDEQAwP/6tDnFW8/3dxZ89arWhUAy9owAMDRlK7Fbwn9Gi4wAG",
    "AQD2Bd2gxVfxP5EgJtKYyTzVCfuuAvwMEatt853H5kUAGAQAJG13LvpgaHtCsEhgcc1mG2FK1QEM",
    "BX1MDiuGVHK7PwJwgACAvXh+Wuoeeao34wZhD0606cdtgwMMBTuaMjU4qdWuaGACAPheMuPJvX5S",
    "U8CHMDljGmavs4R4BQwBu4JEBWZVGxMJBAgAfM+zdQkJVzKOvN7Mvhi93uQBcQDc+d4E4NjZekKC",
    "ECDd49OQyOXkKP4xRQe7yx0J4u+I9rcZ9W+P0m6oFF5/MkAsFhGvco6EGnQATAAAx5LTMVsdWk1u",
    "HUqpx8jWY8Pnu0799QG9c9TfxPwDOpjdpO1m0rcmrLL5V6v+Xp9GvmO1Hbhnf/D+L/3GT02OmzEp",
    "jHYgQbz0iPRQ17EZWY8nbiZHAgAQCgAchwFCAbUjwe6ODJBzDFABhzI2+cvmaMct9fwn6zrTIO+K",
    "2+QDPA1HXOU80zWkSZxaX8MVAAAAgHBv3ED98R+mueksnl6yfV5zsfmp1Klaq53VZn3fjJ8YOkDO",
    "9/9/2XhztrQh+wbbdVzQpZgzIJVkvkW359vNm4mqvh/e+mnl8Q9vnoT0DgBQ6us/fvOU6QIAE8Ao",
    "p4wX2MYmUqDuehw315BQOIcEHskl3xdevf/aJn32uhwV2c2VQJ4FoEcCAGAJAAAAAKQBd1YAQEAo",
    "ANi7ERSEAh8AgLAUAERErfcaAQUAv9oA8NwEAD6GAIhGZgYAAAAAaO/7AcQeR0QAkJ3dK8M0pTAS",
    "9rW+RwAAgcq+XrQBAID+xStGW0FgIQAABgAAAADPt3sAAP645T9ufHV/NU179B6BQ9XOIqmzAEAs",
    "AMASAAAAAEgTAICAUABwvRmAUCADAKhwAQCutP1idwEAvwUAOyUA8L1+gAcAAAAAazMAYAEAYMjO",
    "i/eNFVmY0P7iEwsAAMKNq+gAAAB233pTlwSgf9XqAACADtgGAAAA9i0AlqjNfj2E94B/FeSjE8WB",
    "7L9cBHkWAIgaAGAWANcrAAAIIUgDMf1MAiAgFAD6/a0SpYQCnwGAsDQAgASAqurnTVOJRwMAFyEE",
    "AEIIH2fvAGwBISxHm1/ae+8AAAB4eCRfCiC2AAAAAACgJnPMNV1fEao1NTXxaNkBEw4AIESDBbki",
    "6ZY1ahQAABYT7ngCgAcwCwCcXf/vHselEN0+oAXLyVXsgeUivAEAcAXqBHCfRyeSSABAcQEFINIW",
    "yPTSFaC5JZxZ/88Pvv7QXDvQkpOrjBNk/QbAWxXgCtwAoK3SVRszeQAAOgsAwE2SGhoeDQCkWf9z",
    "XDtD81ZAyzi5bt3vqGsNwL9OcAVeAoCnjcrBXTMAirZwAgBUSAsDDPkiAJxV/893Pv8Q3T6gGNoV",
    "Ik+xXIQlAIArMCcA739EeehvAIi4AIBimOolrExpG8CQfwKUVf/vXur7h+gOBlo0nJxPtJt6AsCP",
    "FuAH3gFQxtH1rGZSgDm0znsCoBC+OBwKdxsqLe8GAOxFf1qDC4ri5TTbYgGURyONfL2jRq1bd76v",
    "MXO/OGdye7Rho0btv/11FPRt//MC05xY/wwprZ4h+AFFAXoBKPn4ipjY663hx9Z6o50RmLnfV8OO",
    "LeZyEc4A3Hn/9V3dVvB7pFbfyO2l9Sn624EtjnZMEwAnQd7MNK610DeAt1/AvUKMigAA8NFXAPwG",
    "Opglr8IPwPFKg88nv5p9P42QNJi5pz+5c4yRt9Wd82yOAPrNMBpCCwAg7EDXLyMyJufOvZ8DAGkA",
    "QAKEAl3XcTREGmMbzDOA1BAufrZ9b1hMavsXvpH/nF133uf+mgDAawKgU+Tx5h2m17IXk9Ka0BoA",
    "AACwq8ABvnSpeVv06s+8dLR41eXIEAEOf/TeojZqPVoA0O83D6ddd3e99xYCYH+jVc+lRhM9Pz9b",
    "PhELhe4kRoJN8Ofv9+Csgjx73hUAAAAAYP48TRUgJ2/cN/7oE407J6F18r69GSgHOLfy9SlTKwAA",
    "3rg1z8ib9K5j8r34tU675iMY+bATHgCAFQAA6KmqAtIEACAUAC8BVHgBAIQLQgFHAFBgDgQAAHCV",
    "AK8PAABwlgAUAOgXAQAA8AoAUJcAAJgAAADQEgEAACC1CjN/D3uMmKrUWPqSkLluuawCkPl+BmTd",
    "IBgAAOCtc4IEqAAAxj5T5SUIAMADAABcTwAcA4APAN6oda/EK/WuMcrPxS9bj13Xx8jtJgmQn5ZY",
    "AgAAAKQJAEDINB34+gggDIQC7gFQIAVDVE2k6RSzCgpdCwDgFQDAvgUAgJ8KAABQfwoAAMBA5jm2",
    "sZdfAZP8gk6MhAwAABOrbQCJBAAA49pUDgAAgIlhAAoADwCYA9wA4PkjAADAoACWmKXvzmv7XedF",
    "Pas/Ln/t+nyMPPkPALLVDQ4WHJ47AQBkANIEACCgwgsAABAKqBOAAumgEwAAEPD4mlJudZaRdP3/",
    "ffa09+r9tD6DCyL03nvvvffyEDw4AOgHAAoAgBAiHQAA8HsqAICxLGNZVrZ9pf5SPIoACfUAgPCD",
    "rW9ZlgUACUzAoAGsVf/1R0hQh2gtatuqChEwAC4SgIu5AACNmqa/XinNCDiMFfCY4BDA/Kip4Dch",
    "AgCsUX/yK+RYQrTCdRKrp/uy1AAXCcDFjAK4uAG77o1MqZYACNxXgGcpiEIBAP0uOhUApFH/9adQ",
    "AhsC65ptVcrD8gBcJAAXswEA9O1mkjbxtTmIwkdA/YoDWOc9+oKHEQwApFH//EcQGyGwrmCtTjLC",
    "UpmAiwTgyhfg4gX4HGmlQDRqAPgd1NIRuIoACMz3gSSgXALMSf+3HnmOcMBx54GgDSh5S9+LpbyF",
    "sj0ubhik19Z6/pHQwk9tj2SZHO0W3gH0WZ9e5OdDW+2n0yk6VPoeeP9vbB0A8B0AQJJnoiGRWEGa",
    "qzhvPOBXABRgOQaPnZ//AQAamN30jydPT2+l8Phy+/5HRv40WU9yG5//9x+8ejXHxnw/G5s25jES",
    "EIUCyLsCHDi/tacdR33UGSPvY4wxxkgQpCEAADpSTKH5sc65c1jcZWX53p1LTmYsqSYK0WOMcZ0A",
    "AC79v0ZuniYdZVed3/hGfd8aIy9EAKAc4BMv519P+a21cXLSqLXW4w+9A8Dht+ejp/Pfu3NLIwAY",
    "ICHnezQIW/m6qrqqAWxPWp5nPHQsN9pskXMA4NYKAAAAfnzL58d7fFJr//PXf1+GOrnePvxx2DUs",
    "6snJSaNWAXsZwBwO4P4UAd64zX61796S9jrW14f2zVOLP5NMJKzg9hOAXz69gRsAWAIAAACAUAD2",
    "DUDTBACAcIWlAYABFMLSkNiQmCdmrjwgVi4H8OTLCnAzfhgQAI4BAGC/CQAAYJkNALgAAABA7x4B",
    "AEgx59Z6X3x4irqqADAAABjJ+w8+jguABQDQWjR50gcgtwwAAABAMgGgAIAaAL6YDT/T944gfR76",
    "13Nnl1r6mhYIrEFaAIBZX/8SAAAAAKEAmATC0gB+qQAAFZYGAE4AoLE1VdMO6yHGkEQCYKcAfc0P",
    "AAAA+DEAAIA9HACAOa0AAAAAIAcAAImo73Gfg29UjvCDAKB7GvcA/Cu4hAEAgHBS2y4AwBAATgBA",
    "CgDACZ6Itb/Ed69CPcz/3gVv9eNZfU0L3dA+B+EFAFgCAAAAgICmAWQFACDcNABQAkDnqPR759Xy",
    "v9QCgOd0oAYAAPgmAACCFQAAAAA0AQAAyHoX5OcTN+tBCIDyn5ECnDnRYXWlFhJAAgAA5oCD1ksA",
    "4Gt8AgDwbgAAcAN+eLU/xffzIl2n8+eHDm32VLZ2nwIS0AgfAMASAAAAAKBpAC8FAEDTAEABgLA/",
    "kFxj8pRFxfgFQE8T+h4AALwLAECNEgAAAABEAQAAFu9uyvajtJUCjATSLKUA4IsBwJSHAAACAAAI",
    "01ULAPABYHAAQA0APoi1PsX37kRazv3PDw3e7EXZf+IBQGpNrARHWAEAAAuwBAAAAABoGsAXAEBY",
    "GgBIAIQBUBS3rDVYGdaZcTTm9pAWAK7bAAD1mwIAhgMAgG8EAKBqAAAAAAAFILEgYHwyn/aqBPYb",
    "xw0AAAAAzGqzjgKAAAAfAABWAf5ntT/l9ymifJzPn5eyV39i+08cKwAAYAFmPXcXAAAAgICmAdwn",
    "AEDTAEAAIAwAOwWAgvoUAOAbBgAAAOAzAADqVwAAAACoCQAwgK/5rsb07b+NFZneCY69n95OjCFY",
    "gOTrkj0CAIRC2gsAABrbANQDAN8DnjdVP8S3lJivu/PjtdhmL5/2Dz0AklwkiaZJCwAw6/rNAAAA",
    "AKBpAFECAMKECwgDKHWqb+3Juiadtsc4lP513RcAz2ngzQEAAADwdgAAnFEBAIwS4wOE/ZcUAiAB",
    "ogAAAJikQ6cAYBMA/AAAACB/DADA1wM+9ww+0beVkV45PunDmz37U0XxD4Cx23MnbI2FtAAASwAA",
    "AAAQCBMuQIULCBeA7uGv+bbdqRhz1Fh+D1P+/QCAk6BLAABwKwCplNIWEhm0mk6GFAA8NiUCMC8o",
    "1QAAAABAvTeHBACggFkAAIBfYgIAYBgAAGB+awAAAIgAAF6GzL7p36dhPZ7/Ptbr7fuK4h3Q4Rq5",
    "NluQAVtwAPzyJgAaYNbzMQEAAABM0wBGAgBUuAAFKo1+pnIOX94yvqTfJElxm+wobsTYygr40sVL",
    "AfAdNw2AYAIACACAvgEAgEQAAADAvNTzvBIAAoBKPgCMAgAA5N8AAKMAHpZUzsun63HKr+v9z+G1",
    "snFQOiBTpxyOBgtu2CCApkclwtLBvCMBIKlwAQBI98XEOebSrXlbzeHr2aoHNRFupA/3TpTXLsCL",
    "iQYAAKDiN6lCgM+dU6435YkYAUAe/4nGqAtTFCrBGSv5qV6c17K1jLN86nb3bI3ZSXcn8O0IgM8w",
    "ALhi8cIPyUqBJO3taAEAQP4h5rcWAD6WVC7PX0Xb4bdL/zHl47APGLo3sQENbGhDAV4BGle46cCc",
    "AISgjgQAUDm20VZfhi7r03Pw95jstndKAYD4rUtpBoADAIdywh5ZpVbK37jXoG2lTrEleGW7xYjU",
    "mL5k6QJTJKZA6LkURgkJcz67fZCH94HJIAMAOl0JAFwqIyc2cTWd47ZWlygBtfdU+Mbvl4vgOPaG",
    "1LjgWR2rtBESHpbk718f16L8/uDbXKnlAJjNMeaaBkIwAS6AkwAA4DbAu6k5IAHYSwYAME90rpOb",
    "pt+8p56xqaluL+lCAMGvVJlIB+3FmQQT2nVtWgKARknLSwUA4YiAAzDs7eQJHF5aZTw14eEa0k3Q",
    "k9zllN44H5CQc4QQN7yjCTjrxhpgPBbYbPLLOCxau4XXyOzTpsL15lGjD2b0MCDhLYwmlBaUXhr3",
    "M1wDHpbkPj7fSSQeB95UjjncA8R2zmmIgIQtaSeAV4DYpOaABFCrkgIA4h5i+L85lrdiZZaKGKnV",
    "QygUQPoZUOUBwOsqgKBLgt/77MAPjuMNLNZC4Goq3GK/5DrACNcCphmFuaq5p6BQkHqHAQBQBTfQ",
    "5BgAXpOQSbJA+xft+qYQiwXO85YOpCeb7f4HIUv3Ab2tPbXNY7wIAWuctpz0SyRFq03UDAFMGgA+",
    "lgTP11eIqgSH+jEbaSQfAOFZLbDAPRPgAZgAbgAmETYDSABVZQCA49TS7k3Y/13yrST0LmvaYwCk",
    "Q/koDQAIAHru4BUUADA2agHgRHObrJ3PbhX6dtYMNnt4yLS4DSlUyrPK0re7FQbgF3vD0EHyQhfx",
    "CyHIfoXaTCph2rFpKiUOY2r+kpe5EXeY0crsnzUpTCmYJS5ZaEWuPDRlKyjVTYTwJgA+lsTPjy8m",
    "Kb8d6+tIlb8pB9BZb65OEKDTJgEUmAAWEEvIDCABSK8MAMDh51aedzlTjSWVZpUY/iAGgriKulfr",
    "URxRAIYSJCI4wJptAxAqCcy/bZJKQn6k1rVRuW+Nuj5E0SSEcN/v5Jwa6V14GF9sVosqJtFSofXe",
    "ik68I2cLZjuDm1hLKkQpzmZPEPW248pMCAt9M93164sDiVINEUasgPt2ASaEHAAeliSer7e3Yv4m",
    "/H9bKuXGfAB2W8c4QICDfBKWAAAXoHth6UAngBqVFABAa5+xn/93dl+9f1MsnL2HRKmj2kZLfkUd",
    "BQBOh6lBAUAAAKcP4czyakYOOx3g0TgFtNcGgEmcFon5O2PTSUHaZ4Px2itP4XJUsamQhnLYAuPb",
    "BMu4NNimb2sTbVBhQPU6awl9KMFv2cQnZKqBhgq52kvecftKuo2ZITEBPpbE7+cXT8bnQU/rSnO4",
    "B2AOG3VCgxZsAChxAhIAYAFuFJYOXADUq6QAAAYhTfcfU/WDkrtD1esWW2A6cYYOMaFO3uKHyFBJ",
    "VRxcAMDQUK8AgJcCgKsmIfkxmQIYGRw9LI6EaoS5h0CW6gyjbhAKqmQnsrgGR9UA9J0YVkwvdtQ0",
    "t1UVsSowT2M3NLLM2onEkv/xW5SS9dL2WrWVG6wZ3B9wgwcdPpZk7/s3vCi/H/1tVPmHSSc1LRYM",
    "xggCmQ50AKhKCiDRJPly3jXDLRMKAN8WAAcAjFY9b3l/I/hJLptxIPrWpwEMvK+0K0B+LpWJ0w+5",
    "TycxwPxBnZkydXkY9tAafc8Tu4ifhLIr+TSteNBFmbH0mYHars0FwAKqUPCnpB24/oplyNMTmj3+",
    "S7LiMzJbWlGJ9FQefXNkRS+eWD6WpO/Xt6Iov5/4NlXMzxQNbUlJO2w56YAAYCuZAv4t3UeaLuqy",
    "fhoBIAoIIAAws1QjPzz4X9NPCIebGODkpaDN2ymvywg0JeW6S32TMqkAoNgRdLsUTcHBfIqP9tpx",
    "IAmiRYxQbIz2iIdv7b2K27qn1lIvCTazATD67sK8w+qmnYf9ZVXKcC8kJScWDImMIiln6DjcmA6u",
    "6a0/9dOUaHgAPpaU79fXtWi/TrpNlcZMMQskFiZAA0wAB8AmMh3YAFB1mADYy041fEkPEqMxKgXg",
    "qhQoBABgdkBFAGAiRAAAEG3fYoQRb5x14XXiA5ry4D4Anl4rGrK2gDHj66RUMPFKH0rmPMxbtKU0",
    "Slq3BZghUuf1hKxeC4PiMAJgoUJpiqMaITYiMB01XqJQMNhxWCEUkbNKhg6D7LR1gb47UQUaEwA+",
    "lpTv97c0KB83vkWJSk/lABasAA0Gc8BCYrQl04EFoFElAAC0kL30MozizPX3S3Ttz0hVSXOWC8zm",
    "AFCMBo5Tns3ba0VMkFk6zalupsGSEwDmjzKdeB2JAjAawXKx3v4dJgME6ONYyE4kwhsnFEckqlvS",
    "lyGZxA0DLQrZfSHhTPLdPEQUobYVubUDfNmZQ4ssM3arquZ0oz81L3huaHeOYgxjlioPPpaU749v",
    "j6gE2r+byhiYRsKiWZIJ4AH04nRgAaiSDOC+a3oL7+lVIjsAgMfmpUEAReoWFAICMHQtnifRdfJP",
    "d1efKKw/WKCFx5pXEYFk4l+c+0mISUXGALaHqhnnIR+pv19GUzrKcUwNApwd4/jT0xVYDBrG3qyn",
    "mGGaQlWZSxfQ2pnkxxmu3MkSJsk8m4z+p0MQ7fqwUqXXVIZoAJg+ltSv97dHUH5788ZiCZGQaII8",
    "ATQgiE6jqgxg3/Fhk6/H61FHqQNQgaKKAJvZmi0+xj573uHUXVEMoSS8kylrYOpRtL5CHzMZnYMF",
    "KDyupKPmcG5XpXyGZpA+oEuQmrf9pMvp9F50Ga9oJAa9NzBIIOSThPNfN5Jfp5FVOSilZMAJI6Kv",
    "3eoDslDbXOvuKywFyNOXD0Q6Wg2kBD6WNK+Pb1Mn/ab8PxbrxtQJgiaJE8ACysuUD5gC+FX7dElb",
    "vaBdSyIADiURFADw4vWlmkeMfOcY+P7v7JMY6xodJleT+7RpDVOYFoEBcbX9vj3evR5stvHnDswT",
    "hycIyteCzu1wmbTI5Hg9ALLEBFiAFhIujn/L08K7iDqgpDNzC86Xa4RkMEcScDhtwh7P6KZZCgA+",
    "ljSvr29XI/2u/GyNZG1MQCOZaUeP2qiXFEBI9ff2J8Q1TtsBABiePd6jScJVBkLYyH7lI1/qzGgt",
    "xMiiiVRsUM4SAC9MNRAZAZBiKrVCZmO6D1KTg0QgYxdyZPmiglSdSoy9o+1PA8WB4F0Oos9jyMpi",
    "ErNA7vNhuzmZViFA8hsYufaY7hZZsu1yCb9hcf8iotxi96dBjBFovQmGAT6WTM/Pb8Mpvys/zWKV",
    "GQeAEoAFmAPQIEii1+gwBXALJrag6PAyCEB1uigApOlwaYqBagAAoBqcrzccqfd7386YG2s5/NmU",
    "WWDOsYN/AnmW//ucXC+UhyOYN2LUXMIKkkK+enwgE47VapcgpRY6UbqoZPuyL2HjF7XblrDDCRMG",
    "SgoWM7OMqmQGamAvObPJ4Qx7Gzii0ZAdWRIkiAl0AD6W9K+v7ymrBMY9DSzLmANAoOmuCcdEmQLg",
    "6m4ilhaaAgCgrCVSpx3c6c4+bvky7fPD8xnl1+ckOKYoDGLDRjpICkWAFt2mJgmDbY9X2mIGs94c",
    "plJCEr5tPk9iKMsFdTJ3SthdhP1sviJsPtGTDNGyXPbEgKLtpGpUqTYSrbmSY035oUZmBBxJZXNs",
    "s3lfZse6P3hOwI1RUgAKAA8+lkzPj+9sWgmU5yB8bvGYISAAunFVVSUAoOs2Ry8FWgF05I/np1pl",
    "4O8Kw0c/vmoCirnZaZhXKDHAYzgA8AG/geuJkACAZjejgTUHDZrmnNil4SLy1B38XC5wO2Lva+G9",
    "WmaL09Oex6hOmVaeSWBE+hfYkJCCj/H6LCujExNCmZxwILukOOoW1OunHENuOUcZeAA+lkzPz+9e",
    "Rvhd+U4HKW4IBQAdkuFWYlQqU0Cr8B2nlCeHtQtQ91i6bxl24FfhxajlMt9gK5Dv0j53IaWDZhYA",
    "qU36qOIv6jIH7cK4RIFg8L7ayRoUYJxY9MejYotJLyIGB9TmcwrZ3vhfMuP243w5a3Ii6adpPoaC",
    "JK1MC5j+9aYUfF7RTZLvmXN0hD86pOy48UzSEnWLrQp0QDwAPpaMz+/v3JX0wLAqI2pbx1ijiWQA",
    "AAH7tpfQZHmPq9E5f7VmpufEL/aE6E0MlB8XFcvUOiWMLvYEpMpiid/ovZx9sihe6RYbwP8cw0iB",
    "f0DHpY8yi7adHH6QNMqJUKwK41KT+/5DdLteZ5pcBs/ZDKXfp3RG6dyBNoEazDCUgqGMJJdLs+1N",
    "oZfZjILNJyYAHpasj8/3eZTwu86wLyMOuqNWA08yAICee3l32KXjodluXh+Co/D/3XQu3+aYRu0x",
    "ageAgOqmV410C3pXl/Czcgn9bL7PFLebtk5c015ysaXRS6UHiCctjW318yNeFLSyICRGI0xUKwJT",
    "mlJsvGJ7yKcqXV5vEKaqD9C3hYCzJ86zzvE3u74t9Fu3Sx1e2F8CKdSYmUAHPpbsj/d3D8Uv6Qxz",
    "3CNu26DUR6MUAMCijsh7j6KbIt/cOI7bkSS7KDHIxI2salN4uwsmYF3qx41wTUnJCQVfK/Z9M0d2",
    "2DKuF5xFGz48fvwWxXdsccw6ddvhi+Ic4qrz+i+Xe9VVKsHLiY3dAbPTXmV/UgLjCXU8pGYOKf+3",
    "CBrnCUavp9numvbGSPDsDP6lInkXTALWSSkAT2dnUwAEgO4AAAAAAACzDG4cAwAAANu1Ys8Rl6CV",
    "lpOPnZeVioiMhIBzWQH+lWy317u7kj6lM83xhzjZgAQglo3ROxQASGgqnnVUETsQeJwMW+EAL3Z4",
    "s/7MMIq/ROeCrsd3KYQ3jUYQADQpGSgNP6CC3/ZI1WRu0g9wlFGY3fHjp6+dzSAFzk4Q5px/nJiM",
    "tcXwaziF47cz6hdzK04wjApCh5Ho1NOoLrq9O7uHJ7tigOmVQSYx/iM7TxChNEedy0sAPpacHs/v",
    "FIqXc08F4SGaA8DABjSAL1WvyhRQMl49lsMVbdBv+knSNTWNAlDMnM+5jzn00+p65yW+bkPCv8FY",
    "QAAQGQCxnsC/7BVbM0bcbXXKYbFjQ6YkRMooqlXbUtz+/oii09QsUGNJMXXtkeLFme9fPmpHWYM3",
    "gXWv248pDSKC/M58wef8FwenJdkE3L95c4X+lS2UsDJI9EDrSoEvAD6WnB7373HDh3KGUfwQt0Ns",
    "jXrPFACwXfrmX92UqXO/NuONHt63j8nspjFnxJwfoT78hZgmCyXO2iMAsmYAgChDwqw59C511I11",
    "EFd0ydMNfSyU/5xxGpHOllRma5xM1O1XUi53i6rwWGTImjW8PbdJYb23AxSY4ezaGV0toh1tUTVm",
    "OrKuZAwTSszjzmm56hp8phAAPpYcH6/vOYIPRbNI3YK9ezWJGs8AoKm8rprC59sVJ/e+cbVBZqcA",
    "vFRNTN/Vv50lAvTRqPlwHjJRAnRdS7Pk9Tc/7HUBQmqp69815f6Fr0eVMmZmnBhuX0vFO9hPC9Fi",
    "FxjffljYJCcR+jFt3UlAnvs6tpjJy6vvVC7cXzdcyeAoGy/wWvZpcSeLsCSFBe4ZvffdUFcAPpac",
    "Ho/vCsNLe04jHYJt6yt6jVICAO5yUAfPPltruvHyDEd06C0juPsgD3zZFsDFtB7p7RRDcEpyyIaQ",
    "s4gzdTe+/F2Vc9cZ7KVUHzjj3WDzJRijyVvSZNNcijp2ylf70rXbrc8yQrzPkGTy4Lq4Ane94jgL",
    "ywSyfvyQCU4vL1BI3t8DkVTmSh8ziINyvMlQ0SwAPpZc7vfvmoZLss0yQRIbq9FVSQEAlpBe1Sf5",
    "DneX8cQn6ZGa9wqFG0/Sltg8DDTlwIp7z4RTbVA8l2ugTcpszZ7OUU/DQB89NU71M8jwIwUZWwRV",
    "yKsyb2QtwLu8tKSWFcwQE0StuzI2F32q4o0TrwyJRWCoJlZK28LfSfH9jrBUsy0Nn7tQpsWck3lC",
    "0Uw+llzv1+/aDavmmECc9DZaG61SAAC4uxknB4ThSXzPJHg1NZJiKdLZr09i5OdUPmaTvZQyMTOv",
    "HNFRcUzt9MN6/fecHMhZozRju3haBzXKyv4b5TpZp7SX99tajsqIi4nNN3DAh0qtjDAp8H0MsLu/",
    "SBHOYo7AF0iXsZoyUVyo8r3dx091l8mk86y7YZ8bRBxpRpWto8dmMiSUS10CPpbc77fv2Q0vybSA",
    "7VWqgY+SAoCaVPSX2PfGx9SxvThi2mVqeD4bNu6VeHx4301PkRgGD/WZW+zdEeWhVDjP1mSLJ5UK",
    "TR4Tl1iu0xj9DvpN5Dbput8fU3HJFZWGTgnZ/Gwlf/9cMrM5RYzLvfsUrYxeCyxvc0Z2uAx73wpV",
    "0PQYochAgFYyed6ovVxlpbQotrbZ4wbwAD6WPG7X79wFDwzwipNYlXjrJQUA4BLGP6rEZeKbzNFz",
    "TfwVknfOCb5ybOHzHmvWBLEpGzRvTjUgYoa8/+7lgmm1+tLR/VwyFAd5gVQh633ZdhcIdzEBrNMZ",
    "Y1GpXj0xcBB5AkLtApXuhu32ncsSPD31jlPYxiw8ChVOBqV+4hSY7tSVcOzsajUBhDslHFc1bt35",
    "SOAEPpbc7/fv2RWrYVggqKDKRFcZAACa7P/VSIGt4gXF3SHI5pcjpkw9Qgj4LQNma5wnn+6dCzhJ",
    "ELZr2R2drd02bqxLmBDaJZ+Iy59gH3i9GwAPisK8P29YIo0bUYYgewV31vnZcCwCWkqX1KB9pZ4G",
    "JlWcHm20q/1u4r+1ESqvV8WJnVKfr1QglUYDPpbc3q7f1RSLbQNBTGyiiTcMAAALPqNMq7pVbSW/",
    "uFuZbIxgH0Lqlk9snqMvIuVM/vj0AgKwUtrmh7/QhzLKU8IQovH7+oYmp9hJUJ+0C1DdjNN7ScOX",
    "ag2IIJPpz9fjEjSM4p6+RYxN6qi+S37cqIYjF1ye9PaVaiiDyR22t/AFu4sTMycKAB6WvFwv794V",
    "i2KbQbCSXOpVGQAg3G+Y9Sb13F6cr3f69Vh42FufoX1wT53iEPun0lKdpSGYHdrG2vW7kvSlrEX0",
    "PJbTmk76NU6YerNZ1Zi5LKInq18ujyLIYtELF5pkQnmegfLyfF9iNJAOVc6mVgSNACKoJI6sNsZI",
    "2ywkUSuP8n0/oBJS8PMUiucBPpa83G7fOQVM0wwCPeZoVJIUAOAdZCrIesdQsA9kq2cNOeWrGI61",
    "gtW8+AlbZGjQHE03/omXVJddxl61bY+dFqejrfdjeJU3NdXZOV+fQbeF7BFMEiFLMeu6ui2rPJwb",
    "Mil+AxO3JV2Bk9WYHbV12Ui3enl5OX2YZ15GP6JSvcReW4EGPpbc3m7f9SoY17ZcBLqWN6RKCgCg",
    "GUvvn7/JA31GxV3L19p+RZQZF40pxtnzufBSIv+UOtPiRiu+7d8QVnt31+ecaMc4LpXfnbVrx5+g",
    "Qfwkodgy2K9/3HH/pu4mxYQBjiDlSWoKJQMEFXtAYehK42+kQ7rGFbDSJdgjlSjppA4elrxdtu/W",
    "FUwbEGhiRSWZKQCAWch1C6El/l+de/aq823CNPgatkz7pjVZSISEbDjOnWmNCl1vJeTsznJw3Lf8",
    "M/n+4Inqn9tFQq8lwaRJT0osDdXvnEkhDp1zqzsdkzHfPEbsDjpkyG2gg4KoFKrRUoMGPpb8uUxf",
    "jgI2QFbMKQkAAACcDpiTb5POwjpSt78zIgG+6Kp6bqOtKQdbQgDL23RX0l8tAJYN9sW/+ueqdbrS",
    "57tWnjTm2wNVAOh3PWvlzhrAq8W2iGAwagAO"
})

local B64_DIGITAL_CHIME = table.concat({
    "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",
    "Dg4ODg4ODg4="
})

local B64_NEW_NOTIFICATION = table.concat({
    "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"
})


local SOUND_CHOICES = {
    { id = "modern_success", label = "Modern Success Confirmation", b64_var = B64_MODERN_SUCCESS },
    { id = "purchase", label = "Purchase Success", b64_var = B64_PURCHASE },
    { id = "ui_chime", label = "UI Chime Success", b64_var = B64_UI_CHIME },
    { id = "ui_bloom", label = "UI Success Bloom", b64_var = B64_UI_BLOOM },
    { id = "digital_chime", label = "Digital Futuristic Chime", b64_var = B64_DIGITAL_CHIME },
    { id = "new_notification", label = "New Notification", b64_var = B64_NEW_NOTIFICATION },
}
local function sound_choice_by_id(id)
    for _, choice in ipairs(SOUND_CHOICES) do
        if choice.id == id then
            return choice
        end
    end
    return SOUND_CHOICES[1]
end

    -- ---------------------------------------------------------------------
    -- Settings (filled in from the Scripts window)
    -- ---------------------------------------------------------------------
    local alert_sound = true
    local selected_sound_id = "new_notification"
    local custom_sound_path = ""  -- if set, overrides the dropdown choice above
    -- 0..100, applied as a linear multiplier (obs_source_set_volume wants
    -- 0.0..1.0) on the internal source each time it's created. Kept
    -- separate from OBS's own per-source mixer/Advanced Audio volume,
    -- which is applied on top of whatever this is set to.
    local alert_volume_pct = 100
    -- Safety-net ceiling only now (see do_sound_alert below) -- normal
    -- cleanup happens as soon as the "media_ended" signal fires, so this
    -- is just how long we wait before force-clearing a stuck/looping file.
    local sound_channel_hold_ms = 10000

-- Mutable (not a constant anymore) so it can be changed from the Scripts
-- window if 63 ever collides with something else in your setup.
local SOUND_CHANNEL = 63

-- ---------------------------------------------------------------------
-- Base64 decoder
-- ---------------------------------------------------------------------
local B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- Lookup table built once, instead of calling string.find() for every
-- single character of every sound blob.
local B64_VALUES = {}
for i = 1, #B64_CHARS do
    B64_VALUES[B64_CHARS:sub(i, i)] = i - 1
end

-- Decodes four base64 characters straight into three bytes with plain
-- arithmetic. The previous version built an intermediate string of
-- "01001010..." bits one character at a time and then re-parsed it,
-- which produced hundreds of thousands of throwaway string allocations
-- per sound and measured ~8x slower on the same input -- noticeable as a
-- stutter the first time each built-in sound is used. Verified to give
-- byte-identical output to the old decoder over randomised round-trips,
-- including every padding case.
local function base64_decode(data)
    data = data:gsub('[^A-Za-z0-9+/]', '')  -- also drops '=' padding

    local out, n = {}, 0
    local char, floor = string.char, math.floor
    local sub = string.sub

    for i = 1, #data - 3, 4 do
        local a = B64_VALUES[sub(data, i, i)]
        local b = B64_VALUES[sub(data, i + 1, i + 1)]
        local c = B64_VALUES[sub(data, i + 2, i + 2)]
        local d = B64_VALUES[sub(data, i + 3, i + 3)]
        if not (a and b and c and d) then break end
        local v = a * 262144 + b * 4096 + c * 64 + d
        n = n + 1
        out[n] = char(floor(v / 65536), floor(v / 256) % 256, v % 256)
    end

    -- Trailing partial group (what the '=' padding stood for).
    local rem = #data % 4
    if rem == 3 then
        local i = #data - 2
        local a = B64_VALUES[sub(data, i, i)]
        local b = B64_VALUES[sub(data, i + 1, i + 1)]
        local c = B64_VALUES[sub(data, i + 2, i + 2)]
        if a and b and c then
            local v = a * 1024 + b * 16 + floor(c / 4)
            out[n + 1] = char(floor(v / 256), v % 256)
        end
    elseif rem == 2 then
        local i = #data - 1
        local a = B64_VALUES[sub(data, i, i)]
        local b = B64_VALUES[sub(data, i + 1, i + 1)]
        if a and b then
            out[n + 1] = char(a * 4 + floor(b / 16))
        end
    end

    return table.concat(out)
end

-- ---------------------------------------------------------------------
-- Decode a chosen built-in sound to a temp audio file the first time
-- it's needed, then reuse that file for the rest of the session.
-- ---------------------------------------------------------------------
local decoded_paths = {}  -- id -> path, cached per OBS session

local function builtin_sound_path_for(choice)
    local cached = decoded_paths[choice.id]
    if cached then
        -- Don't trust the cache blindly: this lives in %TEMP%, which
        -- Windows Storage Sense / Disk Cleanup can empty out from under a
        -- long-running OBS session. If the file is gone, fall through and
        -- write it again instead of handing OBS a path to nothing (which
        -- showed up only as a silent "no sound played", with no error).
        if W.exists(cached) then
            return cached
        end
        decoded_paths[choice.id] = nil
    end

    local temp_dir = W.getenv("TEMP") or W.getenv("TMP") or "."
    local path = temp_dir .. "\\obs_clip_alert_" .. choice.id .. ".ogg"
    local decoded = base64_decode(choice.b64_var)
    local written = (#decoded > 0) and W.write_file(path, decoded) or false
    if not written then
        obs.script_log(obs.LOG_ERROR, "Clip Alert: failed to write the sound data to " .. path)
        return nil
    end
    decoded_paths[choice.id] = path
    return path
end

-- ---------------------------------------------------------------------
-- The alert types
-- ---------------------------------------------------------------------
-- The alert source is kept referenced here and watched by a small timer
-- (obs_source_media_get_state) instead of the old "media_ended" signal.
-- That signal fires on the source's own playback thread, and tearing the
-- source down from inside its own callback (which is what happened when a
-- second clip was saved while the first alert was still finishing) can
-- deadlock. The timer runs on OBS's normal script thread instead.
local alert_source = nil
local alert_started_ns = 0
local alert_seen_playing = false
local ALERT_POLL_MS = 200

local function clear_sound_channel()
    obs.timer_remove(clear_sound_channel)
    obs.obs_set_output_source(SOUND_CHANNEL, nil)
    if alert_source ~= nil then
        obs.obs_source_release(alert_source)
        alert_source = nil
    end
    alert_seen_playing = false
end

local function poll_alert()
    if alert_source == nil then
        obs.timer_remove(poll_alert)
        return
    end
    local state = obs.obs_source_media_get_state(alert_source)
    if state == obs.OBS_MEDIA_STATE_PLAYING then
        alert_seen_playing = true
    elseif state == obs.OBS_MEDIA_STATE_ENDED or state == obs.OBS_MEDIA_STATE_ERROR
        or (alert_seen_playing and state == obs.OBS_MEDIA_STATE_STOPPED) then
        obs.timer_remove(poll_alert)
        clear_sound_channel()
        return
    end
    -- Safety net: a file that never reports an end (corrupt, looping, ...)
    -- still frees the channel after the hold time.
    if (obs.os_gettime_ns() - alert_started_ns) >= (sound_channel_hold_ms * 1e6) then
        obs.timer_remove(poll_alert)
        clear_sound_channel()
    end
end

local function do_sound_alert()
    local path = custom_sound_path
    if path ~= nil and path ~= "" then
        -- A custom path that no longer exists (file renamed, drive
        -- unplugged, sound folder cleaned out) used to just produce
        -- silence with nothing in the log. Say so, then fall back to the
        -- selected built-in sound so an alert still plays.
        if not W.exists(path) then
            obs.script_log(obs.LOG_WARNING,
                "Clip Alert: custom sound file not found (" .. path ..
                ") -- falling back to the built-in sound.")
            path = ""
        end
    else
        path = ""
    end

    if path == "" then
        local choice = sound_choice_by_id(selected_sound_id)
        path = builtin_sound_path_for(choice)
        if not path then
            return
        end
    end

    -- Tear the PREVIOUS alert down completely first (timer stopped, channel
    -- freed, reference released), so two saves close together can never
    -- leave a stale watcher that cuts the new sound off.
    obs.timer_remove(poll_alert)
    clear_sound_channel()

    local settings = obs.obs_data_create()
    obs.obs_data_set_string(settings, "local_file", path)
    obs.obs_data_set_bool(settings, "is_local_file", true)
    obs.obs_data_set_bool(settings, "looping", false)
    obs.obs_data_set_bool(settings, "restart_on_activate", true)
    obs.obs_data_set_bool(settings, "close_when_inactive", false)

    -- Private, not a normal named source: invisible to the scene list and
    -- to obs_get_source_by_name, which is exactly what an internal one-shot
    -- sound player wants.
    local source = obs.obs_source_create_private("ffmpeg_source", "ClipAlertSound", settings)
    obs.obs_data_release(settings)

    if not source then
        obs.script_log(obs.LOG_ERROR, "Clip Alert: failed to create internal sound source.")
        return
    end

    -- "Monitor Only" makes it actually audible through your speakers
    -- in real time, without also baking it into any recording/stream
    -- output.
    obs.obs_source_set_monitoring_type(source, obs.OBS_MONITORING_TYPE_MONITOR_ONLY)

    -- User-controlled alert volume (a multiplier on top of OBS's own
    -- per-source volume, which defaults to 100% for a fresh source).
    obs.obs_source_set_volume(source, alert_volume_pct / 100)

    obs.obs_set_output_source(SOUND_CHANNEL, source)

    -- Keep our own reference (released in clear_sound_channel) so the poll
    -- below can read the playback state.
    alert_source = source
    alert_started_ns = obs.os_gettime_ns()
    alert_seen_playing = false
    obs.timer_add(poll_alert, ALERT_POLL_MS)
end

    local function trigger_alerts()
        if alert_sound then
            do_sound_alert()
        end
    end

    Alert.on_replay_saved = trigger_alerts

    -- Deliberately calls do_sound_alert() rather than trigger_alerts():
    -- the point of a Test button is to hear the sound you just picked, so
    -- it plays even while the module's own checkbox is off. Going through
    -- trigger_alerts() meant the button silently did nothing in exactly
    -- the situation where you'd most want to audition a sound -- while
    -- setting it up, before switching the feature on.
    local function test_alert_clicked(props, property)
        do_sound_alert()
        return false
    end

    function Alert.script_description()
    return "<h3>3) Clip Alert Sound</h3><p>Plays a short sound whenever a " ..
           "clip is saved. Choose a built-in sound or your own file, and " ..
           "set its volume.</p>"
end

    function Alert.script_properties(props)

    local sound_list = obs.obs_properties_add_list(props, "selected_sound_id",
        "Alert sound", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    for _, choice in ipairs(SOUND_CHOICES) do
        obs.obs_property_list_add_string(sound_list, choice.label, choice.id)
    end

    obs.obs_properties_add_path(props, "custom_sound_path",
        "Custom sound file (optional)",
        obs.OBS_PATH_FILE, "Audio files (*.wav *.mp3 *.ogg *.aac *.flac)", nil)

    -- Percent, not a raw 0..1 float -- matches how OBS's own per-source
    -- volume slider (Advanced Audio Properties) is labelled, so "50%"
    -- here means the same thing it would mean anywhere else in OBS.
    obs.obs_properties_add_float_slider(props, "alert_volume",
        "Alert volume", 0, 100, 1)
    -- obs_properties_add_float_slider doesn't take a suffix argument
    -- itself; this is the separate call OBS's own sliders use to show
    -- "%" after the number instead of a bare "100".
    local volume_prop = obs.obs_properties_get(props, "alert_volume")
    if volume_prop then
        obs.obs_property_float_set_suffix(volume_prop, "%")
    end
    -- Safety-net max hold (sound_channel_hold_s, default 10s) is also
    -- kept out of the UI -- in normal use the channel clears itself the
    -- instant the sound finishes; this is purely a fallback ceiling for
    -- the rare case where OBS never reports the sound as finished. Still
    -- has a real default and is still read normally in script_update
    -- below.

    -- The OBS output channel used to play the alert (sound_channel,
    -- default 63) is intentionally NOT exposed here -- it's an obscure,
    -- rarely-needed knob that just confuses most users. It still has a
    -- real default and is still read normally in script_update below,
    -- so the only way to change it now is by editing the script's saved
    -- JSON settings directly (advanced users only).

    obs.obs_properties_add_button(props, "test_alert_button",
        "Test Alert Now", test_alert_clicked)

    end

    function Alert.script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "alert_sound", false)
    obs.obs_data_set_default_string(settings, "selected_sound_id", "new_notification")
    obs.obs_data_set_default_string(settings, "custom_sound_path", "")
    obs.obs_data_set_default_double(settings, "alert_volume", 100)
    obs.obs_data_set_default_double(settings, "sound_channel_hold_s", 10)
    obs.obs_data_set_default_int(settings, "sound_channel", 63)
end

    function Alert.script_update(settings)
    alert_sound = obs.obs_data_get_bool(settings, "alert_sound")
    selected_sound_id = obs.obs_data_get_string(settings, "selected_sound_id")
    custom_sound_path = obs.obs_data_get_string(settings, "custom_sound_path")
    -- Clamped to 0..100: a value outside that range in the saved JSON
    -- (hand-edited, or carried over oddly from somewhere) would make
    -- obs_source_set_volume either silently mute the alert (negative) or
    -- push it into clipping (well above 100), with nothing in the log to
    -- explain why the alert suddenly sounds wrong or has gone silent.
    local raw_volume = obs.obs_data_get_double(settings, "alert_volume")
    alert_volume_pct = math.max(0, math.min(100, raw_volume))
    -- Floored at 1s: this is the safety net that frees the audio channel
    -- if "media_ended" never arrives. At 0 it would be an every-tick timer
    -- that yanks the channel away before the sound can even start.
    sound_channel_hold_ms = math.max(1000,
        math.floor(obs.obs_data_get_double(settings, "sound_channel_hold_s") * 1000))
    -- If the channel number itself changes while a sound is currently
    -- occupying the OLD channel, clear the old one first so it doesn't
    -- get orphaned (never cleared because clear_sound_channel would
    -- from then on only ever target the new channel number).
    -- Clamped to OBS's real channel range (0..63) as well -- an out-of-range
    -- number written into the saved JSON by hand would make every
    -- obs_set_output_source() call a silent no-op, i.e. no sound ever, with
    -- nothing in the log to explain why.
    local new_channel = obs.obs_data_get_int(settings, "sound_channel")
    if new_channel < 0 or new_channel > 63 then
        new_channel = 63
    end
    if new_channel ~= SOUND_CHANNEL then
        obs.timer_remove(poll_alert)
        clear_sound_channel()
        SOUND_CHANNEL = new_channel
    end
end

    function Alert.script_unload()
        obs.timer_remove(poll_alert)
        clear_sound_channel()
    end
end

----------------------------------------------------------------------
-- MODULE 2: Replay Organizer  (shown as "2)" in the Scripts window)
----------------------------------------------------------------------
local Sorter = {}
-- Set to false below if this platform can't give us the Win32 calls this
-- whole module is built on. Checked by every Sorter entry point so the
-- module degrades to "does nothing" instead of throwing on every single
-- replay save.
local sorter_available = (ffi ~= nil)

-- Declared here (top-level, chunk scope) rather than inside Module 2's
-- `do...end` block below, because Module 4's relaunch_obs() also needs
-- them to restart OBS after an update, and a `local` declared inside one
-- module's do-block is invisible to code in a different module's
-- do-block -- Lua would silently fall back to an unset *global*
-- `kernel32`/`user32` there instead, which is what used to break the
-- self-restart after an update (kernel32) and then, after the WM_CLOSE
-- fix, the graceful-close step too (user32 -- EnumWindows/
-- IsWindowVisible/PostMessageW all live in user32, not kernel32).
local kernel32, user32, shell32
-- utf8_to_wide is likewise declared at chunk scope (not inside this
-- module's do...end block) because Module 4's relaunch_obs() also calls
-- it -- a local declared inside one module's do-block is invisible once
-- that block's `end` is reached, so Module 4 was falling back to an
-- unset *global* utf8_to_wide instead, which is what broke the
-- self-relaunch step of an update.
local utf8_to_wide
do

------------------------------------------------------------------
-- Win32 API access via LuaJIT FFI (no external app, no PowerShell,
-- no Python needed — OBS's built-in Lua runtime is LuaJIT).
--
-- Everything (foreground process detection, folder creation, file
-- move) goes through direct Win32 calls here — nothing ever shells
-- out to cmd.exe via os.execute(). That matters because spawning a
-- process/window while a fullscreen-exclusive game is running is
-- exactly what makes Windows minimize the game.
------------------------------------------------------------------
local winhttp
-- kernel32 and user32 are declared at chunk scope above (shared with Module 4)

-- Wrapped in a function + pcall (rather than run bare at chunk level) so
-- that a failure here -- no LuaJIT FFI, a non-Windows OBS build, a
-- locked-down system where ffi.load("winhttp") is refused, or a duplicate
-- cdef on an unusual reload path -- disables just the Organizer instead
-- of aborting the entire script file and taking the Restarter, the alert
-- sound and the update checker down with it.
local function init_win32()
    ffi.cdef[[
typedef void* HWND;
typedef void* HANDLE;
typedef unsigned long DWORD;
typedef int BOOL;
typedef wchar_t WCHAR;

HWND   GetForegroundWindow();
DWORD  GetWindowThreadProcessId(HWND hWnd, DWORD *lpdwProcessId);
HANDLE OpenProcess(DWORD dwDesiredAccess, int bInheritHandle, DWORD dwProcessId);
/* W (wide) version -- not A -- so the exe's full path decodes correctly
   even when it contains non-English characters (e.g. a Windows user
   folder with an Arabic name). The A version would mangle those bytes
   through the system ANSI codepage the same way the A window-title/
   file APIs would, which is exactly what this script avoids elsewhere. */
BOOL   QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, WCHAR* lpExeName, DWORD *lpdwSize);
int    CloseHandle(HANDLE hObject);

/* Used instead of os.execute("mkdir ...") / os.execute("move ...") so that
   no cmd.exe process (and no new window/focus event) is ever spawned when
   a replay is sorted — that is what was kicking fullscreen-exclusive games
   out to the desktop.
   The W (wide/Unicode) versions are used -- not A (ANSI) -- because
   folder names can come from window titles containing non-English text
   (Arabic, etc.); the A versions would mangle that (mojibake) since
   they interpret the bytes using the system's local ANSI codepage
   instead of UTF-16. */
BOOL   CreateDirectoryW(const WCHAR* lpPathName, void* lpSecurityAttributes);
BOOL   MoveFileExW(const WCHAR* lpExistingFileName, const WCHAR* lpNewFileName, DWORD dwFlags);
DWORD  GetLastError();

/* Reads the actual window title text (what NVIDIA/Windows Game Bar use
   to recognize games) instead of guessing from the exe filename. Uses
   the wide (Unicode) version so titles with accents/symbols come
   through correctly, then converts to UTF-8 for use in Lua strings. */
int    GetWindowTextW(HWND hWnd, WCHAR* lpString, int nMaxCount);
int    WideCharToMultiByte(unsigned int CodePage, DWORD dwFlags, const WCHAR* lpWideCharStr,
                            int cchWideChar, char* lpMultiByteStr, int cbMultiByte,
                            const char* lpDefaultChar, BOOL* lpUsedDefaultChar);
int    MultiByteToWideChar(unsigned int CodePage, DWORD dwFlags, const char* lpMultiByteStr,
                            int cbMultiByte, WCHAR* lpWideCharStr, int cchWideChar);

/* Used to detect automatically -- with no manual list at all -- whether
   the foreground window is an actual fullscreen game: a window is
   "fullscreen" here if its rectangle exactly covers the monitor it's on.
   This is the same signal Windows/GPU overlays use to decide a game is
   running exclusively, so browsers, Discord, Explorer, etc. (which are
   never truly fullscreen even when maximized -- maximized still leaves
   window-manager chrome/behavior different from exclusive fullscreen)
   won't be mistaken for games, and any game will be recognized without
   needing its name typed in anywhere. */
typedef struct { long left, top, right, bottom; } RECT;
typedef struct { DWORD cbSize; RECT rcMonitor; RECT rcWork; DWORD dwFlags; } MONITORINFO;
BOOL   GetWindowRect(HWND hWnd, RECT* lpRect);
HANDLE MonitorFromWindow(HWND hwnd, DWORD dwFlags);
BOOL   GetMonitorInfoW(HANDLE hMonitor, MONITORINFO* lpmi);

/* The Windows desktop itself is a real window (class "Progman", title
   "Program Manager"; on some setups a "WorkerW" window sits on top of
   it instead) and it always exactly covers the monitor -- so without
   this check, clicking empty desktop / having nothing open would get
   misdetected as a "fullscreen game" and sorted into a "Program
   Manager" folder. GetClassNameW lets us specifically recognize and
   exclude these shell windows. */
int    GetClassNameW(HWND hWnd, WCHAR* lpClassName, int nMaxCount);

/* A real Windows dialog box, used by the Update Checker to ask before it
   replaces this script's own file. OBS's Lua API has no way to open a
   window of its own, and MessageBoxW is the one Win32 call that gives a
   proper modal prompt with no extra dependencies, no manifest and no
   external process -- consistent with the rest of this file's "Win32
   directly, never a shell-out" approach. */
int    MessageBoxW(HWND hWnd, const WCHAR* lpText, const WCHAR* lpCaption, unsigned int uType);

/* Used to check whether a destination filename is already taken before
   moving a clip into place, so a same-second collision (two saves in
   the same second) picks a "(2)", "(3)"... suffix instead of silently
   overwriting an existing clip. */
DWORD  GetFileAttributesW(const WCHAR* lpFileName);

/* Used to mark known_games.txt as a hidden file right after creating
   it, so it doesn't sit around looking like clutter next to the script
   in a normal Explorer window -- it's an internal data file the script
   maintains itself, not something most users need to see or open. */
BOOL   SetFileAttributesW(const WCHAR* lpFileName, DWORD dwFileAttributes);

/* Wide-character file + environment access (see the "W" helper at the top of
   the file): lets paths containing Arabic / any non-ASCII text work, which
   the ANSI-codepage io.open()/os.getenv() cannot do. */
HANDLE CreateFileW(const WCHAR* lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode,
                    void* lpSecurityAttributes, DWORD dwCreationDisposition,
                    DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
BOOL   ReadFile(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead,
                 DWORD* lpNumberOfBytesRead, void* lpOverlapped);
BOOL   WriteFile(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite,
                  DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
BOOL   DeleteFileW(const WCHAR* lpFileName);
DWORD  GetEnvironmentVariableW(const WCHAR* lpName, WCHAR* lpBuffer, DWORD nSize);


/* WinHTTP -- used for the optional Steam Store search lookup below.
   A real Win32 API (ships with Windows since XP SP2), not a shell-out,
   so this stays consistent with the rest of the script's "no
   cmd.exe/PowerShell" approach. Used ONLY as a last-resort name lookup
   for a game with neither a local mapping nor a usable window title --
   see steam_lookup_name() further down. */
typedef void* HINTERNET;
HINTERNET WinHttpOpen(const WCHAR* pszAgentW, DWORD dwAccessType,
                       const WCHAR* pszProxyW, const WCHAR* pszProxyBypassW, DWORD dwFlags);
HINTERNET WinHttpConnect(HINTERNET hSession, const WCHAR* pswzServerName,
                          unsigned short nServerPort, DWORD dwReserved);
HINTERNET WinHttpOpenRequest(HINTERNET hConnect, const WCHAR* pwszVerb, const WCHAR* pwszObjectName,
                              const WCHAR* pwszVersion, const WCHAR* pwszReferrer,
                              const WCHAR** ppwszAcceptTypes, DWORD dwFlags);
BOOL      WinHttpSendRequest(HINTERNET hRequest, const WCHAR* lpszHeaders, DWORD dwHeadersLength,
                              void* lpOptional, DWORD dwOptionalLength, DWORD dwTotalLength, uintptr_t dwContext);
BOOL      WinHttpReceiveResponse(HINTERNET hRequest, void* lpReserved);
BOOL      WinHttpQueryDataAvailable(HINTERNET hRequest, DWORD* lpdwNumberOfBytesAvailable);
BOOL      WinHttpReadData(HINTERNET hRequest, void* lpBuffer, DWORD dwNumberOfBytesToRead, DWORD* lpdwNumberOfBytesRead);
BOOL      WinHttpCloseHandle(HINTERNET hInternet);
BOOL      WinHttpSetTimeouts(HINTERNET hInternet, int nResolveTimeout, int nConnectTimeout,
                              int nSendTimeout, int nReceiveTimeout);

/* Lets https_get() below read the HTTP status code of a response. Without
   it, a 404/500 page was treated as a perfectly good body -- which is how
   a GitHub error page could end up being written straight over this
   script's own file by the auto-updater. */
BOOL      WinHttpQueryHeaders(HINTERNET hRequest, DWORD dwInfoLevel, const WCHAR* pwszName,
                               void* lpBuffer, DWORD* lpdwBufferLength, DWORD* lpdwIndex);

/* Used by the Update Checker to relaunch OBS itself right after an update
   is installed, instead of leaving the user to close and reopen it by
   hand. GetModuleFileNameW(NULL, ...) with a NULL module handle returns
   the path of the currently-running executable (obs64.exe) -- exactly
   what needs to be started again. */
DWORD  GetModuleFileNameW(HANDLE hModule, WCHAR* lpFilename, DWORD nSize);

/* ShellExecuteW -- not CreateProcess -- launches the new OBS instance:
   it hands the launch to the shell (as if the user double-clicked
   obs64.exe or its shortcut), which picks up the right working
   directory and any "Run as administrator" requirement automatically.
   A NULL lpDirectory makes it inherit this process's current directory,
   which is already correct since OBS itself is running from it. */
HANDLE ShellExecuteW(HWND hwnd, const WCHAR* lpOperation, const WCHAR* lpFile,
                      const WCHAR* lpParameters, const WCHAR* lpDirectory, int nShowCmd);

/* Once the new OBS instance has been launched, the old one has to exit so
   the two don't fight over the same profile/scene collection lock files.
   There is no OBS API for a script to close its own host application, so
   this is the one place in the whole script that reaches past OBS itself
   -- and only after a fresh copy is already starting up.
   This is done by finding this process's own main window and posting it
   a normal WM_CLOSE, the same message Windows sends when the user clicks
   the title-bar X -- NOT ExitProcess(), which used to hard-kill the
   process. A hard kill skips OBS's own shutdown path entirely, so it
   never gets to write the "clean exit" marker it checks on the next
   launch -- that's what was popping the "OBS Studio did not properly
   shut down" / Safe Mode prompt after every self-update. WM_CLOSE lets
   OBS run its real shutdown (save config, release the single-instance
   lock, mark the exit clean) before the process actually ends. */
DWORD  GetCurrentProcessId();
DWORD  WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
typedef struct { DWORD dwLowDateTime; DWORD dwHighDateTime; } FILETIME;
BOOL   GetProcessTimes(HANDLE hProcess, FILETIME* lpCreationTime, FILETIME* lpExitTime,
                       FILETIME* lpKernelTime, FILETIME* lpUserTime);
BOOL   IsWindowVisible(HWND hWnd);
typedef int (*WNDENUMPROC)(HWND, long);
BOOL   EnumWindows(WNDENUMPROC lpEnumFunc, long lParam);
BOOL   PostMessageW(HWND hWnd, unsigned int Msg, unsigned long wParam, long lParam);

/* GetWindow(hWnd, GW_OWNER) tells an owned window (Scripts dialog, floating
   dock) from the real top-level main window, so relaunch_obs() closes OBS's
   main window and never one of those. */
HWND   GetWindow(HWND hWnd, unsigned int uCmd);
]]

    user32   = ffi.load("user32")
    kernel32 = ffi.load("kernel32")
    winhttp  = ffi.load("winhttp")
    shell32  = ffi.load("shell32")
end

if sorter_available then
    local init_ok, init_err = pcall(init_win32)
    if not init_ok then
        sorter_available = false
        obs.script_log(obs.LOG_WARNING,
            "OBS Clip Suite: the Replay Organizer needs Windows + LuaJIT FFI and couldn't " ..
            "initialise (" .. tostring(init_err) .. ") -- that module is disabled; the " ..
            "Replay Buffer Restarter and Clip Alert Sound still work normally.")
    end
end

-- PROCESS_QUERY_LIMITED_INFORMATION: unlike PROCESS_QUERY_INFORMATION,
-- this is specifically designed to let a normal (non-elevated) process
-- like OBS still read basic info — such as the exe name — from a
-- process running with higher privileges (Administrator), which is
-- common for games with anti-cheat. Without this, OpenProcess silently
-- fails for elevated games and everything falls back to "Unsorted".
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

-- MoveFileExA flags
local MOVEFILE_COPY_ALLOWED     = 0x2 -- allows the move to work across drives too
local ERROR_ALREADY_EXISTS      = 183
local ERROR_SHARING_VIOLATION   = 32
local ERROR_LOCK_VIOLATION      = 33
local CP_UTF8                   = 65001
local MOVE_RETRY_ATTEMPTS       = 6
local MOVE_RETRY_DELAY_MS       = 300
local MONITOR_DEFAULTTONEAREST  = 0x2
local INVALID_FILE_ATTRIBUTES   = 0xFFFFFFFF
local FILE_ATTRIBUTE_HIDDEN     = 0x2

-- WinHTTP constants for the optional Steam lookup (see steam_lookup_name
-- further down). Timeouts are intentionally short-ish: this call can run
-- on OBS's frontend-event thread, so a slow/unreachable network should
-- not be able to stall OBS for long. Worst case (each phase timing out
-- in sequence) is bounded to roughly the sum of these four values.
local WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0
local WINHTTP_FLAG_SECURE               = 0x00800000
-- Kept short on purpose -- this call runs synchronously on OBS's
-- frontend-event thread (the same thread that has to restart the Replay
-- Buffer right after), so a slow/unreachable connection blocks the
-- whole OBS UI for as long as these add up to. Previously 1500+1500+
-- 1500+2500 = 7000ms worst case, then 3300ms; now ~2300ms worst case, which
-- is still enough for a normal connection to reach Steam but no longer
-- freezes OBS for the better part of ten seconds when it can't. This
-- only ever runs at all for a genuinely new, never-before-seen exe with
-- no window title -- everything else is served from KNOWN_GAMES/
-- known_games.txt without touching the network.
local STEAM_RESOLVE_TIMEOUT_MS          = 500
local STEAM_CONNECT_TIMEOUT_MS          = 500
local STEAM_SEND_TIMEOUT_MS             = 500
local STEAM_RECEIVE_TIMEOUT_MS          = 800

-- Wide-char buffer size for the exe path. 32760 (not the old 260/MAX_PATH)
-- so deeply nested Steam/library paths or long-path-enabled installs
-- don't get silently truncated.
local EXE_PATH_BUF_LEN          = 32760

-- Reads the real window title (e.g. "ELDEN RING", "Counter-Strike 2") --
-- the same signal NVIDIA/Windows Game Bar use to recognize a game,
-- which is far more reliable than guessing from the exe filename.
-- Returns a cleaned UTF-8 string, or nil if there's no usable title.
-- 1024 wide characters, not 260. GetWindowTextW silently truncates to
-- whatever it's given, and a few games/launchers carry long titles (with
-- a subtitle, build string or server name appended). A truncated title
-- produced a truncated folder name, and if the cut-off point ever moved
-- the same game earned itself a second folder.
local TITLE_BUF_LEN = 1024
local title_wbuf = ffi and ffi.new("WCHAR[?]", TITLE_BUF_LEN) or nil
local class_wbuf = ffi and ffi.new("WCHAR[?]", 260) or nil

local function get_window_title(hwnd)
    local wbuf = title_wbuf
    local len = user32.GetWindowTextW(hwnd, wbuf, TITLE_BUF_LEN)
    if len <= 0 then
        return nil
    end

    -- Ask how many bytes the UTF-8 conversion needs, then convert.
    local needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, len, nil, 0, nil, nil)
    if needed <= 0 then
        return nil
    end
    local buf = ffi.new("char[?]", needed)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, len, buf, needed, nil, nil)
    local title = ffi.string(buf, needed)

    -- Strip trademark/registered symbols (™ / ®) some games include in
    -- their title text, and trim whitespace.
    title = title:gsub("\226\132\162", "")  -- U+2122 ™ (UTF-8: E2 84 A2)
    title = title:gsub("\194\174", "")      -- U+00AE ® (UTF-8: C2 AE)
    title = title:match("^%s*(.-)%s*$")

    if title == "" then
        return nil
    end
    return title
end

-- Exposed so the Update Checker (outside this block) can recognise OBS's
-- main window by its title when it has to close it after an update.
Sorter.get_window_title = get_window_title

-- Converts a UTF-8 Lua string to a null-terminated UTF-16 buffer, for
-- passing to the Unicode ("W") Win32 functions below -- needed so
-- folder/file names with non-English text (Arabic, etc.) are written
-- correctly instead of turning into mojibake.
function utf8_to_wide(str)
    if str == nil then
        return nil
    end
    -- MultiByteToWideChar with a length of 0 reports "0 needed", which the
    -- check below reads as failure -- so an empty string used to come back
    -- as nil and get passed on to CreateDirectoryW/GetFileAttributesW as a
    -- null pointer. Return a proper empty wide string instead.
    if str == "" then
        local empty = ffi.new("WCHAR[?]", 1)
        empty[0] = 0
        return empty
    end
    local needed = kernel32.MultiByteToWideChar(CP_UTF8, 0, str, #str, nil, 0)
    if needed <= 0 then
        return nil
    end
    local wbuf = ffi.new("WCHAR[?]", needed + 1)
    kernel32.MultiByteToWideChar(CP_UTF8, 0, str, #str, wbuf, needed)
    wbuf[needed] = 0
    return wbuf
end

-- Win32 (UTF-16) implementations of the W helper -- replace the io-based
-- fallbacks defined at the top of the file.
if sorter_available then
    local GENERIC_READ, GENERIC_WRITE, FILE_APPEND_DATA = 0x80000000, 0x40000000, 0x4
    local FILE_SHARE_READ_WRITE = 3
    local OPEN_EXISTING, CREATE_ALWAYS, OPEN_ALWAYS = 3, 2, 4
    local FILE_ATTRIBUTE_NORMAL = 0x80

    local function open_handle(path, access, disposition)
        local wide = utf8_to_wide(path)
        if not wide then return nil end
        local h = kernel32.CreateFileW(wide, access, FILE_SHARE_READ_WRITE, nil,
            disposition, FILE_ATTRIBUTE_NORMAL, nil)
        if h == nil or tonumber(ffi.cast("intptr_t", h)) == -1 then
            return nil
        end
        return h
    end

    function W.read_file(path)
        local h = open_handle(path, GENERIC_READ, OPEN_EXISTING)
        if not h then return nil end
        local chunk = 1048576
        local buf = ffi.new("char[?]", chunk)
        local got = ffi.new("DWORD[1]")
        local parts, ok = {}, true
        while true do
            if kernel32.ReadFile(h, buf, chunk, got, nil) == 0 then
                ok = false
                break
            end
            if got[0] == 0 then break end
            parts[#parts + 1] = ffi.string(buf, got[0])
        end
        kernel32.CloseHandle(h)
        if not ok then return nil end
        return table.concat(parts)
    end

    function W.write_file(path, content, append)
        local h = open_handle(path, append and FILE_APPEND_DATA or GENERIC_WRITE,
            append and OPEN_ALWAYS or CREATE_ALWAYS)
        if not h then return false end
        local total, offset = #content, 0
        local base = ffi.cast("const char*", content)
        local written = ffi.new("DWORD[1]")
        local ok = true
        while offset < total do
            local n = math.min(1048576, total - offset)
            if kernel32.WriteFile(h, base + offset, n, written, nil) == 0 or written[0] == 0 then
                ok = false
                break
            end
            offset = offset + tonumber(written[0])
        end
        kernel32.CloseHandle(h)
        return ok
    end

    function W.exists(path)
        local wide = utf8_to_wide(path)
        if not wide then return false end
        return tonumber(kernel32.GetFileAttributesW(wide)) ~= INVALID_FILE_ATTRIBUTES
    end

    function W.remove(path)
        local wide = utf8_to_wide(path)
        if not wide then return false end
        return kernel32.DeleteFileW(wide) ~= 0
    end

    function W.getenv(name)
        local wname = utf8_to_wide(name)
        if not wname then return nil end
        local needed = kernel32.GetEnvironmentVariableW(wname, nil, 0)
        if needed == 0 then return nil end
        local wbuf = ffi.new("WCHAR[?]", needed)
        local len = kernel32.GetEnvironmentVariableW(wname, wbuf, needed)
        if len == 0 then return nil end
        local bytes = kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, len, nil, 0, nil, nil)
        if bytes <= 0 then return nil end
        local out = ffi.new("char[?]", bytes)
        kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, len, out, bytes, nil, nil)
        return ffi.string(out, bytes)
    end
end

-- Reads a window's class name (e.g. "Progman", "WorkerW", "CabinetWClass")
-- as a lowercase UTF-8 string, or nil if it couldn't be read.
local function get_window_class(hwnd)
    local wbuf = class_wbuf
    local len = user32.GetClassNameW(hwnd, wbuf, 260)
    if len <= 0 then
        return nil
    end
    local needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, len, nil, 0, nil, nil)
    if needed <= 0 then
        return nil
    end
    local buf = ffi.new("char[?]", needed)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, len, buf, needed, nil, nil)
    return ffi.string(buf, needed):lower()
end

-- The desktop shell windows -- always exactly full-screen, never a game.
local DESKTOP_SHELL_CLASSES = {
    progman = true, -- "Program Manager", the classic desktop window
    workerw = true, -- sits on top of Progman on modern Windows (wallpaper host)
}

-- True if hwnd's rectangle exactly matches the full rectangle of the
-- monitor it's on -- i.e. genuinely fullscreen, the way an exclusive-
-- fullscreen (or fullscreen-borderless) game runs, and the way a
-- maximized-but-windowed app (browser, Discord, Explorer...) does not.
-- Explicitly excludes the desktop shell itself (Program Manager /
-- WorkerW), which also always covers the whole monitor but isn't a game.
local function is_window_fullscreen(hwnd)
    local class = get_window_class(hwnd)
    if class and DESKTOP_SHELL_CLASSES[class] then
        return false
    end

    local wrect = ffi.new("RECT")
    if user32.GetWindowRect(hwnd, wrect) == 0 then
        return false
    end

    local hmon = user32.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)
    if hmon == nil then
        return false
    end

    local mi = ffi.new("MONITORINFO")
    mi.cbSize = ffi.sizeof("MONITORINFO")
    if user32.GetMonitorInfoW(hmon, mi) == 0 then
        return false
    end

    return wrect.left == mi.rcMonitor.left and wrect.top == mi.rcMonitor.top
       and wrect.right == mi.rcMonitor.right and wrect.bottom == mi.rcMonitor.bottom
end

-- Returns { exe_name = "...", window_title = "..." or nil } for the
-- foreground window, or nil if it couldn't be determined at all.
-- These messages are produced from a timer that ticks twice a second, and
-- the conditions behind them are usually persistent, not momentary: an
-- elevated game that OpenProcess can't be opened against stays elevated
-- for the entire session. Logging every occurrence buried the OBS script
-- log under thousands of identical lines per gaming session, which made
-- every OTHER message in it unfindable. Each distinct message is now
-- logged at most once per minute.
local LOG_THROTTLE_NS = 60 * 1e9
local last_logged_at = {}

local function log_throttled(msg)
    local now = obs.os_gettime_ns()
    local previous = last_logged_at[msg]
    if previous and (now - previous) < LOG_THROTTLE_NS then
        return
    end
    last_logged_at[msg] = now
    print(msg)
end

-- Exposed on the module table (same pattern as Sorter.https_get further
-- down) so the Update Checker, which lives outside this "do" block and so
-- outside the ffi.cdef above, can put a real dialog on screen without
-- redeclaring the whole FFI layer a second time.
--
-- MB_YESNOCANCEL is deliberate: Windows does not allow MessageBox button
-- captions to be renamed, so what each of the three buttons means is
-- spelled out in the message text rather than left to be guessed from
-- "Yes / No / Cancel".
local MB_YESNOCANCEL   = 0x00000003
local MB_ICONQUESTION  = 0x00000020
local MB_SETFOREGROUND = 0x00010000
local MB_TOPMOST       = 0x00040000

Sorter.MB_IDYES    = 6
Sorter.MB_IDNO     = 7
Sorter.MB_IDCANCEL = 2

-- Returns 6 (Yes), 7 (No), 2 (Cancel), or nil if no dialog could be shown
-- at all -- callers must treat nil as "don't assume consent".
function Sorter.ask_yes_no_cancel(text, caption)
    if not sorter_available then
        return nil
    end
    local ok, result = pcall(function()
        return user32.MessageBoxW(nil, utf8_to_wide(text), utf8_to_wide(caption),
            MB_YESNOCANCEL + MB_ICONQUESTION + MB_SETFOREGROUND + MB_TOPMOST)
    end)
    if not ok then
        return nil
    end
    return tonumber(result)
end

-- Whether a genuinely fullscreen window (i.e. almost certainly a game) is
-- in the foreground right now. The Update Checker uses this to hold the
-- dialog back: this whole script exists to avoid yanking a
-- fullscreen-exclusive game out to the desktop, so throwing a topmost
-- modal window on screen mid-match would defeat its entire purpose.
function Sorter.foreground_is_fullscreen()
    if not sorter_available then
        return false
    end
    local ok, result = pcall(function()
        local hwnd = user32.GetForegroundWindow()
        if hwnd == nil then
            return false
        end
        return is_window_fullscreen(hwnd)
    end)
    if not ok then
        return false
    end
    return result and true or false
end

-- Allocated ONCE and reused. This function runs on a 500 ms timer for the
-- entire time the Replay Buffer is active, and it used to ffi.new() a
-- fresh 32760-wide-character buffer (~64 KB) on every tick -- roughly
-- 128 KB/second of pure garbage handed to the collector during a gaming
-- session, for a value that is overwritten each time anyway. The same
-- applies to the small DWORD scratch cells.
local fg_exe_wbuf = ffi and ffi.new("WCHAR[?]", EXE_PATH_BUF_LEN) or nil
local fg_size_cell = ffi and ffi.new("DWORD[1]") or nil
local fg_pid_cell  = ffi and ffi.new("DWORD[1]") or nil

local function get_foreground_info()
    local hwnd = user32.GetForegroundWindow()
    if hwnd == nil then
        log_throttled("OBS Replay Organizer: GetForegroundWindow returned nothing.")
        return nil
    end

    local pid = fg_pid_cell
    pid[0] = 0
    user32.GetWindowThreadProcessId(hwnd, pid)
    if pid[0] == 0 then
        log_throttled("OBS Replay Organizer: couldn't get a process id for the foreground window.")
        return nil
    end

    local window_title = get_window_title(hwnd)
    local fullscreen = is_window_fullscreen(hwnd)

    -- When the exe can't be read (anti-cheat / protected process), a
    -- fullscreen window that has a title is still treated as a game and
    -- named from that title instead of being lost to "Desktop".
    local function protected_fallback(reason)
        log_throttled("OBS Replay Organizer: " .. reason)
        if fullscreen and window_title then
            return { exe_name = "?protected", exe_path = nil, window_title = window_title,
                     is_fullscreen = true, protected = true }
        end
        return nil
    end

    local hproc = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid[0])
    if hproc == nil then
        return protected_fallback("OpenProcess failed for pid " .. tostring(pid[0]) ..
              " (protected/elevated process) -- using its window title.")
    end

    local wbuf = fg_exe_wbuf
    local size = fg_size_cell
    size[0] = EXE_PATH_BUF_LEN
    local ok = kernel32.QueryFullProcessImageNameW(hproc, 0, wbuf, size)
    kernel32.CloseHandle(hproc)

    if ok == 0 then
        return protected_fallback("QueryFullProcessImageNameW failed for pid " .. tostring(pid[0]) .. " -- using its window title.")
    end

    -- Convert the wide path to UTF-8 the same way get_window_title() does,
    -- so a non-English (e.g. Arabic) user/folder name in the exe's path
    -- comes through correctly instead of turning into mojibake.
    local needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, size[0], nil, 0, nil, nil)
    if needed <= 0 then
        return protected_fallback("couldn't convert exe path to UTF-8 for pid " .. tostring(pid[0]) .. ".")
    end
    local buf = ffi.new("char[?]", needed)
    kernel32.WideCharToMultiByte(CP_UTF8, 0, wbuf, size[0], buf, needed, nil, nil)
    local full_path = ffi.string(buf, needed)

    local exe_name = full_path:match("([^\\/]+)$") or full_path
    exe_name = (exe_name:gsub("%.[Ee][Xx][Ee]$", ""))

    return { exe_name = exe_name, exe_path = full_path, window_title = window_title, is_fullscreen = fullscreen }
end

------------------------------------------------------------------
-- Settings
------------------------------------------------------------------
local sorter_enabled = true
local name_map = {} -- lowercase raw exe name -> friendly folder name
local current_settings = nil -- kept so the "Add" button can read/write settings

-- How many seconds of foreground-window history to look back over when a
-- clip is saved (see fg_history / get_dominant_foreground below). Default
-- covers the usual gap between pressing the save hotkey and the
-- REPLAY_BUFFER_SAVED event actually firing (buffer flush + mux time).
local lookback_s = 8

-- Strict mode (default ON): only real games get their own folder. See
-- is_in_game_library() and the decision in on_replay_saved.
-- Games-only (fixed): only games get their own folder, everything else -> Desktop.
local only_real_games = true

-- Whether the last-resort Steam Store lookup (see steam_lookup_name,
-- much further down) is allowed to run at all.
local steam_lookup_enabled = true

------------------------------------------------------------------
-- Foreground-window history
--
-- Problem this solves: REPLAY_BUFFER_SAVED fires only after OBS has
-- finished flushing/muxing the buffer to disk, which can be a couple of
-- seconds AFTER the user actually pressed the save hotkey. Checking
-- the foreground window only at save time can therefore catch whatever
-- the user alt-tabbed to in the meantime (Discord, chat, etc.) instead
-- of the game the clip is actually from.
--
-- Fix: poll the foreground window on a short timer the whole time this
-- module is active, keep a short rolling history of it, and at save
-- time pick whichever app was in the foreground for the LARGEST share
-- of the last `lookback_s` seconds -- not just whatever is in the
-- foreground at the instant the event fires.
------------------------------------------------------------------
-- Retry callbacks of clip moves that hit a locked file (see move_file), kept
-- so script_unload can cancel them.
local pending_move_timers = {}

local FG_POLL_MS       = 500        -- how often we sample the foreground window
local FG_HISTORY_MAX_S = 120        -- drop samples older than this (keeps the table small)
local fg_history = {}               -- { {start_ns, end_ns, exe_name, window_title, is_fullscreen}, ... }

local function fg_poll_tick()
    if not sorter_enabled or not sorter_available then
        return
    end
    -- No point burning Win32 calls twice a second when there isn't even
    -- a replay buffer running to eventually trigger a save -- e.g. the
    -- user has OBS open just to browse scenes, or hasn't started the
    -- buffer yet. This is checked every tick since the buffer can be
    -- started/stopped at any time.
    if not obs.obs_frontend_replay_buffer_active() then
        return
    end

    local ok, info = pcall(get_foreground_info)
    local now = obs.os_gettime_ns()
    if not ok or info == nil then
        return
    end

    local last = fg_history[#fg_history]
    -- Polling is skipped entirely whenever the Replay Buffer isn't running
    -- (see the early return above), so consecutive samples are NOT always
    -- FG_POLL_MS apart. Without this gap check, stopping the buffer while
    -- app X was focused and restarting it an hour later -- still on X --
    -- just stretched that one entry's end_ns across the whole hour, so the
    -- very first save after restarting counted an hour of "focus time"
    -- that was never actually observed. Treat anything beyond a few missed
    -- ticks as a break and start a fresh entry.
    local gap_limit_ns = FG_POLL_MS * 3 * 1e6
    local contiguous = last and (now - last.end_ns) <= gap_limit_ns
    -- is_fullscreen is part of "same sample" on purpose: it used to be recorded
    -- only the first time an app/title was seen, so a game that started
    -- windowed (or on a loading screen) and went fullscreen a moment later
    -- stayed "not fullscreen" forever and its clips went to Desktop -- and a
    -- fullscreen YouTube video could be taken for a game the other way round.
    if contiguous and last.exe_name == info.exe_name
       and last.window_title == info.window_title
       and last.is_fullscreen == info.is_fullscreen then
        -- Same app/window/state as last sample -- just extend its time range
        -- instead of growing the table with one entry per poll tick.
        last.end_ns = now
    else
        fg_history[#fg_history + 1] = {
            start_ns = now, end_ns = now,
            exe_name = info.exe_name, exe_path = info.exe_path, window_title = info.window_title,
            is_fullscreen = info.is_fullscreen, protected = info.protected,
        }
    end

    local cutoff = now - (FG_HISTORY_MAX_S * 1e9)
    while fg_history[1] and fg_history[1].end_ns < cutoff do
        table.remove(fg_history, 1)
    end
end

-- Returns the same shape as get_foreground_info() (exe_name, window_title,
-- is_fullscreen), but for whichever app occupied the most total time
-- within the last `seconds` seconds of history -- or nil if there's no
-- history yet (e.g. script just loaded).
local function get_dominant_foreground(seconds)
    if #fg_history == 0 then
        return nil
    end

    local now = obs.os_gettime_ns()
    local window_start = now - (seconds * 1e9)
    local totals = {} -- "exe\0title" -> { duration_ns = n, info = {...} }

    for _, entry in ipairs(fg_history) do
        local s = math.max(entry.start_ns, window_start)
        local e = math.min(entry.end_ns, now)
        if e > s then
            local key = entry.exe_name .. "\0" .. (entry.window_title or "")
            local rec = totals[key]
            if not rec then
                rec = { duration_ns = 0, info = entry }
                totals[key] = rec
            end
            -- The history is chronological, so this ends up holding the LATEST
            -- sample of this app/window -- i.e. its most recent fullscreen
            -- state, which is what decides Desktop vs. game folder.
            rec.info = entry
            rec.duration_ns = rec.duration_ns + (e - s)
        end
    end

    local best, best_ns = nil, -1
    for _, rec in pairs(totals) do
        if rec.duration_ns > best_ns then
            best, best_ns = rec.info, rec.duration_ns
        end
    end
    return best
end

local function parse_name_map(text)
    local map = {}
    if text == nil then return map end
    for line in text:gmatch("[^\r\n]+") do
        local raw, friendly = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if raw and friendly and raw ~= "" and friendly ~= "" then
            map[raw:lower()] = friendly
        end
    end
    return map
end

-- Built-in table for well-known games whose exe name has nothing to do
-- with the game's real name. Checked before the automatic first-word
-- rule, but after your own custom entries above, so you can always
-- override these too. Fully offline — no internet, no API keys, just a
-- static local list that ships with the script.
-- Built-in defaults. load_known_games() below merges this table with
-- your own known_games.txt in memory every time the script loads (your
-- file wins), so games added here in a new version reach existing users
-- too, without anybody's file being rewritten. Add or override a game
-- in known_games.txt instead of editing the script's code.
--
-- Deliberately NOT listed: exe names so generic that they can belong to
-- some other program (cod, wow, nms, dbd, cities, shootergame,
-- discovery, ...). Those games are named from their window title
-- instead; add them yourself via the "Add" button or known_games.txt if
-- you want a fixed name.
local KNOWN_GAMES_DEFAULTS = {
    -- Battle royale / extraction
    ["tslgame"]              = "PUBG",
    ["r5apex"]               = "Apex Legends",
    ["fortniteclient"]       = "Fortnite",
    ["fortniteclient-win64-shipping"] = "Fortnite",
    ["escapefromtarkov"]     = "Escape from Tarkov",
    ["sotgame"]              = "Sea of Thieves",
    ["huntgame"]             = "Hunt: Showdown",
    ["fallguys_client_game"] = "Fall Guys",
    ["narakabladepoint"]     = "Naraka: Bladepoint",

    -- Call of Duty family
    ["modernwarfare"]        = "Call of Duty",
    ["blackops6"]            = "Call of Duty: Black Ops 6",

    -- Tom Clancy / Ubisoft
    ["rainbowsix"]           = "Rainbow Six Siege",
    ["rainbowsix_vulkan"]    = "Rainbow Six Siege",

    -- GTA / Rockstar
    ["gta5"]                 = "GTA V",
    ["fivem"]                = "GTA V (FiveM)",
    ["rdr2"]                 = "Red Dead Redemption 2",

    -- MMO / RPG
    ["ffxiv_dx11"]           = "Final Fantasy XIV",
    ["wowclassic"]           = "WoW Classic",
    ["pathofexilesteam"]     = "Path of Exile",
    ["pathofexile_x64steam"] = "Path of Exile",
    ["newworld"]             = "New World",
    ["lostark"]              = "Lost Ark",
    ["eldenring"]            = "Elden Ring",
    ["fsd"]                  = "Deep Rock Galactic",     -- stands for the studio's old codename
    ["fsd-win64-shipping"]   = "Deep Rock Galactic",

    -- Shooters / co-op
    ["squadgame"]            = "Squad",
    ["insurgencysandstorm"]  = "Insurgency: Sandstorm",
    ["insurgencysandstorm-win64-shipping"] = "Insurgency: Sandstorm",
    ["bf2042"]               = "Battlefield 2042",
    ["bfv"]                  = "Battlefield V",

    -- MOBA / competitive
    ["leagueclient"]         = "League of Legends",
    ["league of legends"]    = "League of Legends",
    ["deadbydaylight"]       = "Dead by Daylight",
    ["deadbydaylight-win64-shipping"] = "Dead by Daylight",

    -- Blizzard
    ["overwatch"]            = "Overwatch 2",

    -- Other
    ["destiny2"]             = "Destiny 2",
    ["re8"]                  = "Resident Evil Village",
    ["ac_client"]            = "Assassin's Creed",
    ["yuanshen"]             = "Genshin Impact", -- CN client build name
    ["robloxplayerbeta"]     = "Roblox",

    -- Added: games from your library screenshots + other well-known
    -- Steam titles whose exe name doesn't match the store title.
    -- (Anything NOT listed here -- Terraria, Among Us, VRChat, Rust,
    -- Squad, PUBG, RDR2, GTA V, etc. -- already worked before this
    -- update: the script falls back to the game's own window title,
    -- which covers most normally-named games automatically.)
    ["cities2"]              = "Cities: Skylines II",
    ["devilmaycry5"]         = "Devil May Cry 5",
    ["dmc4sedx9"]            = "Devil May Cry 4 Special Edition",
    ["dmc4sedx11"]           = "Devil May Cry 4 Special Edition",
    ["dyinglightgame"]       = "Dying Light",
    ["eurotrucks2"]          = "Euro Truck Simulator 2",
    ["forzahorizon5"]        = "Forza Horizon 5",
    ["hogwartslegacy"]       = "Hogwarts Legacy",
    ["hollow_knight"]        = "Hollow Knight",
    ["flightsimulator"]      = "Microsoft Flight Simulator (2020)",
    ["mk11"]                 = "Mortal Kombat 11",
    ["re7"]                  = "Resident Evil 7 Biohazard",
    ["re2"]                  = "Resident Evil 2",
    ["re3"]                  = "Resident Evil 3", -- also launches Resident Evil Resistance (bundled in the same exe -- can't be told apart by process name)
    ["re4"]                  = "Resident Evil 4",
    ["acvalhalla"]           = "Assassin's Creed Valhalla",
    ["gta5_enhanced"]        = "Grand Theft Auto V Enhanced",
    ["witcher3"]             = "The Witcher 3: Wild Hunt",
    ["cs2"]                  = "Counter-Strike 2",
    ["dota2"]                = "Dota 2",
    ["valheim"]              = "Valheim",
    ["stardewvalley"]        = "Stardew Valley",
    ["hades2"]               = "Hades II",
    ["bg3"]                  = "Baldur's Gate 3",
    ["bg3_dx11"]             = "Baldur's Gate 3",
    ["cyberpunk2077"]        = "Cyberpunk 2077",
    ["starfield"]            = "Starfield",
    ["helldivers2"]          = "Helldivers 2",
    ["monsterhunterwilds"]   = "Monster Hunter Wilds",
    ["palworld-win64-shipping"] = "Palworld",
}

-- Filled in at load time by load_known_games() below -- either from the
-- external known_games.txt file (normal case) or from the defaults
-- table above (first run, or if the file can't be read for some reason).
local KNOWN_GAMES = {}

-- Minimal, self-contained directory creation used only here -- NOT the
-- Sorter module's own ensure_folder() (defined further down in this
-- file), because that's a local declared later in this same top-level
-- chunk: a function defined up here textually before it would only see
-- ensure_folder as an unresolved global (nil), not the real local, so
-- calling it from here would error. kernel32/utf8_to_wide are already
-- defined above this point, so this small inline version is safe.
local function ensure_dir_early(win_folder)
    kernel32.CreateDirectoryW(utf8_to_wide(win_folder), nil)
end

-- known_games.txt now lives in the user's own per-user OBS config folder
-- (%APPDATA%\obs-studio\script-data\...) instead of next to this .lua
-- file. The .lua file itself usually sits under
-- C:\Program Files\obs-studio\..., which a normal (non-admin) OBS
-- process cannot write to -- every save was silently failing with
-- "couldn't save it to ...known_games.txt", so newly-detected games via
-- Steam were re-looked-up every session instead of ever being cached.
-- %APPDATA%\obs-studio is where OBS keeps its own per-user settings
-- already, so it's guaranteed to exist and be writable without admin.
-- Falls back to the old next-to-the-script location only if APPDATA
-- isn't set for some reason (should not normally happen on Windows).
local function known_games_file_path()
    local appdata = W.getenv("APPDATA")
    if appdata and appdata ~= "" then
        local base_dir = appdata .. "\\obs-studio\\script-data"
        local dir = base_dir .. "\\OBS-Clip-Suite"
        ensure_dir_early(base_dir)
        ensure_dir_early(dir)
        return dir .. "\\known_games.txt"
    end
    return script_path() .. "known_games.txt"
end

local function load_known_games()
    local path = known_games_file_path()

    -- Start from the built-in defaults EVERY time, then lay the user's file
    -- over them. The old version only seeded the file once and never read the
    -- defaults again, so games added in later script versions never reached
    -- anyone who already had a file. (Copied, not returned directly: the
    -- table is modified during a session.)
    local map = {}
    for raw, friendly in pairs(KNOWN_GAMES_DEFAULTS) do
        map[raw] = friendly
    end

    local text = W.read_file(path)
    if not text then
        -- First run on this machine (or the file got deleted): create a
        -- small file with just the instructions. It no longer holds a copy
        -- of the defaults -- those are merged in above.
        local header =
            "-- OBS Replay Organizer: your own known-games list. One\n" ..
            "-- 'raw-exe-name=Friendly Name' per line (matching is case-insensitive).\n" ..
            "-- Lines starting with -- are comments. The built-in game list is\n" ..
            "-- merged in automatically; entries here override it. Names found\n" ..
            "-- through the Steam lookup are added below. Reload the script (or\n" ..
            "-- restart OBS) to pick up changes.\n"
        if W.write_file(path, header) then
            kernel32.SetFileAttributesW(utf8_to_wide(path), FILE_ATTRIBUTE_HIDDEN)
        else
            print("OBS Replay Organizer: couldn't create " .. path .. " -- using built-in defaults only.")
        end
        return map
    end

    for line in text:gmatch("[^\r\n]+") do
        if not line:match("^%s*%-%-") then
            local raw, friendly = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
            if raw and friendly and raw ~= "" and friendly ~= "" then
                map[raw:lower()] = friendly
            end
        end
    end
    -- Also (re-)apply the hidden attribute here for anyone who already
    -- had known_games.txt from before this was added on creation -- a
    -- no-op if it's already hidden.
    kernel32.SetFileAttributesW(utf8_to_wide(path), FILE_ATTRIBUTE_HIDDEN)
    return map
end

-- Windows device names that can never be used as a file/folder name,
-- regardless of extension (CON, CON.txt, con, etc. all fail the same
-- way) -- checked case-insensitively against the WHOLE base name only,
-- so e.g. "CONquest" or "Falcon" are untouched.
local RESERVED_WINDOWS_NAMES = {
    ["con"] = true, ["prn"] = true, ["aux"] = true, ["nul"] = true,
    ["com1"] = true, ["com2"] = true, ["com3"] = true, ["com4"] = true,
    ["com5"] = true, ["com6"] = true, ["com7"] = true, ["com8"] = true, ["com9"] = true,
    ["lpt1"] = true, ["lpt2"] = true, ["lpt3"] = true, ["lpt4"] = true,
    ["lpt5"] = true, ["lpt6"] = true, ["lpt7"] = true, ["lpt8"] = true, ["lpt9"] = true,
}

-- Longest folder/file name sanitize() will return, in bytes of UTF-8. A
-- long window title (launcher subtitle, build string, server name...)
-- used to make CreateDirectoryW / MoveFileExW fail outright: the clip's
-- path is "<replay folder>\<name>\<name> <date> <time>.<ext>" and Windows
-- stops at 260 characters.
local MAX_FOLDER_NAME_BYTES = 50

local function sanitize(name)
    -- Normalize away the kinds of invisible/near-invisible differences
    -- that can sneak into a window title (leading spaces, a non-breaking
    -- space \194\160 instead of a normal one, tabs, or a trademark/
    -- copyright/registered mark some games only show sometimes) BEFORE
    -- anything else -- otherwise two saves of the exact same game whose
    -- titles differ only by one of these end up as two technically
    -- different strings, and each gets its own folder even though they
    -- look identical to the eye in Explorer.
    -- NOTE: these are three SEPARATE plain gsubs on purpose. This used to
    -- be a single character class, "[\194\160\9]", which is a byte-level
    -- match -- it hit byte 0xC2 or byte 0xA0 wherever they appeared,
    -- including in the middle of unrelated multi-byte UTF-8 characters.
    -- That silently corrupted text, and it fired on the very first line of
    -- this function, BEFORE the ™/®/© strippers below ever got a chance:
    -- "®" is 0xC2 0xAE, so its lead byte became a space and left a stray
    -- 0xAE behind, which no later rule removes. The result was an
    -- invalid-UTF-8 folder name -- and, since the mark isn't always present
    -- in a game's title, two folders for one game that look identical in
    -- Explorer. Arabic U+0620 (0xD8 0xA0) and "†" (0xE2 0x80 0xA0) were
    -- mangled the same way. Matching each sequence whole fixes all of it.
    name = name:gsub("\194\160", " ")       -- U+00A0 non-breaking space -> normal space
    name = name:gsub("\9", " ")             -- tab -> normal space
    name = name:gsub("\13", " "):gsub("\10", " ") -- stray CR/LF -> space
    -- Each of these is matched as one whole multi-byte UTF-8 sequence via
    -- its own plain gsub, NOT inside a [...] class -- a character class
    -- matches byte-by-byte, and these symbols' bytes could otherwise
    -- collide with bytes belonging to unrelated multi-byte characters
    -- elsewhere in the title (e.g. Arabic or other non-Latin text).
    name = name:gsub("™", ""):gsub("®", ""):gsub("©", "") -- drop trademark/copyright/registered marks
    -- Drop invisible Unicode marks that are completely silent in Explorer
    -- (render as nothing, take zero width) but are still real bytes to
    -- string comparison/CreateDirectoryW -- without this, two saves of
    -- the "same" name that differ only by one of these end up as two
    -- separate folders that look 100% identical to the eye. Seen in the
    -- wild here from Windows itself: on an Arabic (RTL) system, Windows
    -- can inject a bidi mark (LRM U+200E / RLM U+200F) into a window
    -- title that embeds English text inside RTL context; the exact same
    -- game can save one clip with the mark present and the next without
    -- it. Also covers zero-width space/joiner/non-joiner and a stray
    -- UTF-8 BOM, which some Steam name lookups can include.
    name = name:gsub("\226\128[\139\140\141\142\143]", "") -- U+200B..U+200F (ZWSP, ZWNJ, ZWJ, LRM, RLM)
    name = name:gsub("\226\129\160", "")                    -- U+2060 (word joiner)
    name = name:gsub("\239\187\191", "")                    -- U+FEFF (BOM / zero-width no-break space)
    name = name:gsub("%s+", " ")            -- collapse any run of spaces to one
    name = name:match("^%s*(.-)%s*$") or name -- trim leading AND trailing spaces

    local cleaned = name:gsub('[<>:"/\\|%?%*]', "_")
    -- Trailing dots/spaces are also invalid as the last character of a
    -- Windows path segment and get silently stripped by the OS anyway --
    -- strip them ourselves first so the reserved-name check below (and
    -- the final folder name) matches what Windows will actually see.
    cleaned = cleaned:match("^(.-)[%s%.]*$") or cleaned
    if #cleaned > MAX_FOLDER_NAME_BYTES then
        local cut = cleaned:sub(1, MAX_FOLDER_NAME_BYTES)
        -- Never leave half of a multi-byte UTF-8 character (Arabic, accents,
        -- ...) at the end: back off while the next byte is a continuation
        -- byte (10xxxxxx).
        while #cut > 0 do
            local nxt = cleaned:byte(#cut + 1)
            if nxt ~= nil and nxt >= 0x80 and nxt < 0xC0 then
                cut = cut:sub(1, -2)
            else
                break
            end
        end
        cleaned = cut:match("^(.-)[%s%.]*$") or cut
    end
    -- A title made up entirely of characters that get stripped or replaced
    -- above (or an empty one to begin with) used to come back as "", which
    -- turned the destination into "...\replays\" with a trailing separator
    -- and no folder name -- CreateDirectoryW/MoveFileExW then failed and
    -- the clip was left unsorted. Fall back to a real name instead.
    if cleaned == "" then
        cleaned = "Unsorted"
    end
    if RESERVED_WINDOWS_NAMES[cleaned:lower()] then
        -- CreateDirectoryW/MoveFileExW would fail outright on this name --
        -- append a harmless suffix instead of silently breaking sorting.
        cleaned = cleaned .. "_folder"
    end
    return cleaned
end

-- Reverse index: sanitized folder/friendly name (lowercase) -> raw exe
-- name (lowercase). This is what lets the "Add" fields below work off
-- the CURRENT folder name you already see in Explorer -- you never
-- have to know or go find an exe name yourself. Seeded from the
-- built-in/known games list and your own custom entries, and also
-- kept continuously up to date as clips actually get sorted (see
-- on_replay_saved further down), so even a game that was only ever
-- identified from its window title (not in any static list) becomes
-- renameable as soon as one clip from it has been saved.
local last_seen_exe_by_folder = {}

-- When two different raw exe names share the same friendly name (e.g.
-- "modernwarfare" and "cod" both mapping to "Call of Duty"), only ONE
-- raw exe can occupy that slot in last_seen_exe_by_folder. Lua's
-- pairs() has no guaranteed order, so which one "won" used to be
-- effectively random from one OBS session to the next. Sorting the
-- keys first makes the winner deterministic and reproducible (always
-- the alphabetically-last raw exe name for a given friendly name) --
-- it doesn't remove the ambiguity of two exes sharing one folder, but
-- it stops the "Add" fields from pointing at a different exe every
-- time OBS restarts. Once an actual clip from either exe is sorted at
-- runtime, on_replay_saved() below immediately overwrites this with
-- the exe that was really just played, which is always correct.
local function rebuild_folder_index()
    local raws = {}
    for raw in pairs(KNOWN_GAMES) do table.insert(raws, raw) end
    table.sort(raws)
    for _, raw in ipairs(raws) do
        last_seen_exe_by_folder[sanitize(KNOWN_GAMES[raw]):lower()] = raw
    end

    local custom_raws = {}
    for raw in pairs(name_map) do table.insert(custom_raws, raw) end
    table.sort(custom_raws)
    for _, raw in ipairs(custom_raws) do
        last_seen_exe_by_folder[sanitize(name_map[raw]):lower()] = raw
    end
end

-- Reads the two "add mapping" fields -- "1) Current folder name" is
-- looked up in last_seen_exe_by_folder to find which exe it actually
-- belongs to, then a "raw_exe=new_friendly" line is appended to the
-- name_map text (same storage/priority as before: custom entries here
-- always win over the built-in list and the window-title fallback).
local function add_mapping_clicked(props, property)
    if current_settings == nil then
        return false
    end

    local current_folder = obs.obs_data_get_string(current_settings, "new_raw"):match("^%s*(.-)%s*$")
    local friendly = obs.obs_data_get_string(current_settings, "new_friendly"):match("^%s*(.-)%s*$")

    if current_folder == "" or friendly == "" then
        print("OBS Replay Organizer: fill in both fields before adding.")
        return false
    end

    local raw = last_seen_exe_by_folder[sanitize(current_folder):lower()]
    if raw == nil then
        print("OBS Replay Organizer: no clip has been sorted into a folder named '" ..
              current_folder .. "' yet -- play that game and save one clip first, then try renaming it again.")
        return false
    end

    local existing = obs.obs_data_get_string(current_settings, "name_map")
    local new_line = raw .. "=" .. friendly
    local updated = (existing == nil or existing == "") and new_line or (existing .. "\n" .. new_line)

    obs.obs_data_set_string(current_settings, "name_map", updated)
    obs.obs_data_set_string(current_settings, "new_raw", "")
    obs.obs_data_set_string(current_settings, "new_friendly", "")

    name_map = parse_name_map(updated)
    rebuild_folder_index()
    print("OBS Replay Organizer: '" .. current_folder .. "' will now be sorted as '" .. friendly .. "'.")
    return true -- tells OBS to refresh the properties panel
end

    function Sorter.script_description()
        return [[
<h3>2) Replay Organizer</h3>
<p>Sorts saved clips into a folder per game, using the real foreground
window (like NVIDIA/Game Bar). ONLY games get their own folder; anything
else goes into a shared "Desktop" folder. Can optionally look up unknown
games on Steam.</p>
]]
    end

    function Sorter.script_properties(props)
        obs.obs_properties_add_text(
            props, "new_raw",
            "1) Current folder name",
            obs.OBS_TEXT_DEFAULT
        )
        obs.obs_properties_add_text(
            props, "new_friendly",
            "2) New name",
            obs.OBS_TEXT_DEFAULT
        )
        obs.obs_properties_add_button(
            props, "add_mapping_btn", "3) Add",
            add_mapping_clicked
        )
        -- Hidden on purpose: the Add button keeps this list up to date, and
        -- showing the raw text box in the Scripts window is just clutter. It is
        -- still saved with the script's settings; make it visible (change
        -- false to true below) if you want to edit the list by hand.
        local name_map_prop = obs.obs_properties_add_text(
            props, "name_map",
            "Custom names (filled in by the Add button above) -- one line per game: raw-exe-name=Friendly Name",
            obs.OBS_TEXT_MULTILINE
        )
        obs.obs_property_set_visible(name_map_prop, false)

        -- The built-in game list is merged in memory with your own
        -- known_games.txt (a hidden file in
        -- %APPDATA%\obs-studio\script-data\OBS-Clip-Suite, appended to by
        -- Steam lookups), but its path is intentionally NOT surfaced here --
        -- most users never need to touch it, and a raw file path in the
        -- Scripts window is just clutter. Power users can open it by hand;
        -- see known_games_file_path().

        -- Foreground look-back window (lookback_s, default 8s) is also
        -- kept out of the UI now -- it's an internal tuning knob, not
        -- something most users will ever need to touch. Still has a real
        -- default and is still read normally in script_update below.

        obs.obs_properties_add_bool(
            props, "steam_lookup_enabled",
            "Look up unknown games on Steam (online, last resort only)"
        )
    end

    function Sorter.script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "sorter_enabled", true)
    obs.obs_data_set_default_double(settings, "lookback_s", 8)
    obs.obs_data_set_default_bool(settings, "steam_lookup_enabled", true)
end

    function Sorter.script_load()
        -- Nothing here works without the Win32 layer (known_games.txt is
        -- created through CreateDirectoryW, the poll reads the foreground
        -- window). If init_win32() failed, stay completely inert rather
        -- than starting a timer that would throw on every single tick.
        if not sorter_available then
            return
        end
        KNOWN_GAMES = load_known_games()
        rebuild_folder_index()
        obs.timer_add(fg_poll_tick, FG_POLL_MS)
    end

    function Sorter.script_unload()
        obs.timer_remove(fg_poll_tick)
        for retry in pairs(pending_move_timers) do
            obs.timer_remove(retry)
        end
        pending_move_timers = {}
    end

    function Sorter.script_update(settings)
    current_settings = settings
    sorter_enabled = obs.obs_data_get_bool(settings, "sorter_enabled")
    name_map = parse_name_map(obs.obs_data_get_string(settings, "name_map"))
    rebuild_folder_index()
    -- Floored at 1s: a 0 look-back makes get_dominant_foreground() search a
    -- zero-length time window, so it always returns nil and the whole
    -- rolling-history feature silently degrades back to the instantaneous
    -- check it was written to replace.
    lookback_s = math.max(1, obs.obs_data_get_double(settings, "lookback_s"))
    steam_lookup_enabled = obs.obs_data_get_bool(settings, "steam_lookup_enabled")
end

------------------------------------------------------------------
-- Fetch the path of the last replay buffer save, straight from OBS
------------------------------------------------------------------
local function get_last_replay_path()
    local replay_buffer = obs.obs_frontend_get_replay_buffer_output()
    if replay_buffer == nil then
        return nil
    end

    local cd = obs.calldata_create()
    local ph = obs.obs_output_get_proc_handler(replay_buffer)
    obs.proc_handler_call(ph, "get_last_replay", cd)
    local path = obs.calldata_string(cd, "path")
    obs.calldata_destroy(cd)
    obs.obs_output_release(replay_buffer)

    if path == nil or path == "" then
        return nil
    end
    return path
end

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------

-- Finds the LAST occurrence of a plain (non-pattern) substring, since
-- Lua's string.find with plain=true only finds the first by default.
local function last_plain_find(haystack, needle)
    local last_s, last_e = nil, nil
    local start = 1
    while true do
        local s, e = haystack:find(needle, start, true)
        if not s then break end
        last_s, last_e = s, e
        start = e + 1
    end
    return last_s, last_e
end

-- Most Windows apps put the constant application name at the END of
-- their window title, after a separator, with the part that actually
-- changes (channel, tab, document, folder...) before it:
--   "New folder - File Explorer"       -> "File Explorer"
--   "general - ZNOG - Discord"         -> "Discord"
--   "Inbox - user@mail.com - Outlook"  -> "Outlook"
-- Games, on the other hand, are usually just the plain game name with
-- no such separator ("ELDEN RING"), so they pass through unchanged.
-- This one generic rule covers any app without needing to hardcode it.
local TITLE_SEPARATORS = { " - ", " | ", " — " }

local function extract_stable_app_name(title)
    -- Old Source-engine and some other games append the graphics API to the
    -- title ("Team Fortress 2 - Direct3D 9"). That suffix is not the app's
    -- name, so drop it first instead of letting it become the folder name.
    for _ = 1, 2 do
        local stripped = title:gsub("%s+[%-|]%s+[Dd]irect3[Dd]%s*[%d%.]*%s*$", "")
        stripped = stripped:gsub("%s+[%-|]%s+[Oo]pen[Gg][Ll]%s*[%d%.]*%s*$", "")
        stripped = stripped:gsub("%s+[%-|]%s+[Vv]ulkan%s*[%d%.]*%s*$", "")
        stripped = stripped:gsub("%s+[%-|]%s+[Dd]irect[Xx]%s*[%d%.]*%s*$", "")
        if stripped == title or stripped == "" then break end
        title = stripped
    end
    local best_pos, best_end = nil, nil
    for _, sep in ipairs(TITLE_SEPARATORS) do
        local s, e = last_plain_find(title, sep)
        if s and (best_pos == nil or s > best_pos) then
            best_pos, best_end = s, e
        end
    end
    if best_end then
        local suffix = title:sub(best_end + 1):match("^%s*(.-)%s*$")
        if suffix ~= "" then
            return suffix
        end
    end
    return title
end

------------------------------------------------------------------
-- Optional last-resort Steam Store lookup
--
-- Only ever reached when a game has neither a custom/known-games
-- mapping NOR a usable window title -- i.e. exactly the case that used
-- to just chop the exe name at its first "." or "-" and hope for the
-- best. Tries Steam's public storesearch endpoint (no API key needed)
-- to turn e.g. "eldenring" into "ELDEN RING", and once found, saves it
-- to known_games.txt so this exact lookup never has to happen again
-- (on this machine, in any future session).
------------------------------------------------------------------
local steam_lookup_cache = {}   -- lower exe name -> name found this session
local steam_lookup_failed = {}  -- lower exe name -> true (already tried & failed this session)

local function url_encode(str)
    return (str:gsub("[^%w%-%_%.~ ]", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+"))
end

-- Exe names that say nothing about WHICH program is running: Java
-- (every Minecraft / Java launcher is "javaw"), the UWP window host (every
-- Microsoft Store app or game is "ApplicationFrameHost"), and generic
-- interpreters. For these the exe can't identify the game, so the window
-- title is used instead -- every time, never remembered -- and no Steam
-- lookup is attempted (searching Steam for "javaw" is meaningless).
local GENERIC_HOST_EXES = {
    javaw = true, java = true,
    applicationframehost = true,
    python = true, pythonw = true, dotnet = true,
}

-- For generic hosts only: window titles whose real game name is not at the
-- end of the title. "Minecraft 1.20.1 - Singleplayer" would otherwise
-- become a folder called "Singleplayer".
local TITLE_KEYWORD_NAMES = {
    { "minecraft", "Minecraft" },
}

-- Words in an exe name that are not part of a game's name
-- ("VALORANT-Win64-Shipping" -> "VALORANT").
local STEAM_NOISE_WORDS = {
    win64 = true, win32 = true, x64 = true, x86 = true, shipping = true,
    client = true, game = true, dx9 = true, dx11 = true, dx12 = true,
    vulkan = true, steam = true, launcher = true, retail = true,
}

local function codepoint_to_utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
end

local JSON_SIMPLE_ESCAPES = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" }

-- Reads one JSON string whose opening quote is just before index i. Returns
-- the decoded UTF-8 string and the index after the closing quote, or nil if
-- the string is malformed/unterminated. Decodes \" \\ \/ and \uXXXX,
-- including surrogate pairs ("\u2019" -> a real apostrophe), in ONE pass so
-- an escaped backslash followed by "u2019" is not mistaken for an escape.
local function read_json_string(body, i)
    local out = {}
    local n = #body
    while i <= n do
        local c = body:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local e = body:sub(i + 1, i + 1)
            if e == "u" then
                local hex = body:match("^%x%x%x%x", i + 2)
                if not hex then
                    return nil
                end
                local cp = tonumber(hex, 16)
                i = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local low = body:match("^\\u(%x%x%x%x)", i)
                    local low_cp = low and tonumber(low, 16)
                    if low_cp and low_cp >= 0xDC00 and low_cp <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (low_cp - 0xDC00)
                        i = i + 6
                    else
                        cp = 0xFFFD
                    end
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    cp = 0xFFFD
                end
                out[#out + 1] = codepoint_to_utf8(cp)
            else
                out[#out + 1] = JSON_SIMPLE_ESCAPES[e] or e
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil
end

-- Deliberately NOT a general-purpose JSON parser -- just collects the
-- "name" fields (up to 10) out of Steam's storesearch response, in
-- order, which is all this needs.
local function json_extract_names(body)
    local names = {}
    if body:match('"total"%s*:%s*0[,%}]') then
        return names -- Steam itself says no matches
    end
    local pos = 1
    while #names < 10 do
        local _, e = body:find('"name"%s*:%s*"', pos)
        if not e then
            break
        end
        local name, next_pos = read_json_string(body, e + 1)
        if not name then
            break
        end
        if name ~= "" then
            names[#names + 1] = name
        end
        pos = next_pos
    end
    return names
end

local function normalize_for_match(text)
    return (text:lower():gsub("[^%w]", ""))
end

-- Picks the search result that actually corresponds to the exe name: its
-- letters/digits must equal, or contain / be contained in, the exe name
-- (after dropping words like "Win64"/"Shipping"). Returns nil if nothing
-- matches. The first result used to be taken blindly, which for an
-- unrelated exe name meant a random game's name became a folder name --
-- "no match" now means the plain exe name is used instead, which is safer.
local function pick_steam_name(names, query)
    local words = {}
    for w in query:lower():gmatch("[^%s]+") do
        if not STEAM_NOISE_WORDS[w] then
            words[#words + 1] = w
        end
    end
    local q = normalize_for_match(table.concat(words))
    if #q < 3 then
        return nil
    end
    local partial = nil
    for _, name in ipairs(names) do
        local n = normalize_for_match(name)
        if n == q then
            return name
        end
        if partial == nil and #n >= 3 and (n:find(q, 1, true) or q:find(n, 1, true)) then
            partial = name
        end
    end
    return partial
end

-- Blocking HTTPS GET over WinHTTP. Runs on whatever thread calls it
-- (OBS's frontend-event thread, in our case) -- kept short via the
-- STEAM_*_TIMEOUT_MS constants above specifically because of that.
-- Returns the response body as a string, or nil on any failure.
-- WinHttpQueryHeaders selectors for the status-code read below.
local WINHTTP_QUERY_STATUS_CODE   = 19
local WINHTTP_QUERY_CONTENT_LENGTH = 5
local WINHTTP_QUERY_FLAG_NUMBER   = 0x20000000

-- Reads a numeric response header (status code, Content-Length) or nil.
local function query_number_header(hRequest, selector)
    local value = ffi.new("DWORD[1]")
    local len = ffi.new("DWORD[1]", ffi.sizeof("DWORD"))
    local ok = winhttp.WinHttpQueryHeaders(hRequest,
        selector + WINHTTP_QUERY_FLAG_NUMBER, nil, value, len, nil)
    if ok == 0 then
        return nil
    end
    return tonumber(value[0])
end

-- `timeouts` is optional: { resolve, connect, send, receive, total, headers }.
-- `total` (ms) is a hard ceiling on the WHOLE request: the per-phase
-- WinHTTP timeouts apply to each individual read, so a slow-but-alive
-- connection could previously keep the (synchronous) call going far beyond
-- them. `headers` is an optional extra request header block (e.g. Range). The Steam
-- lookup wants the short defaults (it runs on OBS's frontend-event thread
-- during a save and must not stall the UI); the update checker downloads a
-- ~230 KB file on a background timer and needs a far more generous receive
-- timeout -- with the Steam values, a slow connection hit the timeout
-- mid-transfer and returned a TRUNCATED body as if it were complete.
local function https_get(host, path_and_query, timeouts)
    timeouts = timeouts or {}
    local hSession, hConnect, hRequest = nil, nil, nil

    -- Closes whatever got opened, in reverse order. It runs exactly once,
    -- after the request below has finished, on EVERY path: success, HTTP
    -- error status, truncated body, or a Lua error thrown halfway. The old
    -- version returned from inside the request code on a non-200 status or
    -- a Content-Length mismatch and so skipped its cleanup, leaking all
    -- three handles each time.
    local function close_all()
        if hRequest ~= nil then winhttp.WinHttpCloseHandle(hRequest) end
        if hConnect ~= nil then winhttp.WinHttpCloseHandle(hConnect) end
        if hSession ~= nil then winhttp.WinHttpCloseHandle(hSession) end
        hRequest, hConnect, hSession = nil, nil, nil
    end

    local ok, body = pcall(function()
        hSession = winhttp.WinHttpOpen(utf8_to_wide("OBS-ReplayOrganizer/1.0"),
            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0)
        if hSession == nil then return nil end

        winhttp.WinHttpSetTimeouts(hSession,
            timeouts.resolve or STEAM_RESOLVE_TIMEOUT_MS,
            timeouts.connect or STEAM_CONNECT_TIMEOUT_MS,
            timeouts.send    or STEAM_SEND_TIMEOUT_MS,
            timeouts.receive or STEAM_RECEIVE_TIMEOUT_MS)

        hConnect = winhttp.WinHttpConnect(hSession, utf8_to_wide(host), 443, 0)
        if hConnect == nil then return nil end

        hRequest = winhttp.WinHttpOpenRequest(hConnect, utf8_to_wide("GET"),
            utf8_to_wide(path_and_query), nil, nil, nil, WINHTTP_FLAG_SECURE)
        if hRequest == nil then return nil end

        local deadline_ns = timeouts.total and (obs.os_gettime_ns() + timeouts.total * 1e6) or nil

        local wide_headers = timeouts.headers and utf8_to_wide(timeouts.headers) or nil
        if winhttp.WinHttpSendRequest(hRequest, wide_headers,
            wide_headers and 0xFFFFFFFF or 0, nil, 0, 0, 0) == 0 then return nil end
        if winhttp.WinHttpReceiveResponse(hRequest, nil) == 0 then return nil end

        -- The status code was never looked at in the first version, so a
        -- 404 or 500 page came back looking exactly like a successful
        -- response. For the Steam lookup that just meant a garbage game
        -- name; for the updater it meant GitHub's HTML "Not Found" page
        -- could be treated as the script.
        local status = query_number_header(hRequest, WINHTTP_QUERY_STATUS_CODE)
        if status ~= nil and status ~= 200 and status ~= 206 then return nil end

        local expected = query_number_header(hRequest, WINHTTP_QUERY_CONTENT_LENGTH)

        local chunks = {}
        local total = 0
        while true do
            if deadline_ns and obs.os_gettime_ns() > deadline_ns then
                return nil -- took too long overall; give up (handles are closed by close_all)
            end
            local avail = ffi.new("DWORD[1]")
            if winhttp.WinHttpQueryDataAvailable(hRequest, avail) == 0 or avail[0] == 0 then
                break
            end
            local buf = ffi.new("char[?]", avail[0])
            local read = ffi.new("DWORD[1]")
            if winhttp.WinHttpReadData(hRequest, buf, avail[0], read) == 0 or read[0] == 0 then
                break
            end
            total = total + tonumber(read[0])
            chunks[#chunks + 1] = ffi.string(buf, read[0])
        end

        -- The read loop above exits on ANY interruption -- including a
        -- receive timeout partway through -- and used to hand back whatever
        -- had arrived so far as if it were the whole response. When the
        -- server told us how many bytes to expect, hold it to that.
        if expected ~= nil and expected > 0 and total ~= expected then return nil end

        return table.concat(chunks)
    end)
    close_all()
    if ok then return body end
    return nil
end

-- Exposed on the module table so the Updater module (defined after this
-- "do" block closes, further down the file) can reuse this exact same
-- WinHTTP plumbing instead of redeclaring the whole ffi.cdef a second
-- time (which would error on the duplicate typedefs/prototypes).
Sorter.https_get = https_get

-- Appends a new "raw=friendly" line to known_games.txt so a successful
-- Steam lookup is remembered permanently, not just for this session.
-- ONLY Steam results (and entries the user adds) are written there. Names
-- taken from a window title are NOT: a title is a snapshot ("Minecraft 1.20.1
-- - Singleplayer", a launcher or loading-screen caption) and saving it
-- forever kept the wrong name for good.
-- Tracks what has already been appended during THIS session, so the same
-- line isn't written again and again.
local persisted_this_session = {}

local function persist_known_game(raw_exe_name, friendly)
    -- Validate before touching the file. A blank raw or friendly name
    -- produces a line load_known_games() will refuse to parse on the next
    -- start -- junk that then accumulates in the file forever. An "=" or a
    -- newline inside the friendly name is worse: it splits one entry into
    -- two broken ones. Neither was checked before.
    if raw_exe_name == nil or friendly == nil then
        return
    end
    raw_exe_name = raw_exe_name:lower()
    friendly = friendly:gsub("[\r\n]", " "):gsub("=", "-")
    friendly = friendly:match("^%s*(.-)%s*$") or ""
    if raw_exe_name == "" or friendly == "" then
        return
    end

    -- friendly_name() calls this every time it resolves a name from a
    -- window title. Without a duplicate check, a long session could append
    -- the identical line dozens of times.
    local line = raw_exe_name .. "=" .. friendly
    if persisted_this_session[line] then
        return
    end

    local path = known_games_file_path()
    if not W.write_file(path, line .. "\n", true) then
        print("OBS Replay Organizer: found '" .. friendly .. "' but couldn't save it to " .. path .. ".")
        return
    end
    persisted_this_session[line] = true
end

local function steam_lookup_name(raw_exe_name)
    local lower = raw_exe_name:lower()
    if not steam_lookup_enabled or GENERIC_HOST_EXES[lower] then
        return nil
    end
    if steam_lookup_cache[lower] then
        return steam_lookup_cache[lower]
    end
    if steam_lookup_failed[lower] then
        -- Already tried and failed once this session (offline, Steam
        -- unreachable, no match, ...) -- don't hammer the network again
        -- on every single save until OBS restarts.
        return nil
    end

    -- Turn e.g. "VALORANT-Win64-Shipping" into a plausible search term
    -- "VALORANT Win64 Shipping" -- Steam's search handles the extra
    -- words fine, it just needs the real product word to be present.
    local query = raw_exe_name:gsub("[%-_]", " "):match("^%s*(.-)%s*$")
    if query == "" then
        steam_lookup_failed[lower] = true
        return nil
    end

    local path = "/api/storesearch/?term=" .. url_encode(query) .. "&cc=us&l=english"
    local body = https_get("store.steampowered.com", path)
    if not body then
        steam_lookup_failed[lower] = true
        print("OBS Replay Organizer: Steam lookup unreachable/timed out for '" .. raw_exe_name .. "' -- using the exe name instead.")
        return nil
    end

    local name = pick_steam_name(json_extract_names(body), query)
    if not name or name == "" then
        steam_lookup_failed[lower] = true
        return nil
    end

    steam_lookup_cache[lower] = name
    KNOWN_GAMES[lower] = name -- instant for the rest of THIS session too
    persist_known_game(raw_exe_name, name)
    print("OBS Replay Organizer: Steam lookup found '" .. name .. "' for '" .. raw_exe_name .. "' -- saved to known_games.txt.")
    return name
end

-- Names taken from a window title, remembered for THIS OBS session only
-- (lower exe name -> folder name): keeps a game in one folder even if its
-- title changes mid-session, without writing anything to disk.
local title_name_cache = {}

-- Priority order:
--   1) your own custom entries (from the "Add" fields / list above) --
--      matched against the raw exe name, so these always win
--   2) the built-in table of well-known oddly-named games plus your
--      known_games.txt and past Steam finds (also by exe name)
--   3) generic hosts (javaw, ApplicationFrameHost, ...): the exe says
--      nothing, so the window title is used fresh every time
--   4) the game's/app's real window title, run through
--      extract_stable_app_name() above -- the same signal NVIDIA/
--      Windows Game Bar use for games, generalized to also handle
--      apps whose title changes constantly (chat apps, browsers,
--      Explorer, etc.) without hardcoding each one by name. Remembered
--      for this session only, never saved to disk.
--   5) optional online fallback: a Steam Store search by exe name (see
--      steam_lookup_name above) -- only reached when there's no window
--      title to fall back to
--   6) last resort, automatic rule on the exe name: keep only the
--      first word, stopping at "." or "-"
--      "VALORANT-Win64-Shipping" -> "VALORANT"
--      "RiotClientServices"      -> "RiotClientServices" (nothing to stop at)
-- Apps that can be fullscreen without being a game. Only consulted when the
-- exe is NOT a game you named yourself (known_games.txt / the Add button).
local NON_GAME_EXES = {
    chrome = true, msedge = true, firefox = true, brave = true, opera = true,
    opera_gx = true, vivaldi = true, iexplore = true, arc = true,
    vlc = true, ["mpc-hc64"] = true, potplayermini64 = true,
    potplayer = true, mpv = true, wmplayer = true, netflix = true, spotify = true,
    explorer = true, discord = true, teams = true, zoom = true,
    obs64 = true, obs32 = true, obs = true, claude = true, code = true,
    notepad = true,
}

-- Install locations of the common game stores / launchers. In strict mode an
-- unknown app only counts as a game when it is fullscreen AND its exe lives in
-- one of these (or in a folder literally named "Games"). Discord, Claude,
-- browsers, editors... live in AppData / Program Files, so they never match.
local GAME_LIBRARY_MARKERS = {
    "\\steamapps\\common\\", "\\epic games\\", "\\gog galaxy\\games\\", "\\gog games\\",
    "\\riot games\\", "\\ubisoft\\ubisoft game launcher\\games\\", "\\ea games\\",
    "\\origin games\\", "\\xboxgames\\", "\\rockstar games\\",
    "\\games\\",
}

local function is_in_game_library(path)
    if not path or path == "" then return false end
    local p = path:lower():gsub("/", "\\")
    for _, marker in ipairs(GAME_LIBRARY_MARKERS) do
        if p:find(marker, 1, true) then
            return true
        end
    end
    return false
end

local function friendly_name(raw_exe_name, window_title, is_fullscreen)
    local lower = raw_exe_name:lower()

    local mapped = name_map[lower]
    if mapped then
        return mapped
    end

    local known = KNOWN_GAMES[lower]
    if known then
        return known
    end

    local has_title = window_title ~= nil and window_title ~= ""

    if GENERIC_HOST_EXES[lower] then
        if has_title then
            local lowered_title = window_title:lower()
            for _, rule in ipairs(TITLE_KEYWORD_NAMES) do
                if lowered_title:find(rule[1], 1, true) then
                    return rule[2]
                end
            end
            return sanitize(extract_stable_app_name(window_title))
        end
        return raw_exe_name
    end

    local cached = title_name_cache[lower]
    if cached then
        return cached
    end

    if has_title then
        -- Sanitize now (not just later in on_replay_saved) so the name we
        -- remember is the EXACT string that will become the folder name.
        local name = sanitize(extract_stable_app_name(window_title))
        -- Lock this exe -> name for the rest of this OBS session, so a
        -- title that isn't perfectly identical every time (loading screen,
        -- stray invisible character, ...) doesn't fan out into several
        -- folders. Session only -- see persist_known_game().
        -- Only remember it when the window is fullscreen (the real game window),
        -- so a launcher / splash title seen first can't lock the wrong name.
        if is_fullscreen then
            title_name_cache[lower] = name
        end
        return name
    end

    local steam_name = steam_lookup_name(raw_exe_name)
    if steam_name then
        return steam_name
    end

    return raw_exe_name:match("^([^%.%-]+)") or raw_exe_name
end

-- Creates dest_folder via a direct Win32 call (no cmd.exe / mkdir process).
-- Only handles a single-level create, same as the old "mkdir" call did;
-- OBS's own replay folder must already exist, we're just creating the
-- one game subfolder under it.
local function ensure_folder(win_folder)
    local wide_folder = utf8_to_wide(win_folder)
    local ok = kernel32.CreateDirectoryW(wide_folder, nil)
    if ok == 0 then
        local err = kernel32.GetLastError()
        if err ~= ERROR_ALREADY_EXISTS then
            print("OBS Replay Organizer: CreateDirectoryW failed for '" .. win_folder ..
                  "' (error " .. tostring(err) .. ").")
        end
    end
end

-- True if a file already exists at this Windows path.
local function file_exists(win_path)
    local wide = utf8_to_wide(win_path)
    local attrs = kernel32.GetFileAttributesW(wide)
    return tonumber(attrs) ~= INVALID_FILE_ATTRIBUTES
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
    return err == ERROR_SHARING_VIOLATION or err == ERROR_LOCK_VIOLATION
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
    -- MOVEFILE_COPY_ALLOWED mirrors the old fallback behavior for moves
    -- across drives. No MOVEFILE_REPLACE_EXISTING -- win_dest is guaranteed
    -- unique by unique_dest_path() above, so this never needs to (and
    -- never should) silently overwrite an existing clip.
    local wide_src = utf8_to_wide(win_src)
    local wide_dest = utf8_to_wide(win_dest)

    if kernel32.MoveFileExW(wide_src, wide_dest, MOVEFILE_COPY_ALLOWED) ~= 0 then
        return win_dest
    end
    local err = kernel32.GetLastError()

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
        if kernel32.MoveFileExW(wide_src, wide_dest, MOVEFILE_COPY_ALLOWED) ~= 0 then
            obs.timer_remove(retry)
            pending_move_timers[retry] = nil
            on_moved_later(win_dest)
            return
        end
        local retry_err = kernel32.GetLastError()
        if not is_lock_error(retry_err) or attempt >= MOVE_RETRY_ATTEMPTS then
            obs.timer_remove(retry)
            pending_move_timers[retry] = nil
            log_move_failure(win_src, win_dest, attempt, retry_err)
        end
    end
    pending_move_timers[retry] = true
    obs.timer_add(retry, MOVE_RETRY_DELAY_MS)
    return nil, true
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

    -- Use whichever app dominated the foreground over the last few
    -- seconds (see fg_history above), not just whatever happens to be
    -- focused at the exact instant this event fires -- that instant can
    -- already be a couple of seconds after the user pressed the save
    -- hotkey and alt-tabbed away (to Discord, etc.).
    local info = get_dominant_foreground(lookback_s)
    if info == nil then
        -- No history yet (e.g. right after the script loaded) -- fall
        -- back to the plain instantaneous check.
        info = get_foreground_info()
    end
    local game = "Desktop"
    local is_game = false
    if info == nil then
        print("OBS Replay Organizer: couldn't detect the foreground app — sorting into 'Desktop'.")
    elseif info.protected then
        -- Exe unreadable (anti-cheat/protected) but the window is fullscreen
        -- and titled: treat as a game, named from the title.
        is_game = true
        game = extract_stable_app_name(info.window_title)
    else
        local exe_lower = info.exe_name:lower()
        if NON_GAME_EXES[exe_lower] then
            -- Browsers, Explorer, Discord, OBS itself...: never a game, even
            -- if a stray entry for them exists in known_games.txt.
            is_game = false
        elseif name_map[exe_lower] or KNOWN_GAMES[exe_lower] then
            -- A game you (or the built-in list) named is a game even windowed.
            is_game = true
        elseif GENERIC_HOST_EXES[exe_lower] then
            -- javaw / ApplicationFrameHost: only a game if the title says so
            -- (e.g. Minecraft); the exe alone can't tell.
            local t = (info.window_title or ""):lower()
            for _, rule in ipairs(TITLE_KEYWORD_NAMES) do
                if t:find(rule[1], 1, true) then is_game = true end
            end
        else
            -- Unknown app: a game only if fullscreen AND installed in a game library.
            is_game = (info.is_fullscreen and is_in_game_library(info.exe_path)) and true or false
        end
        -- The name (and any Steam lookup) is resolved ONLY for games.
        if is_game then
            game = friendly_name(info.exe_name, info.window_title, info.is_fullscreen)
        end
    end
    game = sanitize(game)
    print("OBS Replay Organizer: detected exe='" .. (info and info.exe_name or "?") ..
          "' fullscreen=" .. tostring(info and info.is_fullscreen) ..
          " game=" .. tostring(is_game))

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

    local SW_SHOWNORMAL = 1
    local WM_CLOSE = 0x0010
    local GW_OWNER = 4

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
            if user32.IsWindowVisible(hwnd) ~= 0 and user32.GetWindow(hwnd, GW_OWNER) == nil then
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
            local result = shell32.ShellExecuteW(nil, nil, wbuf, utf8_to_wide("--multi"), nil, SW_SHOWNORMAL)
            if tonumber(ffi.cast("intptr_t", result)) <= 32 then
                error("ShellExecuteW couldn't start a new OBS instance")
            end

            user32.PostMessageW(main_hwnd, WM_CLOSE, 0, 0)
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
    -- Called by the NEW OBS, after the old one has exited -- so the reload
    -- OBS does after the swap is an ordinary clean one.
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
            -- it just reloads the script in this OBS, like the reload button.
            local applied, apply_err = Updater.apply_staged_update()
            if applied then
                last_check_result = "Update installed, but couldn't restart OBS automatically (" ..
                    tostring(relaunch_err) .. ") -- the script was reloaded in this OBS; restart OBS when convenient."
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
                        obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
                    end
                elseif tries >= 30 then
                    obs.timer_remove(waiter)
                    install_waiter = nil
                    last_check_result = "The Replay Buffer wouldn't stop in time, so the update was NOT installed. " ..
                        "It will be offered again next time."
                    obs.script_log(obs.LOG_WARNING, "OBS Clip Suite: " .. last_check_result)
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
        if not force and Sorter.foreground_is_fullscreen() then
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

        local answer = Sorter.ask_yes_no_cancel(message, "OBS Clip Suite - update available")

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

    -- Retries a prompt that was held back because a game was fullscreen.
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
            last_check_result = "An update is available but you stayed in a fullscreen app -- " ..
                "it'll be offered again next time."
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

    -- manual = true when triggered from the "Check for Updates Now"
    -- button (always logs a result, even "up to date"); false when
    -- triggered automatically on script_load (stays quiet unless a
    -- newer version is actually found, so a normal OBS launch with no
    -- update doesn't spam the log every time).
    function Updater.check_for_updates(manual)
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
            -- cutting off a live stream/recording/Replay Buffer or
            -- yanking a fullscreen game to the desktop. relaunch_obs()
            -- posts WM_CLOSE, and if outputs are active OBS's own
            -- shutdown path pops its "Active Outputs" confirmation --
            -- a modal dialog nobody is there to answer during an
            -- unattended auto-install. So: hold off and retry later
            -- instead, the same way "ask" mode already holds off a
            -- fullscreen prompt.
            auto_install_attempts = 0
            if outputs_are_active() or Sorter.foreground_is_fullscreen() then
                last_check_result = "An update is staged but is being held back because a " ..
                    "stream/recording/Replay Buffer is active (or a game is fullscreen) -- " ..
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
                "soon as you're out of fullscreen."
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
        local answer = Sorter.ask_yes_no_cancel(
            "Restore OBS Clip Suite version " .. backup_version .. " (you are on " .. VERSION .. ")?\n\n" ..
            "Yes  -  Restore it and restart OBS now (the Replay Buffer is stopped and resumed)\n" ..
            "No / Cancel  -  Do nothing",
            "OBS Clip Suite - restore previous version")
        if answer ~= Sorter.MB_IDYES then
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

    function Updater.script_load()
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
        if install_waiter ~= nil then
            obs.timer_remove(install_waiter)
            install_waiter = nil
        end
        pending_update = nil
        updater_settings = nil
    end
end

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

function script_defaults(settings) each_module("script_defaults", settings) end
function script_update(settings) each_module("script_update", settings) end

-- True in the OLD OBS after a self-update reloaded the script: stay passive.
local dormant_old_instance = false

local function on_frontend_event(event)
    if dormant_old_instance then return end
    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        -- Order matters: move the clip, play the sound, then restart the buffer.
        guard("Sorter.on_replay_saved", Sorter.on_replay_saved)
        guard("Alert.on_replay_saved", Alert.on_replay_saved)
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
        return ffi.errno() == 5
    end
    local r = kernel32.WaitForSingleObject(h, 0)
    kernel32.CloseHandle(h)
    return r == 0x102 -- WAIT_TIMEOUT: still running
end

-- New instance launched by a self-update: WAIT until the old OBS has really
-- exited, then (1) swap in the staged script, if any -- OBS reloads it and the
-- reloaded copy lands back here -- and (2) start the Replay Buffer and confirm it.
local function resume_replay_buffer_after_relaunch(marker)
    local MAX_WAIT_S = 180   -- the old OBS may be sitting on a "quit?" prompt
    local MAX_RETRIES = 8
    local state = "waiting"  -- "waiting" -> "applied" -> "starting"
    local waited_s, applied_s, retries, warned = 0, 0, 0, false
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
                    obs.script_log(obs.LOG_INFO, "OBS Clip Suite: update applied -- reloading the script.")
                    state = "applied" -- OBS reloads the script; this copy normally never runs again
                    return
                end
                obs.script_log(obs.LOG_WARNING,
                    "OBS Clip Suite: couldn't apply the staged update (" .. tostring(err) .. ").")
            end
            return begin_resume()
        elseif state == "applied" then
            -- OBS didn't reload us: carry on with what is in memory rather than leave the buffer off.
            applied_s = applied_s + 1
            if applied_s >= 5 then
                obs.script_log(obs.LOG_WARNING,
                    "OBS Clip Suite: OBS didn't reload the script by itself -- restart OBS to use the new version.")
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
