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

-- Minecraft's window title always ENDS with the mode: "<name> <version> - Singleplayer",
-- "... - Multiplayer (3rd-party Server)", "... - Multiplayer (LAN)". The word "Minecraft"
-- at the start is not reliable: modpacks / launchers (ATLauncher, SKLauncher, title mods)
-- replace it with their own name. Without this check such a window was named from the
-- part after the last " - " -- a folder called "Multiplayer (3rd-party Server)".
local function is_minecraft_mode_title(title)
    if not title or title == "" then return false end
    local t = "- " .. title:lower()  -- so a title that is ONLY the mode ("Multiplayer (LAN)") matches too
    return t:find("%- singleplayer%s*$") ~= nil or t:find("%- multiplayer %b()%s*$") ~= nil
end

-- YOUR title rules: a line  title:<keyword>=<Folder Name>  in known_games.txt (or the Add
-- list). Works for ANY program: a window whose title contains the keyword is that game.
-- Example:  title:hollow knight=Hollow Knight
-- (A table field, not a chunk-level local: the combined script is near LuaJIT's local limit.)
function C.user_title_rule(title)
    if title == nil or title == "" then return nil end
    local lowered = title:lower()
    for _, map in ipairs({ name_map, KNOWN_GAMES }) do
        for key, name in pairs(map) do
            if key:sub(1, 6) == "title:" and #key > 6 and lowered:find(key:sub(7), 1, true) then
                return name
            end
        end
    end
    return nil
end

-- A name decided by the WINDOW TITLE, for programs whose exe says nothing (generic hosts)
-- and for Minecraft-style mode titles. Sources: Minecraft's mode titles, the built-in
-- TITLE_KEYWORD_NAMES, and your own title: rules (see C.user_title_rule).
local function title_rule_name(title)
    if title == nil or title == "" then return nil end
    if is_minecraft_mode_title(title) then return "Minecraft" end
    local lowered = title:lower()
    for _, rule in ipairs(TITLE_KEYWORD_NAMES) do
        if lowered:find(rule[1], 1, true) then return rule[2] end
    end
    return C.user_title_rule(title)
end

-- "Game 1.2 - Level 3" / "Game 1.2 - Multiplayer (Server)": the state part changes, the
-- game part stays. For a generic host (javaw, ApplicationFrameHost...) every different title
-- this exe had in the foreground history is split into segments, and the segment that
-- appears in the MOST of them is the name. With fewer than two different titles there is
-- nothing to compare, and the old rule (the part after the last " - ") applies.
local function split_title_segments(title)
    local t = title:gsub("%s+%-%s+", "\1"):gsub("%s+|%s+", "\1"):gsub("%s+\226\128\148%s+", "\1")
    local segs = {}
    for seg in t:gmatch("[^\1]+") do
        seg = seg:match("^%s*(.-)%s*$")
        if seg ~= "" then segs[#segs + 1] = seg end
    end
    return segs
end

local function stable_host_title(lower_exe, current)
    local titles, seen = {}, {}
    local function add(t)
        if t and t ~= "" and not seen[t] then
            seen[t] = true
            titles[#titles + 1] = t
        end
    end
    for _, e in ipairs(fg_history or {}) do
        if e.exe_name and e.exe_name:lower() == lower_exe then add(e.window_title) end
    end
    add(current)
    if #titles >= 2 then
        local counts = {}
        for _, t in ipairs(titles) do
            local in_this = {}
            for _, seg in ipairs(split_title_segments(t)) do
                if not in_this[seg] then
                    in_this[seg] = true
                    counts[seg] = (counts[seg] or 0) + 1
                end
            end
        end
        local best, best_n = nil, 1
        for _, seg in ipairs(split_title_segments(current)) do   -- ties: the earlier segment
            if counts[seg] and counts[seg] > best_n then best, best_n = seg, counts[seg] end
        end
        if best then return best end
    end
    return extract_stable_app_name(current)
end

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
-- Second return value: true for an EXACT match, false for a partial one.
-- Only exact matches are trusted enough to be saved to known_games.txt
-- ("cod" would otherwise match "Decode" and be remembered forever).
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
            return name, true
        end
        if partial == nil and #n >= 3 and (n:find(q, 1, true) or q:find(n, 1, true)) then
            partial = name
        end
    end
    return partial, false
end

-- Blocking HTTPS GET over WinHTTP. Runs on whatever thread calls it
-- (OBS's frontend-event thread, in our case) -- kept short via the
-- STEAM_*_TIMEOUT_MS constants above specifically because of that.
-- Returns the response body as a string, or nil on any failure.
-- WinHttpQueryHeaders selectors for the status-code read below.
C.WINHTTP_QUERY_STATUS_CODE   = 19
C.WINHTTP_QUERY_CONTENT_LENGTH = 5
C.WINHTTP_QUERY_FLAG_NUMBER   = 0x20000000

-- Network circuit breaker, per host. Every request here is a BLOCKING call on
-- OBS's own thread, so a dead connection must not be retried over and over:
-- after 2 failures in a row the host is skipped for 2 minutes, then 4, 8 ...
-- up to 30 minutes. One success clears it. A caller that was started by the
-- user (the "Check for Updates Now" button) passes timeouts.force = true.
-- (Kept in the shared C table: the chunk is close to LuaJIT's 200-locals limit.)
C.net_state = {}
function C.net_blocked(host)
    local st = C.net_state[host]
    return st ~= nil and st.until_ns ~= nil and obs.os_gettime_ns() < st.until_ns
end
function C.net_record(host, ok)
    local st = C.net_state[host]
    if st == nil then
        st = { fails = 0 }
        C.net_state[host] = st
    end
    if ok then
        st.fails, st.until_ns = 0, nil
        return
    end
    st.fails = st.fails + 1
    if st.fails >= 2 then
        local wait_s = math.min(1800, 120 * 2 ^ (st.fails - 2))
        st.until_ns = obs.os_gettime_ns() + wait_s * 1e9
    end
end

-- Reads a numeric response header (status code, Content-Length) or nil.
local function query_number_header(hRequest, selector)
    local value = ffi.new("DWORD[1]")
    local len = ffi.new("DWORD[1]", ffi.sizeof("DWORD"))
    local ok = winhttp.WinHttpQueryHeaders(hRequest,
        selector + C.WINHTTP_QUERY_FLAG_NUMBER, nil, value, len, nil)
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
    if not timeouts.force and C.net_blocked(host) then
        return nil -- the circuit breaker is open for this host (see C.net_record)
    end
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
        -- Automatic proxy (Windows 8.1+) follows the system's proxy auto-config
        -- like a browser does; the plain default fails behind a PAC/WPAD proxy.
        -- Older Windows refuses it: fall back to the default.
        hSession = winhttp.WinHttpOpen(utf8_to_wide("OBS-ReplayOrganizer/1.0"),
            C.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0)
        if hSession == nil then
            hSession = winhttp.WinHttpOpen(utf8_to_wide("OBS-ReplayOrganizer/1.0"),
                C.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0)
        end
        if hSession == nil then return nil end

        winhttp.WinHttpSetTimeouts(hSession,
            timeouts.resolve or C.STEAM_RESOLVE_TIMEOUT_MS,
            timeouts.connect or C.STEAM_CONNECT_TIMEOUT_MS,
            timeouts.send    or C.STEAM_SEND_TIMEOUT_MS,
            timeouts.receive or C.STEAM_RECEIVE_TIMEOUT_MS)

        hConnect = winhttp.WinHttpConnect(hSession, utf8_to_wide(host), 443, 0)
        if hConnect == nil then return nil end

        hRequest = winhttp.WinHttpOpenRequest(hConnect, utf8_to_wide("GET"),
            utf8_to_wide(path_and_query), nil, nil, nil, C.WINHTTP_FLAG_SECURE)
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
        local status = query_number_header(hRequest, C.WINHTTP_QUERY_STATUS_CODE)
        if status ~= nil and status ~= 200 and status ~= 206 then return nil end

        local expected = query_number_header(hRequest, C.WINHTTP_QUERY_CONTENT_LENGTH)

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
    if ok and body ~= nil then
        C.net_record(host, true)
        return body
    end
    C.net_record(host, false)
    return nil
end

-- Exposed on the module table so the Updater module (defined after this
-- "do" block closes, further down the file) can reuse this exact same
-- WinHTTP plumbing instead of redeclaring the whole ffi.cdef a second
-- time (which would error on the duplicate typedefs/prototypes).
Sorter.https_get = https_get
Sorter.net_blocked = C.net_blocked

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

    -- Only Steam lookups call this (never window-title names). The duplicate
    -- check stops the same line being appended again within one session.
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

-- The blocking lookup itself. Only ever called from the background timer
-- below, never from the save handler or the foreground poll: a few hundred ms
-- to ~2 s of a stalled OBS is fine for the first sighting of a game, but not
-- in the middle of a save (which restarts the Replay Buffer right after).
local function steam_lookup_now(raw_exe_name)
    local lower = raw_exe_name:lower()
    if not steam_lookup_enabled or GENERIC_HOST_EXES[lower] then
        return nil
    end
    if steam_lookup_cache[lower] then
        return steam_lookup_cache[lower]
    end
    if steam_lookup_failed[lower] then
        return nil
    end
    if C.net_blocked("store.steampowered.com") then
        return nil -- circuit breaker open: not marked as failed, tried again later
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

    local name, exact = pick_steam_name(json_extract_names(body), query)
    if not name or name == "" then
        steam_lookup_failed[lower] = true
        return nil
    end

    steam_lookup_cache[lower] = name
    if exact then
        KNOWN_GAMES[lower] = name -- instant for the rest of THIS session too
        persist_known_game(raw_exe_name, name)
        print("OBS Replay Organizer: Steam lookup found '" .. name .. "' for '" .. raw_exe_name .. "' -- saved to known_games.txt.")
    else
        -- A partial match is a guess: use it for this session only, never save it.
        print("OBS Replay Organizer: Steam lookup guessed '" .. name .. "' for '" .. raw_exe_name .. "' (not an exact match, so not saved).")
    end
    return name
end

-- Background queue of exe names waiting for a Steam lookup (one chunk-level
-- local on purpose, see the locals-limit note above).
local steam_q = { list = {}, queued = {}, seen = {} }

local function steam_q_schedule(ms)
    obs.timer_remove(steam_q.tick)
    obs.timer_add(steam_q.tick, ms)
end

steam_q.tick = function()
    obs.timer_remove(steam_q.tick)
    if #steam_q.list == 0 then return end
    -- Never stall a live stream or a recording: try again later.
    if obs.obs_frontend_streaming_active() or obs.obs_frontend_recording_active() then
        steam_q_schedule(30000)
        return
    end
    local raw = table.remove(steam_q.list, 1)
    steam_q.queued[raw:lower()] = nil
    local ok, err = pcall(steam_lookup_now, raw)
    if not ok then
        steam_lookup_failed[raw:lower()] = true
        print("OBS Replay Organizer: Steam lookup error for '" .. raw .. "': " .. tostring(err))
    end
    if #steam_q.list > 0 then steam_q_schedule(2000) end
end

function Sorter.cancel_steam_queue()
    obs.timer_remove(steam_q.tick)
    steam_q.list, steam_q.queued, steam_q.seen = {}, {}, {}
end

-- Used while a clip is being sorted. NEVER touches the network: it returns what
-- is already known this session, otherwise queues a background lookup and
-- returns nil (the caller falls back to the exe name for this one clip; the
-- next save of the game uses the Steam name).
local function steam_lookup_name(raw_exe_name)
    local lower = raw_exe_name:lower()
    if not steam_lookup_enabled or GENERIC_HOST_EXES[lower] then
        return nil
    end
    if steam_lookup_cache[lower] then
        return steam_lookup_cache[lower]
    end
    if steam_lookup_failed[lower] or steam_q.queued[lower] then
        return nil
    end
    steam_q.queued[lower] = true
    steam_q.list[#steam_q.list + 1] = raw_exe_name
    steam_q_schedule(1500)
    return nil
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
    -- Game stores / launchers themselves (they live in game-library folders, so without
    -- this they would be taken for a game now that windowed games count too).
    steam = true, steamwebhelper = true, steamservice = true,
    epicgameslauncher = true, epicwebhelper = true,
    galaxyclient = true, ["battle.net"] = true,
    riotclientservices = true, riotclientux = true, riotclientuxrender = true,
    ubisoftconnect = true, upc = true, uplay = true,
    eadesktop = true, ealauncher = true, origin = true,
    xboxpcapp = true, gamingservicesui = true,
    -- Common non-game apps that can go fullscreen.
    powerpnt = true, winword = true, excel = true, acrobat = true, acrord32 = true,
    mstsc = true, vmware = true, vmplayer = true, teamviewer = true, anydesk = true,
    kodi = true, stremio = true, plex = true, slack = true, telegram = true,
    ["mpc-be64"] = true, ["mpc-hc"] = true, smplayer = true, kmplayer = true,
    wallpaper32 = true, wallpaper64 = true,
    -- Helper / overlay / launcher tools that are often installed in a game library or kept
    -- open next to a game (a few seconds in front of one must not take over its clip).
    losslessscaling = true, soundpad = true,
    voicemeeter = true, voicemeeterpro = true, voicemeeter8x64 = true,
    msiafterburner = true, rtss = true, hwinfo64 = true, hwinfo32 = true,
    ["playnite.desktopapp"] = true, ["playnite.fullscreenapp"] = true,
    borderlessgaming = true, vrmonitor = true, vrdashboard = true,
}

-- Install locations of the common game stores / launchers. In strict mode an
-- unknown app only counts as a game when it is fullscreen AND its exe lives in
-- one of these (or in a folder literally named "Games"). Discord, Claude,
-- browsers, editors... live in AppData / Program Files, so they never match.
local GAME_LIBRARY_MARKERS = {
    "\\steamapps\\common\\", "\\steamlibrary\\", "\\epic games\\", "\\gog galaxy\\games\\", "\\gog games\\",
    "\\battle.net\\", "\\blizzard entertainment\\", "\\amazon games\\library\\", "\\itch\\apps\\",
    "\\riot games\\", "\\ubisoft\\ubisoft game launcher\\games\\", "\\ea games\\",
    "\\origin games\\", "\\xboxgames\\", "\\rockstar games\\",
    "\\games\\",
}

local function is_in_game_library(path)
    if not path or path == "" then return false end
    local p = path:lower():gsub("/", "\\")
    -- The store launchers themselves also live under "Epic Games" etc.
    if p:find("\\epic games\\launcher\\", 1, true) or p:find("\\epic online services\\", 1, true) then
        return false
    end
    for _, marker in ipairs(GAME_LIBRARY_MARKERS) do
        if p:find(marker, 1, true) then
            return true
        end
    end
    return false
end

-- Where a game is NOT installed. A fullscreen app outside every game library is still
-- taken for a game (games installed on any drive / any folder), unless it lives in one
-- of these places: Windows itself, Store apps, Office, browsers, per-user app folders
-- (Electron apps like Discord / Slack live under AppData).
local NON_GAME_PATH_MARKERS = {
    "\\windowsapps\\", "\\microsoft office\\", "\\microsoft\\edge\\",
    "\\google\\chrome\\", "\\mozilla firefox\\", "\\common files\\", "\\appdata\\",
}

local function is_plausible_fullscreen_game(path)
    if not path or path == "" then return false end
    local p = path:lower():gsub("/", "\\")
    if p:match("^%a:\\windows\\") then return false end -- the real Windows folder only
    for _, marker in ipairs(NON_GAME_PATH_MARKERS) do
        if p:find(marker, 1, true) then
            return false
        end
    end
    return true
end

-- "...\\steamapps\\common\\Hades II\\Ship\\Hades2.exe" -> "Hades II" (offline, exact).
local function steam_folder_name(exe_path)
    if not exe_path then return nil end
    local name = exe_path:gsub("/", "\\"):match("[Ss][Tt][Ee][Aa][Mm][Aa][Pp][Pp][Ss]\\[Cc][Oo][Mm][Mm][Oo][Nn]\\([^\\]+)\\")
    return name
end

local function friendly_name(raw_exe_name, window_title, is_fullscreen, exe_path)
    local lower = raw_exe_name:lower()

    -- GENERIC HOSTS (javaw, ApplicationFrameHost, python, dotnet...): the exe does not say
    -- WHICH program runs, so a list entry keyed by the exe ("javaw=<something>", which older
    -- versions could save from a window title) must never decide the folder -- it would
    -- rename every Java program / Store app. They are named from the title instead:
    -- a title rule first, then the part of the title that stays the same.
    if GENERIC_HOST_EXES[lower] then
        local rule = title_rule_name(window_title)
        if rule then
            return rule
        end
        if window_title ~= nil and window_title ~= "" then
            return sanitize(stable_host_title(lower, window_title))
        end
        return raw_exe_name
    end

    local mapped = name_map[lower]
    if mapped then
        return mapped
    end

    local known = KNOWN_GAMES[lower]
    if known then
        return known
    end

    -- Your own title: rule (known_games.txt / Add list) for any program.
    local by_title = C.user_title_rule(window_title)
    if by_title then
        return by_title
    end

    -- Any program whose window title is a Minecraft mode title is Minecraft, whatever
    -- the launcher / modpack calls the window and whichever java exe runs it.
    if is_minecraft_mode_title(window_title) then
        return "Minecraft"
    end

    local has_title = window_title ~= nil and window_title ~= ""

    -- Official name from the launcher's own records (Steam / Epic / GOG) or the exe's
    -- version info -- offline, and not affected by FPS counters, servers or loading
    -- screens in the window title (see 32b_organizer_official_names.lua).
    if C.official_lookup then
        local official = C.official_lookup(raw_exe_name, exe_path)
        if official then
            return official
        end
    end

    local cached = title_name_cache[lower]
    if cached then
        return cached
    end

    if has_title then
        -- Sanitize now (not just later in on_replay_saved) so the name we
        -- remember is the EXACT string that will become the folder name.
        local name = sanitize(extract_stable_app_name(window_title, is_fullscreen))
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

    -- No window title: the title OBS Game Capture saw for this exe, if it is hooked.
    local hooked_title = C.on and C.on.hook_title[lower]
    if hooked_title then
        title_name_cache[lower] = sanitize(hooked_title)
        return title_name_cache[lower]
    end

    -- No window title: the Steam install folder names the game exactly, offline.
    local folder_name = steam_folder_name(exe_path)
    if folder_name then
        title_name_cache[lower] = sanitize(folder_name)
        return title_name_cache[lower]
    end

    local steam_name = steam_lookup_name(raw_exe_name)
    if steam_name then
        return steam_name
    end

    return raw_exe_name:match("^([^%.%-]+)") or raw_exe_name
end

-- Called by the foreground poll (see fg_poll_tick) for the app in front. The
-- first time a fullscreen, untitled game from a game library shows up with no
-- known name, its Steam lookup is queued right away, so the name is usually
-- ready by the time the first clip is saved (instead of being looked up in the
-- middle of that save). Once per exe per session; mirrors the checks that
-- on_replay_saved + friendly_name make before they would reach a lookup.
function Sorter.note_foreground(info)
    if not steam_lookup_enabled or info == nil or info.protected or not info.is_fullscreen then
        return
    end
    local exe = info.exe_name
    if exe == nil or exe == "" then return end
    local lower = exe:lower()
    if steam_q.seen[lower] then return end
    steam_q.seen[lower] = true
    if name_map[lower] or KNOWN_GAMES[lower] or GENERIC_HOST_EXES[lower] or NON_GAME_EXES[lower] then return end
    if info.window_title ~= nil and info.window_title ~= "" then return end
    if not is_in_game_library(info.exe_path) or steam_folder_name(info.exe_path) then return end
    steam_lookup_name(exe)
end
