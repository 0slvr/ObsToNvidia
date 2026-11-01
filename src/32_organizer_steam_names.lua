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
C.WINHTTP_QUERY_STATUS_CODE   = 19
C.WINHTTP_QUERY_CONTENT_LENGTH = 5
C.WINHTTP_QUERY_FLAG_NUMBER   = 0x20000000

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
            C.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0)
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

-- "...\\steamapps\\common\\Hades II\\Ship\\Hades2.exe" -> "Hades II" (offline, exact).
local function steam_folder_name(exe_path)
    if not exe_path then return nil end
    local name = exe_path:gsub("/", "\\"):match("[Ss][Tt][Ee][Aa][Mm][Aa][Pp][Pp][Ss]\\[Cc][Oo][Mm][Mm][Oo][Nn]\\([^\\]+)\\")
    return name
end

local function friendly_name(raw_exe_name, window_title, is_fullscreen, exe_path)
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

