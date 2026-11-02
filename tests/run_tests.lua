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
    if opts.official then
        env.ffi = nil  -- no real Win32 in the tests: directory / file / exe-info access is faked per test
        env.W = { write_file = env.W.write_file, getenv = function() return "C:\\ProgramData" end }
    end
    local api = compile(read("src/32_organizer_steam_names.lua") ..
        (opts.official and read("src/32b_organizer_official_names.lua") or "") ..
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
-- Game memory: played -> desktop for a minute -> saved
------------------------------------------------------------------
local function load_recent_game()
    local src = read("src/31_organizer_tracking.lua")
    local s = src:find("local function get_recent_game", 1, true)
    local e = select(2, src:find("\nend\n", s, true))
    local obs = Mock.new()
    local env = { obs = obs, fg_history = {} }
    local fn = compile(src:sub(s, e) .. "\nreturn get_recent_game", "recent", env)()
    obs.advance(3600000, function() end)
    return fn, env, obs
end

test("memory: game 40 s, then 50 s on the desktop -> the game is found", function()
    local fn, env, obs = load_recent_game()
    local now = obs.os_gettime_ns()
    env.fg_history[1] = { start_ns = now - 90e9, end_ns = now - 50e9, exe_name = "Game", window_title = "Game", is_fullscreen = true }
    env.fg_history[2] = { start_ns = now - 50e9, end_ns = now, exe_name = "explorer", window_title = "Desktop", is_fullscreen = false }
    local g = fn(60, function(e) return e.exe_name == "Game" end, 2)
    check("game found after 50 s on the desktop", g ~= nil and g.exe_name == "Game", g and g.exe_name)
end)

test("memory: a game from long ago, outside the window, is NOT used", function()
    local fn, env, obs = load_recent_game()
    local now = obs.os_gettime_ns()
    env.fg_history[1] = { start_ns = now - 200e9, end_ns = now - 100e9, exe_name = "Game", window_title = "Game", is_fullscreen = true }
    env.fg_history[2] = { start_ns = now - 100e9, end_ns = now, exe_name = "explorer", window_title = "x", is_fullscreen = false }
    check("game left more than a minute ago is ignored", fn(60, function(e) return e.exe_name == "Game" end, 2) == nil)
end)

test("memory: the LAST game wins, even if the earlier one was played longer", function()
    local fn, env, obs = load_recent_game()
    local now = obs.os_gettime_ns()
    local is_game = function(e) return e.exe_name == "Flash" or e.exe_name == "A" or e.exe_name == "B" end
    env.fg_history[1] = { start_ns = now - 58e9, end_ns = now - 20e9, exe_name = "A", window_title = "a", is_fullscreen = true }
    env.fg_history[2] = { start_ns = now - 20e9, end_ns = now - 5e9, exe_name = "B", window_title = "b", is_fullscreen = true }
    env.fg_history[3] = { start_ns = now - 5e9, end_ns = now, exe_name = "explorer", window_title = "x", is_fullscreen = false }
    local g = fn(60, is_game, 2)
    check("B (15 s, last) beats A (38 s, earlier)", g ~= nil and g.exe_name == "B", g and g.exe_name)
    env.fg_history[3] = { start_ns = now - 5e9, end_ns = now - 4e9, exe_name = "Flash", window_title = "f", is_fullscreen = true }
    env.fg_history[4] = { start_ns = now - 4e9, end_ns = now, exe_name = "explorer", window_title = "x", is_fullscreen = false }
    g = fn(60, is_game, 2)
    check("a 1 s flash of another game afterwards is ignored", g ~= nil and g.exe_name == "B", g and g.exe_name)
    env.fg_history[3] = { start_ns = now - 5e9, end_ns = now - 1e9, exe_name = "A", window_title = "a", is_fullscreen = true }
    g = fn(60, is_game, 2)
    check("going back to A makes A the last game", g ~= nil and g.exe_name == "A", g and g.exe_name)
end)

------------------------------------------------------------------
-- Is it a game? (classify_game)
------------------------------------------------------------------
local function load_classify()
    local base = new_steam()
    local g33 = read("src/33_organizer_files.lua")
    local s = g33:find("local function classify_game", 1, true)
    local e = select(2, g33:find("\nend\n", s, true))
    local env = base.env
    env.GENERIC_HOST_EXES = nil
    local fn = compile(read("src/32_organizer_steam_names.lua") .. "\n" .. g33:sub(s, e) ..
        "\nreturn classify_game", "classify", env)()
    return fn, env
end

test("classify: what is and is not a game", function()
    local classify, env = load_classify()
    local function c(exe, path, fs, title) return classify({ exe_name = exe, exe_path = path, is_fullscreen = fs, window_title = title or "" }) end
    check("Steam game, windowed", c("SomeGame", "D:\\SteamLibrary\\steamapps\\common\\Some\\SomeGame.exe", false) == true)
    check("game on a custom drive, fullscreen", c("MyGame", "E:\\Stuff\\MyGame\\MyGame.exe", true) == true)
    check("same game windowed, not in any library -> not guessed", c("MyGame", "E:\\Stuff\\MyGame\\MyGame.exe", false) == false)
    check("browser fullscreen is not a game", c("chrome", "C:\\Program Files\\Google\\Chrome\\chrome.exe", true) == false)
    check("Discord (AppData) fullscreen is not a game", c("SomeElectron", "C:\\Users\\u\\AppData\\Local\\Foo\\foo.exe", true) == false)
    check("PowerPoint fullscreen is not a game", c("POWERPNT", "C:\\Program Files\\Microsoft Office\\root\\Office16\\POWERPNT.EXE", true) == false)
    check("Steam client itself is not a game", c("steam", "C:\\Program Files (x86)\\Steam\\steam.exe", false) == false)
    check("Epic launcher is not a game", c("EpicGamesLauncher", "C:\\Program Files\\Epic Games\\Launcher\\x.exe", true) == false)
    check("known game by exe name, windowed", (function() env.KNOWN_GAMES["eldenring"] = "Elden Ring"; return c("eldenring", nil, false) end)() == true)
    check("javaw without minecraft in the title is not a game", c("javaw", nil, true, "Some Java App") == false)
    check("javaw with Minecraft in the title is a game", c("javaw", nil, false, "Minecraft 1.20") == true)
    check("Minecraft modpack title (no 'Minecraft' word) under javaw is a game",
        c("javaw", nil, false, "All the Mods 9 1.20.1 - Multiplayer (3rd-party Server)") == true)
    check("same title under another exe name is a game too",
        c("SomeJavaRuntime", "C:\\x\\y.exe", false, "Pack - Singleplayer") == true)
    check("a browser tab titled like that is still not a game", c("chrome", nil, false, "Foo - Singleplayer") == false)
    check("an ordinary title ending in 'singleplayer' text mid-sentence is not matched",
        c("javaw", nil, false, "Singleplayer mode guide") == false)
    check("protected fullscreen window is a game", classify({ exe_name = "?protected", protected = true, window_title = "X" }) == true)
    check("your own Add entry wins over the non-game list", (function() env.name_map["chrome"] = "Cloud Game"; return c("chrome", nil, false) end)() == true)
end)

test("friendly_name: Minecraft under any launcher title", function()
    local steam = new_steam()
    local fn = steam.api.friendly_name
    check("modpack title under javaw -> Minecraft", fn("javaw", "ATM9 1.20.1 - Multiplayer (3rd-party Server)", false, nil) == "Minecraft")
    check("LAN title -> Minecraft", fn("javaw", "Multiplayer (LAN)", false, nil) == "Minecraft")
    check("plain Minecraft title still -> Minecraft", fn("javaw", "Minecraft* 1.20.1 - Singleplayer", false, nil) == "Minecraft")
end)


------------------------------------------------------------------
-- Official names (32b): launcher records, exe info, OBS Game Capture
------------------------------------------------------------------
local ACF = '"AppState"\n{\n\t"appid"\t\t"1145350"\n\t"name"\t\t"Hades II"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"Hades II"\n}\n'
local function epic_item(name, loc, app, main)
    return '{"FormatVersion":0,"DisplayName":"' .. name .. '","InstallLocation":"' .. loc:gsub("\\", "\\\\") ..
        '","AppName":"' .. app .. '","MainGameAppName":"' .. (main or app) .. '"}'
end

local function new_official()
    local t = new_steam({ official = true })
    local on = t.env.C.on
    t.files, t.dirs, t.exe_info = {}, {}, {}
    on.list_dir = function(dir, mask) t.listed = (t.listed or 0) + 1 return t.dirs[dir:lower() .. "|" .. mask] or {} end
    on.read_text = function(path) return t.files[path:lower()] end
    on.exe_strings = function(path) local i = t.exe_info[path:lower()] if i then return i[1], i[2] end return nil end
    t.on = on
    return t
end

test("official: Steam appmanifest gives the exact name, from any library drive", function()
    local t = new_official()
    local lib = "D:\\SteamLibrary\\steamapps"
    t.dirs[lib:lower() .. "|appmanifest_*.acf"] = { "appmanifest_1145350.acf" }
    t.files[(lib .. "\\appmanifest_1145350.acf"):lower()] = ACF
    local fn = t.api.friendly_name
    check("Hades2.exe -> Hades II", fn("Hades2", "Hades II - 144 FPS", true, lib .. "\\common\\Hades II\\Ship\\Hades2.exe") == "Hades II")
    check("name does not follow the window title", fn("Hades2", "something else", true, lib .. "\\common\\Hades II\\Ship\\Hades2.exe") == "Hades II")
    local before = t.listed
    fn("Hades2", "x", true, lib .. "\\common\\Hades II\\Ship\\Hades2.exe")
    check("second call is served from the cache (no directory scan)", t.listed == before)
end)

test("official: your own names and known_games still win", function()
    local t = new_official()
    local lib = "D:\\SteamLibrary\\steamapps"
    t.dirs[lib:lower() .. "|appmanifest_*.acf"] = { "a.acf" }
    t.files[(lib .. "\\a.acf"):lower()] = ACF
    local path = lib .. "\\common\\Hades II\\Hades2.exe"
    t.env.name_map["hades2"] = "My Hades"
    check("name_map wins", t.api.friendly_name("Hades2", "", true, path) == "My Hades")
    t.env.name_map["hades2"] = nil
    t.env.KNOWN_GAMES["hades2"] = "Known Hades"
    check("known games wins", t.api.friendly_name("Hades2", "", true, path) == "Known Hades")
end)

test("official: a game installed after the first scan is found on the next try", function()
    local t = new_official()
    local lib = "D:\\SteamLibrary\\steamapps"
    local path = lib .. "\\common\\Hades II\\Hades2.exe"
    check("not installed yet -> falls back to the title", t.api.friendly_name("Hades2", "Hades Window", true, path) == "Hades Window")
    t.dirs[lib:lower() .. "|appmanifest_*.acf"] = { "a.acf" }
    t.files[(lib .. "\\a.acf"):lower()] = ACF
    t.obs.advance(125000, function() end)  -- past the 2-minute 'not found' memory and the 1-minute rescan limit
    check("after the waiting time the manifest is read", t.api.friendly_name("Hades2", "Hades Window", true, path) == "Hades II")
end)

test("official: Epic manifests (DLC and nested exe handled)", function()
    local t = new_official()
    local dir = "C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data\\Manifests"
    t.dirs[dir:lower() .. "|*.item"] = { "1.item", "2.item" }
    t.files[(dir .. "\\1.item"):lower()] = epic_item("Fortnite\\u2122", "C:\\Games\\Fortnite", "Fortnite")
    t.files[(dir .. "\\2.item"):lower()] = epic_item("Fortnite Skin Pack", "C:\\Games\\Fortnite", "FortniteDLC", "Fortnite")
    local fn = t.api.friendly_name
    check("exe inside InstallLocation -> main game name, TM removed",
        fn("FortniteClient-Win64-Shipping", "", true, "C:\\Games\\Fortnite\\FortniteGame\\Binaries\\Win64\\FortniteClient-Win64-Shipping.exe") == "Fortnite")
    check("a similarly named folder is NOT matched",
        fn("x", "My Title", true, "C:\\Games\\Fortnite2\\x.exe") == "My Title")
end)

test("official: GOG info file (main game only)", function()
    local t = new_official()
    local root = "E:\\GOG Games\\Witcher 3"
    t.dirs[(root .. "\\bin\\x64"):lower() .. "|goggame-*.info"] = {}
    t.dirs[(root .. "\\bin"):lower() .. "|goggame-*.info"] = {}
    t.dirs[root:lower() .. "|goggame-*.info"] = { "goggame-dlc.info", "goggame-1207664643.info" }
    t.files[(root .. "\\goggame-dlc.info"):lower()] = '{"name":"DLC Pack","gameId":"2"}'
    t.files[(root .. "\\goggame-1207664643.info"):lower()] = '{"gameId":"1","name":"The Witcher 3: Wild Hunt","playTasks":[{"name":"Play"}]}'
    check("deep exe finds the root info", t.api.friendly_name("witcher3", "", true, root .. "\\bin\\x64\\witcher3.exe") == "The Witcher 3: Wild Hunt")
end)

test("official: exe ProductName / FileDescription, generic values ignored", function()
    local t = new_official()
    local on = t.on
    check("Unreal Engine product -> next field", on.pick_version_name("Unreal Engine", "Palworld", "Palworld-Win64-Shipping") == "Palworld")
    check("Game is generic", on.pick_version_name("Game", nil, "x") == nil)
    check("Microsoft Windows OS string is ignored", on.pick_version_name("Microsoft\194\174 Windows\194\174 Operating System", nil, "x") == nil)
    check("name equal to the exe stem adds nothing", on.pick_version_name("hades2", nil, "Hades2") == nil)
    check("Win64-Shipping suffix removed", on.pick_version_name("Dead Island 2 Win64-Shipping", nil, "DeadIsland-Win64-Shipping") == "Dead Island 2")
    check("symbols removed", on.pick_version_name("Tom Clancy\226\128\153s Game\194\174", nil, "x") == "Tom Clancy\226\128\153s Game")
    t.exe_info["d:\\g\\cool.exe"] = { "Cool Platformer", "cool" }
    check("friendly_name uses it when no launcher knows the game", t.api.friendly_name("cool", "Cool - 60 FPS", true, "D:\\G\\cool.exe") == "Cool Platformer")
    check("generic hosts never use it (javaw)", t.api.friendly_name("javaw", "My Java Game", false, "C:\\Java\\javaw.exe") == "My Java Game")
end)

test("official: a failing lookup never breaks naming", function()
    local t = new_official()
    t.on.list_dir = function() error("boom") end
    check("falls back to the window title", t.api.friendly_name("Hades2", "Hades II", true, "D:\\SteamLibrary\\steamapps\\common\\Hades II\\Hades2.exe") == "Hades II")
    check("the failure was logged", #t.printed > 0)
end)

test("official: switch off restores the old behaviour", function()
    local t = new_official()
    local lib = "D:\\SteamLibrary\\steamapps"
    t.dirs[lib:lower() .. "|appmanifest_*.acf"] = { "a.acf" }
    t.files[(lib .. "\\a.acf"):lower()] = ACF
    t.on.enabled = false
    check("title used when disabled", t.api.friendly_name("Hades2", "Window Title", true, lib .. "\\common\\Hades II\\Hades2.exe") == "Window Title")
end)

test("official: OBS Game Capture hooked exe", function()
    local t = new_official()
    local obs = t.obs
    local hooked = true
    local fake_cd = { exe = "EldenRing.exe", title = "ELDEN RING\226\132\162" }
    obs.obs_enum_sources = function() return { "src1", "src2" } end
    obs.source_list_release = function() end
    obs.obs_source_get_unversioned_id = function(s) return s == "src1" and "game_capture" or "window_capture" end
    obs.obs_source_get_proc_handler = function() return {} end
    obs.calldata_create = function() return {} end
    obs.calldata_destroy = function() end
    obs.proc_handler_call = function() return true end
    obs.calldata_bool = function() return hooked end
    obs.calldata_string = function(_, k) return k == "executable" and fake_cd.exe or fake_cd.title end
    t.on.refresh_hooked()
    check("exe remembered (lowercase, no .exe)", t.on.seen_hooked["eldenring"] == true)
    check("title remembered (TM stripped)", t.on.hook_title["eldenring"] == "ELDEN RING")
    check("only game_capture sources are asked", t.on.seen_hooked["window_capture"] == nil)
    check("untitled window gets the hooked title", t.api.friendly_name("EldenRing", "", false, nil) == "ELDEN RING")
    hooked = false
    fake_cd.exe = "other.exe"
    t.obs.advance(3500, function() end)
    t.on.refresh_hooked()
    check("a source that is not hooked adds nothing", t.on.seen_hooked["other"] == nil)
end)

test("classify: a game hooked by OBS Game Capture is a game, a launcher never", function()
    local classify, env = load_classify()
    env.C.on = { seen_hooked = { somegame = true, steam = true }, hook_title = {} }
    local function c(exe, path, fs) return classify({ exe_name = exe, exe_path = path, is_fullscreen = fs, window_title = "" }) end
    check("hooked exe in an odd folder, windowed", c("SomeGame", "E:\\Stuff\\SomeGame.exe", false) == true)
    check("not hooked -> still not guessed", c("OtherGame", "E:\\Stuff\\OtherGame.exe", false) == false)
    check("a hooked launcher is still excluded", c("steam", "C:\\Program Files (x86)\\Steam\\steam.exe", false) == false)
end)


test("minecraft mode titles are recognised for the protected (unreadable exe) path too", function()
    local steam = new_steam()
    local g33 = read("src/33_organizer_files.lua")
    check("protected branch checks the Minecraft title", g33:find("is_minecraft_mode_title(info.window_title)", 1, true) ~= nil)
end)

test("friendly_name: a stale javaw mapping cannot override a Minecraft mode title", function()
    local steam = new_steam()
    steam.env.KNOWN_GAMES["javaw"] = "Multiplayer (3rd-party Server)"
    steam.env.name_map["javaw"] = "Multiplayer (3rd-party Server)"
    check("-> Minecraft", steam.api.friendly_name("javaw", "Guns and Ture 1.20.1 - Multiplayer (3rd-party Server)", false, nil) == "Minecraft")
end)

test("friendly_name: stale javaw mapping + plain Minecraft Forge title -> Minecraft", function()
    local steam = new_steam()
    steam.env.KNOWN_GAMES["javaw"] = "Multiplayer (3rd-party Server)"
    check("-> Minecraft", steam.api.friendly_name("javaw", "Minecraft* Forge 1.20.1", false, nil) == "Minecraft")
end)

test("generic hosts (any javaw / UWP game): exe-keyed lists never decide, titles do", function()
    local steam = new_steam()
    local fn = steam.api.friendly_name
    steam.env.KNOWN_GAMES["javaw"] = "Stale Name"
    steam.env.name_map["javaw"] = "Stale Name"
    check("stale javaw entries are ignored for a non-Minecraft Java game", fn("javaw", "Foo Game 1.2", false, nil) == "Foo Game 1.2")
    check("same for a Store (UWP) host", (function() steam.env.KNOWN_GAMES["applicationframehost"] = "Stale"; return fn("ApplicationFrameHost", "Forza Horizon", true, nil) end)() == "Forza Horizon")
    check("a normal exe still honours its entry", (function() steam.env.KNOWN_GAMES["eldenring"] = "Elden Ring"; return fn("eldenring", "x", true, nil) end)() == "Elden Ring")
end)

test("generic hosts: your own title rule (known_games.txt  title:<keyword>=<Name>)", function()
    local steam = new_steam()
    steam.env.KNOWN_GAMES["title:foo game"] = "Foo Game"
    check("title containing the keyword -> the rule's name", steam.api.friendly_name("javaw", "Foo Game 1.2 - Level 3 (Server)", false, nil) == "Foo Game")
    local classify, env = load_classify()
    env.KNOWN_GAMES["title:foo game"] = "Foo Game"
    env.KNOWN_GAMES["javaw"] = "Stale"
    local function c(title) return classify({ exe_name = "javaw", exe_path = "C:\\Java\\javaw.exe", is_fullscreen = false, window_title = title }) end
    check("javaw + matching title is a game", c("Foo Game 1.2") == true)
    check("javaw alone (stale list entry) is NOT a game", c("Some IDE") == false)
end)

test("generic hosts: the part of the title that stays the same is the name", function()
    local steam = new_steam()
    steam.env.fg_history = {
        { exe_name = "javaw", window_title = "Foo Game - Menu" },
        { exe_name = "javaw", window_title = "Foo Game - Level 3 (Server)" },
        { exe_name = "chrome", window_title = "Foo Game - Wiki" },
    }
    local fn = steam.api.friendly_name
    check("segment shared by the titles wins over the changing state", fn("javaw", "Foo Game - Level 3 (Server)", false, nil) == "Foo Game")
    steam.env.fg_history = {}
    steam.env.extract_stable_app_name = function() return "OLD RULE" end
    check("with a single title the old rule (extract_stable_app_name) applies", fn("javaw", "Foo Game - Level 3", false, nil) == "OLD RULE")
end)
------------------------------------------------------------------
print("")
for _, line in ipairs(results) do print(line) end
print(string.format("\n%d check(s), %d failed", #results, failed))
os.exit(failed == 0 and 0 or 1)
