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
-- self-restart after an update (kernel32) and then, after the C.WM_CLOSE
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
/* The command line OBS was started with (e.g. --portable, --profile, --collection),
   so the relaunch after an update starts OBS the same way. */
const WCHAR* GetCommandLineW(void);

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
   a normal C.WM_CLOSE, the same message Windows sends when the user clicks
   the title-bar X -- NOT ExitProcess(), which used to hard-kill the
   process. A hard kill skips OBS's own shutdown path entirely, so it
   never gets to write the "clean exit" marker it checks on the next
   launch -- that's what was popping the "OBS Studio did not properly
   shut down" / Safe Mode prompt after every self-update. C.WM_CLOSE lets
   OBS run its real shutdown (save config, release the single-instance
   lock, mark the exit clean) before the process actually ends. */
DWORD  GetCurrentProcessId();
DWORD  WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
typedef struct { DWORD dwLowDateTime; DWORD dwHighDateTime; } FILETIME;
BOOL   GetProcessTimes(HANDLE hProcess, FILETIME* lpCreationTime, FILETIME* lpExitTime,
                       FILETIME* lpKernelTime, FILETIME* lpUserTime);
BOOL   IsWindowVisible(HWND hWnd);
typedef int (*WNDENUMPROC)(HWND, intptr_t);
BOOL   EnumWindows(WNDENUMPROC lpEnumFunc, intptr_t lParam);
BOOL   PostMessageW(HWND hWnd, unsigned int Msg, uintptr_t wParam, intptr_t lParam);

