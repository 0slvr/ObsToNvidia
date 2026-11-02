------------------------------------------------------------------
-- Official game names (all OFFLINE, no window title involved)
--
-- A window title is the weakest source for a game's name: it changes with
-- the FPS counter, the server, the modpack, the loading screen. These
-- sources know the real name instead, and are asked in this order by
-- friendly_name() (see 32_organizer_steam_names.lua):
--   1) Steam   steamapps\appmanifest_*.acf   ("name" + "installdir")
--   2) Epic    ProgramData\Epic\...\Manifests\*.item  (DisplayName + InstallLocation)
--   3) GOG     goggame-*.info next to the game (name)
--   4) the exe's own version info (ProductName, then FileDescription),
--      ignoring generic values like "Unreal Engine" or "Game"
-- plus OBS Game Capture: the games OBS has hooked are certainly real
-- games (used by classify_game) and give a title when the window has none.
--
-- Everything here is wrapped in pcall by official_lookup(): any failure just
-- means "no official name" and the old chain (title, Steam folder, Steam
-- lookup, exe name) carries on exactly as before.
--
-- Part of the Organizer's do...end block (opened in 30, closed in 33). Only
-- ONE chunk-level local is used (the chunk is near LuaJIT's 200-locals
-- limit): everything lives in the table C.on.
------------------------------------------------------------------
C.on = {
    enabled = true,
    steam = {},         -- lower "...\steamapps" dir -> { map = { lower installdir -> name }, at = ns }
    epic = nil,         -- { items = { {name, loc, is_main}, ... }, at = ns }
    cache = {},         -- lower exe path -> { name = string|false, at = ns }
    seen_hooked = {},   -- lower exe stem -> true: hooked by an OBS Game Capture source this session
    hook_title = {},    -- lower exe stem -> title of the hooked window
    hook_at = nil,      -- ns of the last Game Capture check
}

