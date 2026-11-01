-- Runs against the real parts in src\. Usage:  luajit tests/run_tests.lua [project-root]
-- (any Lua 5.1-5.4 works). No OBS, no Windows: the OBS API and WinHTTP are faked.
local root = arg and arg[1] or "."
local here = (arg and arg[0] or "tests/run_tests.lua"):match("^(.*)[\\/][^\\/]+$") or "."
package.path = here .. "/?.lua;" .. package.path
local Mock = require("mock_obs")

local function read(path)
    local f = assert(io.open(root .. "/" .. path, "rb"))
    local t = f:read("*a"); f:close()
    return (t:gsub("\r\n", "\n"))
end

-- Compiles `text` with `env` as its globals (works on 5.1/LuaJIT and 5.2+).
local function compile(text, name, env)
    env = setmetatable(env or {}, { __index = _G })
    if setfenv then
        local fn = assert(loadstring(text, name))
        return setfenv(fn, env)
    end
    return assert(load(text, name, "t", env))
end

local results, failed = {}, 0
local function check(name, cond, detail)
    results[#results + 1] = (cond and "  PASS  " or "  FAIL  ") .. name .. (detail and ("   [" .. detail .. "]") or "")
    if not cond then failed = failed + 1 end
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then check(name .. " (error)", false, tostring(err)) end
end

------------------------------------------------------------------
-- Restarter
------------------------------------------------------------------
local function new_restarter()
    local obs = Mock.new()
    local R = compile(read("src/10_restarter.lua") .. "\nreturn Restarter", "10_restarter", { obs = obs })()
    local function deliver(ev)
        if ev == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then R.on_replay_saved() end
        R.on_event(ev)
    end
    R.script_update({}) -- enabled = true (mock returns true)
    return obs, R, deliver
end

test("restarter: a single save restarts quickly", function()
    local obs, R, deliver = new_restarter()
    deliver(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING)
    obs.emit_in(500, obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
    obs.advance(10000, deliver)
    local stop = obs.calls.stop[1]
    check("single save: stop issued", stop ~= nil)
    check("single save: stop within ~3 s of SAVING", stop ~= nil and stop <= 3000, "stop at " .. tostring(stop) .. " ms")
    check("single save: buffer running again", obs.state.active)
end)

test("restarter: SAVING without SAVED must not delay the next restart (fix #4)", function()
    local obs, R, deliver = new_restarter()
    deliver(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING)      -- t=0: this save fails, no SAVED ever comes
    obs.advance(30000, deliver)                               -- longer than the 25 s stale limit
    check("failed save alone causes no stop", #obs.calls.stop == 0)
    local t_saving = obs.now_ms()
    deliver(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING)      -- t=30 s: a good save
    obs.emit_in(500, obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
    obs.advance(40000, deliver)
    local stop = obs.calls.stop[1]
    local delay = stop and (stop - t_saving) or math.huge
    check("restart after the good save comes within ~3 s", delay <= 3000, "stop " .. tostring(delay) .. " ms after SAVING")
end)

test("restarter: held-key duplicate SAVING (no SAVED) is still ignored", function()
    local obs, R, deliver = new_restarter()
    deliver(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING)
    obs.advance(300, deliver)
    deliver(obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVING)      -- OBS ignores this press, announces it anyway
    obs.emit_in(700, obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
    obs.advance(10000, deliver)
    local stop = obs.calls.stop[1]
    check("duplicate SAVING: restart still within ~4 s", stop ~= nil and stop <= 4000, "stop at " .. tostring(stop))
end)

------------------------------------------------------------------
-- Dominant foreground app
------------------------------------------------------------------
test("foreground: grouped by exe, not exe+title (fix #7)", function()
    local src = read("src/31_organizer_tracking.lua")
    local s = src:find("local function get_dominant_foreground", 1, true)
    local e = select(2, src:find("\nend\n", s, true))
    local obs = Mock.new()
    local env = { obs = obs, fg_history = {} }
    local fn = compile(src:sub(s, e) .. "\nreturn get_dominant_foreground", "fg", env)()
    obs.advance(10000, function() end)
    local now = obs.os_gettime_ns()
    local t0 = now - 8e9
    -- Game: 6 s, window title changes every 0.5 s (FPS counter in the title).
    for i = 0, 11 do
        env.fg_history[#env.fg_history + 1] = { start_ns = t0 + i * 0.5e9, end_ns = t0 + (i + 1) * 0.5e9,
            exe_name = "Game", window_title = "Game - " .. (60 + i) .. " FPS", is_fullscreen = true }
    end
    -- Discord: 2 s with one steady title.
    env.fg_history[#env.fg_history + 1] = { start_ns = t0 + 6e9, end_ns = t0 + 8e9,
        exe_name = "Discord", window_title = "Discord", is_fullscreen = false }
    local best = fn(8)
    check("6 s of the game beats 2 s of Discord", best ~= nil and best.exe_name == "Game", best and best.exe_name)
    check("the latest sample of the winner is returned", best ~= nil and best.window_title == "Game - 71 FPS", best and best.window_title)
end)

------------------------------------------------------------------
-- Steam lookup / WinHTTP (Steam part loaded with a fake FFI + fake WinHTTP)
------------------------------------------------------------------
local function new_steam(opts)
    opts = opts or {}
    local obs = Mock.new()
    local net = { requests = 0, open_types = {}, bodies = opts.bodies or {}, fail = opts.fail, old_windows = opts.old_windows }
    local remaining, cur_host, cur_path = "", nil, nil
    local fake_ffi = {
        new = function(t, init) if t:find("%[%?%]") then return { data = "" } end return { [0] = init or 0 } end,
        sizeof = function() return 4 end,
        string = function(buf, n) return buf.data:sub(1, n) end,
        errno = function() return 0 end,
    }
    local winhttp = {
        WinHttpOpen = function(_, access)
            net.open_types[#net.open_types + 1] = access
            if access == 4 and net.old_windows then return nil end
            return {}
        end,
        WinHttpSetTimeouts = function() return 1 end,
        WinHttpConnect = function(_, host) cur_host = host return {} end,
        WinHttpOpenRequest = function(_, _, path) cur_path = path return {} end,
        WinHttpSendRequest = function() net.requests = net.requests + 1 return 1 end,
        WinHttpReceiveResponse = function()
            if net.fail then return 0 end
            local term = cur_path:match("term=([^&]+)") or ""
            remaining = net.bodies[term] or '{"total":0,"items":[]}'
            return 1
        end,
        WinHttpQueryHeaders = function(_, selector, _, value)
            if selector == 19 + 0x20000000 then value[0] = 200 return 1 end
            return 0
        end,
        WinHttpQueryDataAvailable = function(_, avail) avail[0] = #remaining return 1 end,
        WinHttpReadData = function(_, buf, _, read) buf.data = remaining read[0] = #remaining remaining = "" return 1 end,
        WinHttpCloseHandle = function() return 1 end,
    }
    local written, printed = {}, {}
    local C = { STEAM_RESOLVE_TIMEOUT_MS = 1, STEAM_CONNECT_TIMEOUT_MS = 1, STEAM_SEND_TIMEOUT_MS = 1,
        STEAM_RECEIVE_TIMEOUT_MS = 1, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4,
        WINHTTP_FLAG_SECURE = 0x00800000 }
    local Sorter = {}
    local env = {
        obs = obs, C = C, ffi = fake_ffi, winhttp = winhttp, Sorter = Sorter,
        utf8_to_wide = function(s) return s end,
        steam_lookup_enabled = true, name_map = {}, KNOWN_GAMES = {},
        known_games_file_path = function() return "known_games.txt" end,
        W = { write_file = function(_, line) written[#written + 1] = line return true end },
        sanitize = function(s) return s end,
        extract_stable_app_name = function(t) return t end,
        print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end,
    }
    local api = compile(read("src/32_organizer_steam_names.lua") ..
        "\nreturn { friendly_name = friendly_name, pick = pick_steam_name }", "32_steam", env)()
    local function tick(ms) obs.advance(ms, function() end) end
    return { obs = obs, net = net, env = env, api = api, Sorter = Sorter, written = written, printed = printed, tick = tick }
end

local ELDEN = '{"total":1,"items":[{"id":1,"name":"ELDEN RING"}]}'
local DECODE = '{"total":1,"items":[{"id":2,"name":"Decode"}]}'
local GAMEPATH = "C:\\Tools\\x.exe"

test("steam: pick_steam_name reports exact vs partial (fix #8)", function()
    local t = new_steam()
    local n1, e1 = t.api.pick({ "ELDEN RING" }, "eldenring")
    local n2, e2 = t.api.pick({ "Decode" }, "cod")
    check("exact match is flagged exact", n1 == "ELDEN RING" and e1 == true)
    check("partial match is flagged partial", n2 == "Decode" and e2 == false)
end)

test("steam: no network during the save; lookup runs later on a timer (fix #5)", function()
    local t = new_steam({ bodies = { eldenring = ELDEN } })
    local name = t.api.friendly_name("eldenring", "", true, GAMEPATH)
    check("save-time name is the plain exe name", name == "eldenring", name)
    check("no HTTP request was made while sorting", t.net.requests == 0, "requests=" .. t.net.requests)
    t.tick(5000)
    check("the background timer did the request", t.net.requests == 1, "requests=" .. t.net.requests)
    check("exact match is saved to known_games.txt", #t.written == 1 and t.written[1] == "eldenring=ELDEN RING\n", t.written[1])
    check("next clip uses the Steam name", t.api.friendly_name("eldenring", "", true, GAMEPATH) == "ELDEN RING")
end)

test("steam: a partial match is used for the session but never saved (fix #8)", function()
    local t = new_steam({ bodies = { cod = DECODE } })
    t.api.friendly_name("cod", "", true, GAMEPATH)
    t.tick(5000)
    check("nothing written to known_games.txt", #t.written == 0, t.written[1])
    check("KNOWN_GAMES not polluted", t.env.KNOWN_GAMES.cod == nil)
end)

test("steam: circuit breaker stops hammering a dead network (fix #5)", function()
    local t = new_steam({ fail = true })
    for _, exe in ipairs({ "aaa1", "bbb2", "ccc3", "ddd4" }) do t.api.friendly_name(exe, "", true, GAMEPATH) end
    t.tick(20000)
    check("only 2 requests before the breaker opened", t.net.requests == 2, "requests=" .. t.net.requests)
    t.net.fail = false
    t.net.bodies["ccc3"] = '{"total":1,"items":[{"id":3,"name":"CCC3"}]}'
    t.api.friendly_name("ccc3", "", true, GAMEPATH)
    t.tick(20000)
    check("still blocked inside the back-off window", t.net.requests == 2, "requests=" .. t.net.requests)
    t.tick(130000)   -- back-off (2 min) is over
    t.api.friendly_name("ccc3", "", true, GAMEPATH)
    t.tick(20000)
    check("works again after the back-off", t.net.requests == 3, "requests=" .. t.net.requests)
end)

test("steam: automatic proxy first, default proxy as fallback (fix #5)", function()
    local t = new_steam({ old_windows = true, bodies = { eldenring = ELDEN } })
    t.api.friendly_name("eldenring", "", true, GAMEPATH)
    t.tick(5000)
    check("tried 4 (automatic) then 0 (default)", t.net.open_types[1] == 4 and t.net.open_types[2] == 0,
        table.concat(t.net.open_types, ","))
    check("lookup still succeeded", t.net.requests == 1)
end)

test("steam: lookups wait while streaming/recording", function()
    local t = new_steam({ bodies = { eldenring = ELDEN } })
    t.obs.state.recording = true
    t.api.friendly_name("eldenring", "", true, GAMEPATH)
    t.tick(10000)
    check("no request while recording", t.net.requests == 0)
    t.obs.state.recording = false
    t.tick(35000)
    check("request after recording stops", t.net.requests == 1, "requests=" .. t.net.requests)
end)

test("steam: foreground hook queues only real untitled fullscreen games", function()
    local t = new_steam({ bodies = { newgame = ELDEN } })
    local N = t.Sorter.note_foreground
    N({ exe_name = "Discord", exe_path = "C:\\Games\\d.exe", window_title = "", is_fullscreen = true })
    N({ exe_name = "titled", exe_path = "D:\\Games\\t.exe", window_title = "Has Title", is_fullscreen = true })
    N({ exe_name = "windowed", exe_path = "D:\\Games\\w.exe", window_title = "", is_fullscreen = false })
    N({ exe_name = "elsewhere", exe_path = "C:\\Tools\\e.exe", window_title = "", is_fullscreen = true })
    t.tick(10000)
    check("none of the non-candidates caused a request", t.net.requests == 0, "requests=" .. t.net.requests)
    N({ exe_name = "newgame", exe_path = "D:\\Games\\newgame\\newgame.exe", window_title = "", is_fullscreen = true })
    t.tick(5000)
    check("a new fullscreen game from a library is looked up early", t.net.requests == 1, "requests=" .. t.net.requests)
end)

------------------------------------------------------------------
print("")
for _, line in ipairs(results) do print(line) end
print(string.format("\n%d check(s), %d failed", #results, failed))
os.exit(failed == 0 and 0 or 1)