/* GetWindow(hWnd, C.GW_OWNER) tells an owned window (Scripts dialog, floating
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

-- C.PROCESS_QUERY_LIMITED_INFORMATION: unlike PROCESS_QUERY_INFORMATION,
-- this is specifically designed to let a normal (non-elevated) process
-- like OBS still read basic info — such as the exe name — from a
-- process running with higher privileges (Administrator), which is
-- common for games with anti-cheat. Without this, OpenProcess silently
-- fails for elevated games and everything falls back to "Unsorted".
C.PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

-- MoveFileExA flags
C.MOVEFILE_COPY_ALLOWED     = 0x2 -- allows the move to work across drives too
C.ERROR_ALREADY_EXISTS      = 183
C.ERROR_SHARING_VIOLATION   = 32
C.ERROR_LOCK_VIOLATION      = 33
C.CP_UTF8                   = 65001
C.MOVE_RETRY_ATTEMPTS       = 6
C.MOVE_RETRY_DELAY_MS       = 300
C.MONITOR_DEFAULTTONEAREST  = 0x2
C.INVALID_FILE_ATTRIBUTES   = 0xFFFFFFFF
C.FILE_ATTRIBUTE_HIDDEN     = 0x2

-- WinHTTP constants for the optional Steam lookup (see steam_lookup_name
-- further down). Timeouts are intentionally short-ish: this call can run
-- on OBS's frontend-event thread, so a slow/unreachable network should
-- not be able to stall OBS for long. Worst case (each phase timing out
-- in sequence) is bounded to roughly the sum of these four values.
C.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0
C.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4  -- Windows 8.1+; WinHttpOpen fails on older ones

-- Win32 error code of the FFI call that JUST returned. ffi.errno() is the
-- supported way: LuaJIT saves the last error right after every FFI call, while
-- a separate kernel32.GetLastError() call can already see a value changed by
-- LuaJIT / the GC in between. Falls back to GetLastError if ffi.errno is
-- missing. Call it immediately after the failing call, before any other FFI call.
-- (A field of C, not a local: the chunk is close to LuaJIT's 200-locals limit.)
function C.last_error()
    if ffi ~= nil and ffi.errno ~= nil then
        return tonumber(ffi.errno())
    end
    return tonumber(kernel32.GetLastError())
end
C.WINHTTP_FLAG_SECURE               = 0x00800000
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
C.STEAM_RESOLVE_TIMEOUT_MS          = 500
C.STEAM_CONNECT_TIMEOUT_MS          = 500
C.STEAM_SEND_TIMEOUT_MS             = 500
C.STEAM_RECEIVE_TIMEOUT_MS          = 800

-- Wide-char buffer size for the exe path. 32760 (not the old 260/MAX_PATH)
-- so deeply nested Steam/library paths or long-path-enabled installs
-- don't get silently truncated.
C.EXE_PATH_BUF_LEN          = 32760

-- Reads the real window title (e.g. "ELDEN RING", "Counter-Strike 2") --
-- the same signal NVIDIA/Windows Game Bar use to recognize a game,
-- which is far more reliable than guessing from the exe filename.
-- Returns a cleaned UTF-8 string, or nil if there's no usable title.
-- 1024 wide characters, not 260. GetWindowTextW silently truncates to
-- whatever it's given, and a few games/launchers carry long titles (with
-- a subtitle, build string or server name appended). A truncated title
-- produced a truncated folder name, and if the cut-off point ever moved
-- the same game earned itself a second folder.
C.TITLE_BUF_LEN = 1024
local title_wbuf = ffi and ffi.new("WCHAR[?]", C.TITLE_BUF_LEN) or nil
local class_wbuf = ffi and ffi.new("WCHAR[?]", 260) or nil
-- Reused UTF-8 output buffer (1024 wide chars -> at most 3 bytes each): no allocation per poll.
local U8_BUF_LEN = 4096
local u8_buf = ffi and ffi.new("char[?]", U8_BUF_LEN) or nil

local function get_window_title(hwnd)
    local wbuf = title_wbuf
    local len = user32.GetWindowTextW(hwnd, wbuf, C.TITLE_BUF_LEN)
    if len <= 0 then
        return nil
    end

    -- Ask how many bytes the UTF-8 conversion needs, then convert.
    local needed = kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wbuf, len, u8_buf, U8_BUF_LEN, nil, nil)
    if needed <= 0 then
        return nil
    end
    local title = ffi.string(u8_buf, needed)

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
    local needed = kernel32.MultiByteToWideChar(C.CP_UTF8, 0, str, #str, nil, 0)
    if needed <= 0 then
        return nil
    end
    local wbuf = ffi.new("WCHAR[?]", needed + 1)
    kernel32.MultiByteToWideChar(C.CP_UTF8, 0, str, #str, wbuf, needed)
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
        return tonumber(kernel32.GetFileAttributesW(wide)) ~= C.INVALID_FILE_ATTRIBUTES
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
        local bytes = kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wbuf, len, nil, 0, nil, nil)
        if bytes <= 0 then return nil end
        local out = ffi.new("char[?]", bytes)
        kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wbuf, len, out, bytes, nil, nil)
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
    local needed = kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wbuf, len, u8_buf, U8_BUF_LEN, nil, nil)
    if needed <= 0 then
        return nil
    end
    return ffi.string(u8_buf, needed):lower()
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

    local hmon = user32.MonitorFromWindow(hwnd, C.MONITOR_DEFAULTTONEAREST)
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
C.LOG_THROTTLE_NS = 60 * 1e9
local last_logged_at = {}

local function log_throttled(msg)
    local now = obs.os_gettime_ns()
    local previous = last_logged_at[msg]
    if previous and (now - previous) < C.LOG_THROTTLE_NS then
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
-- C.MB_YESNOCANCEL is deliberate: Windows does not allow MessageBox button
-- captions to be renamed, so what each of the three buttons means is
-- spelled out in the message text rather than left to be guessed from
-- "Yes / No / Cancel".
C.MB_YESNOCANCEL   = 0x00000003
C.MB_ICONQUESTION  = 0x00000020
C.MB_SETFOREGROUND = 0x00010000
C.MB_TOPMOST       = 0x00040000

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
            C.MB_YESNOCANCEL + C.MB_ICONQUESTION + C.MB_SETFOREGROUND + C.MB_TOPMOST)
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
local fg_exe_wbuf = ffi and ffi.new("WCHAR[?]", C.EXE_PATH_BUF_LEN) or nil
local fg_size_cell = ffi and ffi.new("DWORD[1]") or nil
local fg_pid_cell  = ffi and ffi.new("DWORD[1]") or nil
-- The exe behind a pid never changes while that process lives, so the
-- OpenProcess + QueryFullProcessImageName + UTF-8 conversion is done once per
-- pid instead of twice a second (the 500 ms foreground poll).
local exe_cache_pid, exe_cache_name, exe_cache_path = nil, nil, nil

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

    if exe_cache_pid == pid[0] then
        return { exe_name = exe_cache_name, exe_path = exe_cache_path, window_title = window_title, is_fullscreen = fullscreen }
    end

    local hproc = kernel32.OpenProcess(C.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid[0])
    if hproc == nil then
        return protected_fallback("OpenProcess failed for pid " .. tostring(pid[0]) ..
              " (protected/elevated process) -- using its window title.")
    end

    local wbuf = fg_exe_wbuf
    local size = fg_size_cell
    size[0] = C.EXE_PATH_BUF_LEN
    local ok = kernel32.QueryFullProcessImageNameW(hproc, 0, wbuf, size)
    kernel32.CloseHandle(hproc)

    if ok == 0 then
        return protected_fallback("QueryFullProcessImageNameW failed for pid " .. tostring(pid[0]) .. " -- using its window title.")
    end

    -- Convert the wide path to UTF-8 the same way get_window_title() does,
    -- so a non-English (e.g. Arabic) user/folder name in the exe's path
    -- comes through correctly instead of turning into mojibake.
    local needed = kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wbuf, size[0], nil, 0, nil, nil)
    if needed <= 0 then
        return protected_fallback("couldn't convert exe path to UTF-8 for pid " .. tostring(pid[0]) .. ".")
    end
    local buf = ffi.new("char[?]", needed)
    kernel32.WideCharToMultiByte(C.CP_UTF8, 0, wbuf, size[0], buf, needed, nil, nil)
    local full_path = ffi.string(buf, needed)

    local exe_name = full_path:match("([^\\/]+)$") or full_path
    exe_name = (exe_name:gsub("%.[Ee][Xx][Ee]$", ""))
    exe_cache_pid, exe_cache_name, exe_cache_path = pid[0], exe_name, full_path

    return { exe_name = exe_name, exe_path = full_path, window_title = window_title, is_fullscreen = fullscreen }
end