do
    local ON = C.on
    local NEG_CACHE_NS = 120 * 1e9   -- a "nothing found" answer is asked again after 2 minutes
    local RESCAN_NS    = 60 * 1e9    -- a launcher's records are re-read at most once a minute on a miss

    -- Values that say nothing about WHICH game it is (compared lowercase, ™/® removed).
    local GENERIC_PRODUCT = {
        ["unreal engine"] = true, ["unreal"] = true, ["unity"] = true, ["unity player"] = true,
        ["game"] = true, ["launcher"] = true, ["application"] = true, ["app"] = true,
        ["shipping"] = true, ["electron"] = true, ["chromium"] = true, ["godot engine"] = true,
        ["openjdk platform binary"] = true, ["java(tm) platform se binary"] = true,
        ["microsoft windows operating system"] = true,
        -- Engine / store / anti-cheat / tool strings and company names: not a game's name.
        ["unreal engine 4"] = true, ["unreal engine 5"] = true, ["unity technologies"] = true,
        ["epic games"] = true, ["epic online services"] = true, ["valve"] = true,
        ["valve corporation"] = true, ["steam"] = true, ["easy anti-cheat"] = true,
        ["easyanticheat"] = true, ["battleye"] = true, ["crash handler"] = true,
        ["crash reporter"] = true, ["setup"] = true, ["installer"] = true, ["updater"] = true,
    }
    -- A product / description that ends like a company name ("Foo Studios Inc.") names the
    -- publisher, not the game.
    -- (a table field, not a local: this block is close to the 200-locals limit)
    ON.company_endings = { "inc", "llc", "ltd", "gmbh", "corp", "corporation", "co" }

    ----------------------------------------------------------------
    -- Pure text helpers (no Win32): these are what the tests exercise
    ----------------------------------------------------------------
    function ON.clean(name)
        if type(name) ~= "string" then return nil end
        name = name:gsub("\226\132\162", ""):gsub("\194\174", ""):gsub("\194\169", "") -- ™ ® ©
        name = name:gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
        name = name:match("^%s*(.-)%s*$") or ""
        if #name < 2 then return nil end
        return name
    end

    -- Steam's appmanifest (VDF text): returns installdir, name -- or nil.
    function ON.parse_acf(text)
        if type(text) ~= "string" then return nil end
        local dir = text:match('"installdir"%s+"([^"]*)"')
        local name = text:match('"name"%s+"([^"]*)"')
        if not dir or not name or dir == "" then return nil end
        local function unesc(s) return (s:gsub("\\(.)", "%1")) end
        return unesc(dir), ON.clean(unesc(name))
    end

    -- "D:\SteamLibrary\steamapps\common\Hades II\Ship\Hades2.exe"
    --   -> "D:\SteamLibrary\steamapps", "Hades II"
    function ON.steam_split(exe_path)
        if not exe_path then return nil end
        local p = exe_path:gsub("/", "\\")
        return p:match("^(.-[Ss][Tt][Ee][Aa][Mm][Aa][Pp][Pp][Ss])\\[Cc][Oo][Mm][Mm][Oo][Nn]\\([^\\]+)")
    end

    -- Epic's .item manifest (JSON): { name, loc (lower, no trailing \), is_main } or nil.
    function ON.parse_epic(text)
        if type(text) ~= "string" then return nil end
        local function field(key)
            local _, e = text:find('"' .. key .. '"%s*:%s*"')
            if not e then return nil end
            return (read_json_string(text, e + 1))
        end
        local name, loc = field("DisplayName"), field("InstallLocation")
        if not name or not loc or name == "" or loc == "" then return nil end
        local app, main = field("AppName"), field("MainGameAppName")
        loc = loc:gsub("/", "\\"):gsub("\\+$", ""):lower()
        return { name = ON.clean(name), loc = loc, is_main = (main == nil or main == "" or main == app) }
    end

    -- Longest InstallLocation that contains the exe wins; the main game beats its DLC.
    function ON.epic_pick(items, exe_path)
        local p = exe_path:gsub("/", "\\"):lower()
        local best = nil
        for _, it in ipairs(items) do
            if it.name and p:sub(1, #it.loc) == it.loc and p:sub(#it.loc + 1, #it.loc + 1) == "\\" then
                if best == nil or #it.loc > #best.loc or (#it.loc == #best.loc and it.is_main and not best.is_main) then
                    best = it
                end
            end
        end
        return best and best.name or nil
    end

    -- GOG's goggame-<id>.info (JSON). Only the main game has "playTasks"; its
    -- top-level "name" comes before that key. A DLC info has no playTasks -> nil.
    function ON.parse_gog(text)
        if type(text) ~= "string" then return nil end
        local cut = text:find('"playTasks"', 1, true)
        if not cut then return nil end
        local head = text:sub(1, cut - 1)
        local _, e = head:find('"name"%s*:%s*"')
        if not e then return nil end
        return ON.clean((read_json_string(head, e + 1)))
    end

    -- Picks a usable name from the exe's ProductName / FileDescription, or nil.
    function ON.pick_version_name(prod, desc, raw_exe)
        local stem = normalize_for_match(raw_exe or "")
        for _, cand in ipairs({ prod or false, desc or false }) do
            local n = cand and ON.clean(cand)
            if n then
                n = ON.clean((n:gsub("%s*%-?%s*[Ww]in%d+%-[Ss]hipping$", "")))
            end
            if n then
                local lower = n:lower()
                local norm = normalize_for_match(n)
                local company = false
                for _, w in ipairs(ON.company_endings) do
                    if lower:find("%f[%w]" .. w .. "%.?$") then company = true end
                end
                if not GENERIC_PRODUCT[lower] and not lower:find("^microsoft")
                   and not lower:find("unreal engine", 1, true) and not company
                   and not lower:find("%.exe$") and #norm >= 3 and norm ~= stem then
                    return n
                end
            end
        end
        return nil
    end

    ----------------------------------------------------------------
    -- Win32 helpers (replaced by fakes in the tests)
    ----------------------------------------------------------------
    local function wide_to_utf8(wptr)
        local needed = kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wptr, -1, nil, 0, nil, nil)
        if needed <= 1 then return nil end
        local buf = ffi.new("char[?]", needed)
        kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wptr, -1, buf, needed, nil, nil)
        return ffi.string(buf, needed - 1)
    end

    -- File names (not folders) in `dir` matching `mask` ("appmanifest_*.acf").
    function ON.list_dir(dir, mask)
        local out = {}
        if not ffi or not kernel32 then return out end
        pcall(function()
            pcall(ffi.cdef, [[
typedef struct {
    DWORD dwFileAttributes; FILETIME ftCreationTime; FILETIME ftLastAccessTime; FILETIME ftLastWriteTime;
    DWORD nFileSizeHigh; DWORD nFileSizeLow; DWORD dwReserved0; DWORD dwReserved1;
    WCHAR cFileName[260]; WCHAR cAlternateFileName[14];
} WIN32_FIND_DATAW;
HANDLE FindFirstFileW(const WCHAR* lpFileName, WIN32_FIND_DATAW* lpFindFileData);
BOOL   FindNextFileW(HANDLE hFindFile, WIN32_FIND_DATAW* lpFindFileData);
BOOL   FindClose(HANDLE hFindFile);
]])
            local data = ffi.new("WIN32_FIND_DATAW")
            local h = kernel32.FindFirstFileW(utf8_to_wide(dir .. "\\" .. mask), data)
            if h == nil or tonumber(ffi.cast("intptr_t", h)) == -1 then return end
            local guard = 0
            repeat
                local is_dir = math.floor(tonumber(data.dwFileAttributes) / 16) % 2 == 1
                if not is_dir then
                    local n = wide_to_utf8(data.cFileName)
                    if n then out[#out + 1] = n end
                end
                guard = guard + 1
            until kernel32.FindNextFileW(h, data) == 0 or guard > 5000
            kernel32.FindClose(h)
        end)
        return out
    end

    function ON.read_text(path)
        local ok, text = pcall(W.read_file, path)
        if ok then return text end
        return nil
    end

    -- ProductName, FileDescription of an exe (version resource), or nil.
    function ON.exe_strings(path)
        if not ffi or not kernel32 or ON.ver_failed then return nil end
        local ok, prod, desc = pcall(function()
            if not ON.ver then
                pcall(ffi.cdef, [[
DWORD GetFileVersionInfoSizeW(const WCHAR* lptstrFilename, DWORD* lpdwHandle);
BOOL  GetFileVersionInfoW(const WCHAR* lptstrFilename, DWORD dwHandle, DWORD dwLen, void* lpData);
BOOL  VerQueryValueW(const void* pBlock, const WCHAR* lpSubBlock, void** lplpBuffer, unsigned int* puLen);
]])
                ON.ver = ffi.load("version")
            end
            local wpath = utf8_to_wide(path)
            local size = tonumber(ON.ver.GetFileVersionInfoSizeW(wpath, nil))
            if size == 0 or size > 4 * 1024 * 1024 then return nil end
            local data = ffi.new("char[?]", size)
            if ON.ver.GetFileVersionInfoW(wpath, 0, size, data) == 0 then return nil end
            local pbuf = ffi.new("void*[1]")
            local plen = ffi.new("unsigned int[1]")
            local langs = {}
            if ON.ver.VerQueryValueW(data, utf8_to_wide("\\VarFileInfo\\Translation"), pbuf, plen) ~= 0 and plen[0] >= 4 then
                local words = ffi.cast("unsigned short*", pbuf[0])
                for i = 0, math.min(math.floor(plen[0] / 4), 4) - 1 do
                    langs[#langs + 1] = string.format("%04x%04x", words[i * 2], words[i * 2 + 1])
                end
            end
            langs[#langs + 1] = "040904b0"
            langs[#langs + 1] = "040904e4"
            local function q(key)
                for _, l in ipairs(langs) do
                    local sub = "\\StringFileInfo\\" .. l .. "\\" .. key
                    if ON.ver.VerQueryValueW(data, utf8_to_wide(sub), pbuf, plen) ~= 0 and plen[0] > 1 then
                        local s = wide_to_utf8(ffi.cast("const WCHAR*", pbuf[0]))
                        if s and s ~= "" then return s end
                    end
                end
                return nil
            end
            return q("ProductName"), q("FileDescription")
        end)
        if not ok then
            ON.ver_failed = true   -- version.dll unusable here: stop trying
            return nil
        end
        return prod, desc
    end

    ----------------------------------------------------------------
    -- The launchers
    ----------------------------------------------------------------
    function ON.steam_name(exe_path)
        local lib, folder = ON.steam_split(exe_path)
        if not lib then return nil end
        local key, fold = lib:lower(), folder:lower()
        local entry = ON.steam[key]
        if entry and entry.map[fold] then return entry.map[fold] end
        local now = obs.os_gettime_ns()
        if entry and (now - entry.at) < RESCAN_NS then return nil end
        local map = {}
        for _, f in ipairs(ON.list_dir(lib, "appmanifest_*.acf")) do
            local dir, name = ON.parse_acf(ON.read_text(lib .. "\\" .. f))
            if dir and name then map[dir:lower()] = name end
        end
        ON.steam[key] = { map = map, at = now }
        return map[fold]
    end

    function ON.epic_name(exe_path)
        local now = obs.os_gettime_ns()
        if ON.epic then
            local hit = ON.epic_pick(ON.epic.items, exe_path)
            if hit then return hit end
            if (now - ON.epic.at) < RESCAN_NS then return nil end
        end
        local base = W.getenv("ProgramData") or "C:\\ProgramData"
        local dir = base .. "\\Epic\\EpicGamesLauncher\\Data\\Manifests"
        local items = {}
        for _, f in ipairs(ON.list_dir(dir, "*.item")) do
            local it = ON.parse_epic(ON.read_text(dir .. "\\" .. f))
            if it then items[#items + 1] = it end
        end
        ON.epic = { items = items, at = now }
        return ON.epic_pick(items, exe_path)
    end

    -- goggame-*.info sits in the game's root; the exe can be a few folders deeper.
    function ON.gog_name(exe_path)
        local dir = exe_path:gsub("/", "\\"):match("^(.*)\\[^\\]+$")
        for _ = 1, 4 do
            if not dir or #dir < 4 then return nil end
            for _, f in ipairs(ON.list_dir(dir, "goggame-*.info")) do
                local name = ON.parse_gog(ON.read_text(dir .. "\\" .. f))
                if name then return name end
            end
            dir = dir:match("^(.*)\\[^\\]+$")
        end
        return nil
    end

    function ON.version_name(raw_exe_name, exe_path)
        local prod, desc = ON.exe_strings(exe_path)
        return ON.pick_version_name(prod, desc, raw_exe_name)
    end

    ----------------------------------------------------------------
    -- Entry point used by friendly_name(): name or nil. Cached per exe path.
    ----------------------------------------------------------------
    function C.official_lookup(raw_exe_name, exe_path)
        if not ON.enabled or not exe_path or exe_path == "" then return nil end
        local key = exe_path:lower()
        local now = obs.os_gettime_ns()
        local hit = ON.cache[key]
        if hit and (hit.name or (now - hit.at) < NEG_CACHE_NS) then
            return hit.name or nil
        end
        local name, src = nil, nil
        local ok, err = pcall(function()
            name = ON.steam_name(exe_path)
            if name then src = "Steam" return end
            if not ON.steam_split(exe_path) then
                name = ON.epic_name(exe_path)
                if name then src = "Epic" return end
                name = ON.gog_name(exe_path)
                if name then src = "GOG" return end
            end
            name = ON.version_name(raw_exe_name, exe_path)
            if name then src = "exe info" end
        end)
        if not ok then
            print("OBS Replay Organizer: official-name lookup failed for '" .. tostring(raw_exe_name) .. "': " .. tostring(err))
            name = nil
        end
        ON.cache[key] = { name = name or false, at = now }
        if name then
            print("OBS Replay Organizer: official name '" .. name .. "' for '" .. tostring(raw_exe_name) .. "' (from " .. src .. ").")
        end
        return name
    end

    ----------------------------------------------------------------
    -- OBS Game Capture: which exe is hooked right now?
    -- Called from the foreground poll; throttled to once every 3 seconds.
    ----------------------------------------------------------------
    function ON.refresh_hooked()
        if not ON.enabled then return end
        local now = obs.os_gettime_ns()
        if ON.hook_at and (now - ON.hook_at) < 3e9 then return end
        ON.hook_at = now
        local sources = obs.obs_enum_sources()
        if sources == nil then return end
        for _, src in ipairs(sources) do
            if obs.obs_source_get_unversioned_id(src) == "game_capture" then
                local ph = obs.obs_source_get_proc_handler(src)
                if ph ~= nil then
                    local cd = obs.calldata_create()
                    if obs.proc_handler_call(ph, "get_hooked", cd) and obs.calldata_bool(cd, "hooked") then
                        local exe = (obs.calldata_string(cd, "executable") or ""):gsub("%.[Ee][Xx][Ee]$", ""):lower()
                        -- javaw / ApplicationFrameHost... run many programs: hooking one of them
                        -- must not turn every window of that exe into a "game" for the session.
                        local generic = GENERIC_HOST_EXES and GENERIC_HOST_EXES[exe]
                        if exe ~= "" and not generic then
                            ON.seen_hooked[exe] = true
                            local title = ON.clean(obs.calldata_string(cd, "title"))
                            if title then ON.hook_title[exe] = title end
                        end
                    end
                    obs.calldata_destroy(cd)
                end
            end
        end
        obs.source_list_release(sources)
    end
end
