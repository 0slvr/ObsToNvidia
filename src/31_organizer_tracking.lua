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
-- Long enough to cover the whole Replay Buffer (up to 30 min) so that a clip saved from
-- the desktop can still be traced back to the game that is in it (see get_recent_game).
local FG_HISTORY_MAX_S = 1800       -- drop samples older than this (keeps the table small)
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
    -- Lets the Steam-name code queue a background lookup for a brand-new game
    -- (defined further down; nothing here waits for the network).
    if Sorter.note_foreground then pcall(Sorter.note_foreground, info) end
    -- Which games OBS Game Capture has hooked (throttled inside; see 32b).
    if C.on and C.on.refresh_hooked then pcall(C.on.refresh_hooked) end

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
        -- Entries tile the timeline: a new one starts exactly where the previous
        -- one ended (no unattributed gap, and no zero-length first sample).
        fg_history[#fg_history + 1] = {
            start_ns = contiguous and last.end_ns or now, end_ns = now,
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
    -- Grouped by exe ONLY, not exe + title: a game whose window title keeps
    -- changing (FPS counter, level name, server) used to be split into many
    -- small entries, and a short-lived window with a steady title (Discord)
    -- could out-score the game's total time.
    local totals = {} -- lower exe name -> { duration_ns = n, info = {...} }

    for _, entry in ipairs(fg_history) do
        local s = math.max(entry.start_ns, window_start)
        local e = math.min(entry.end_ns, now)
        if e > s then
            local key = entry.exe_name:lower()
            local rec = totals[key]
            if not rec then
                rec = { duration_ns = 0, info = entry }
                totals[key] = rec
            end
            rec.last_ns = entry.end_ns
            -- The history is chronological, so this ends up holding the LATEST
            -- sample of this app -- i.e. its most recent window title and
            -- fullscreen state, which is what decides Desktop vs. game folder.
            rec.info = entry
            rec.duration_ns = rec.duration_ns + (e - s)
        end
    end

    -- Ties go to the app that was in front most recently (pairs() order is random).
    local best, best_ns, best_last = nil, -1, -1
    for _, rec in pairs(totals) do
        if rec.duration_ns > best_ns or (rec.duration_ns == best_ns and rec.last_ns > best_last) then
            best, best_ns, best_last = rec.info, rec.duration_ns, rec.last_ns
        end
    end
    return best
end

-- Length of the Replay Buffer in seconds, read from the active OBS profile
-- (Simple or Advanced output mode). nil if it can't be read.
local function replay_buffer_seconds()
    local ok, secs = pcall(function()
        local cfg = obs.obs_frontend_get_profile_config()
        if cfg == nil then return nil end
        local mode = obs.config_get_string(cfg, "Output", "Mode")
        local section = (mode == "Advanced") and "AdvOut" or "SimpleOutput"
        local v = tonumber(obs.config_get_int(cfg, section, "RecRBTime"))
        if v and v > 0 then return v end
        return nil
    end)
    if ok then return secs end
    return nil
end

-- How far back to look for a game when the foreground at save time is NOT a game
-- (you played, went to the desktop / Discord / browser, and then saved).
-- At most ONE minute, and never longer than the Replay Buffer itself (a clip can't
-- contain anything older than the buffer). Never less than 10 seconds.
local function game_memory_seconds()
    local w = math.min(replay_buffer_seconds() or 60, 60)
    return math.max(w, 10)
end

-- Looks through the last `seconds` of history for a GAME (is_game(entry) decides)
-- and returns the one that was in front MOST RECENTLY, as the latest history entry
-- of that game -- or nil if there was none. A game only counts if it was in front for
-- at least `min_s` seconds in total, so a flash of a window passing by is ignored.
-- Playing A, then B, then going to the desktop -> B (the last game you played).
local function get_recent_game(seconds, is_game, min_s)
    local now = obs.os_gettime_ns()
    local window_start = now - (seconds * 1e9)
    local totals = {}
    for _, entry in ipairs(fg_history) do
        local s = math.max(entry.start_ns, window_start)
        local e = math.min(entry.end_ns, now)
        if e > s and entry.exe_name and is_game(entry) then
            -- Protected (anti-cheat) games all share the placeholder exe name, so
            -- they are told apart by their window title instead.
            local key = entry.protected and ("?p:" .. tostring(entry.window_title)) or entry.exe_name:lower()
            local rec = totals[key]
            if not rec then
                rec = { duration_ns = 0 }
                totals[key] = rec
            end
            rec.info = entry        -- chronological: ends up as the LATEST game sample
            rec.last_ns = entry.end_ns
            rec.duration_ns = rec.duration_ns + (e - s)
        end
    end
    local best, best_last = nil, -1
    for _, rec in pairs(totals) do
        if rec.duration_ns >= (min_s or 0) * 1e9 and rec.last_ns > best_last then
            best, best_last = rec.info, rec.last_ns
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
            kernel32.SetFileAttributesW(utf8_to_wide(path), C.FILE_ATTRIBUTE_HIDDEN)
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
    kernel32.SetFileAttributesW(utf8_to_wide(path), C.FILE_ATTRIBUTE_HIDDEN)
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
    name = name:gsub("[%z\1-\31\127]", " ")        -- any other control character (invalid in file names)
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

    -- One field, "current folder name = new name" (the "=" is pre-filled).
    local entry = obs.obs_data_get_string(current_settings, "new_rename") or ""
    local left, right = entry:match("^(.-)=(.*)$")
    local current_folder = left and left:match("^%s*(.-)%s*$") or ""
    local friendly = right and right:match("^%s*(.-)%s*$") or ""

    if current_folder == "" or friendly == "" then
        print("OBS Replay Organizer: type  current folder name = new name  before adding.")
        return false
    end

    local raw = last_seen_exe_by_folder[sanitize(current_folder):lower()]
    if raw == nil then
        -- Not a folder name we know: maybe it's the program's own exe name (as Task
        -- Manager shows it, e.g. "MyGame" or "MyGame.exe") of something that was in
        -- front recently. This is how a game the script doesn't recognise (windowed,
        -- installed in an unusual folder...) can be taught without a clip first.
        local want = (current_folder:lower():gsub("%.exe$", ""))
        for i = #fg_history, 1, -1 do
            local e = fg_history[i]
            if e.exe_name and not e.protected and e.exe_name:lower() == want then
                raw = want
                break
            end
        end
    end
    if raw == nil then
        print("OBS Replay Organizer: no clip has been sorted into a folder named '" ..
              current_folder .. "' yet, and no program with that exe name was in front recently -- " ..
              "play that game and save one clip first (or type its exe name as in Task Manager), then try again.")
        return false
    end

    local existing = obs.obs_data_get_string(current_settings, "name_map")
    friendly = friendly:gsub("[\r\n=]", " ")
    local new_line = raw .. "=" .. friendly
    -- Replace any older line for the same exe instead of piling up duplicates.
    local kept = {}
    for line in (existing or ""):gmatch("[^\r\n]+") do
        local old_raw = line:match("^%s*(.-)%s*=")
        if not (old_raw and old_raw:lower() == raw:lower()) then
            kept[#kept + 1] = line
        end
    end
    kept[#kept + 1] = new_line
    local updated = table.concat(kept, "\n")

    obs.obs_data_set_string(current_settings, "name_map", updated)
    obs.obs_data_set_string(current_settings, "new_rename", "=")

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
        obs.obs_properties_add_bool(
            props, "official_names_enabled",
            "Use official game names (Steam/Epic/GOG records, exe info, OBS Game Capture)"
        )
        obs.obs_properties_add_bool(
            props, "steam_lookup_enabled",
            "Look up unknown games on Steam (online, last resort only)"
        )
        obs.obs_properties_add_text(
            props, "new_rename",
            "Folder name = New name",
            obs.OBS_TEXT_DEFAULT
        )
        obs.obs_properties_add_button(
            props, "add_mapping_btn", "Add",
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

    end

    function Sorter.script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "sorter_enabled", true)
    obs.obs_data_set_default_string(settings, "new_rename", "=")
    obs.obs_data_set_default_double(settings, "lookback_s", 8)
    obs.obs_data_set_default_bool(settings, "steam_lookup_enabled", true)
    obs.obs_data_set_default_bool(settings, "official_names_enabled", true)
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
        if Sorter.cancel_steam_queue then Sorter.cancel_steam_queue() end
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
    if C.on then C.on.enabled = obs.obs_data_get_bool(settings, "official_names_enabled") end
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

-- keep_whole = true: the window is a fullscreen game, so a " - " in its title is
-- part of the game's name ("Hollow Knight - Silksong"), not an app-name suffix.
local function extract_stable_app_name(title, keep_whole)
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
    if keep_whole then
        return title
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

