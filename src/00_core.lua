--[[
OBS Clip Suite -- one Tools > Scripts entry (add this single file).
On every Replay Buffer save, in this order: Replay Organizer (per-game folder,
Windows only) -> Clip Alert Sound (off by default) -> Restarter (stops + starts
the buffer so clips don't overlap). The Update Checker updates this script from
GitHub Releases. Each module has its own group and on/off checkbox.
--]]

-- Bump on every GitHub Release (compared numerically: 1.10.0 > 1.9.0).
local VERSION = "2.18"

obs = obslua

-- Constants shared by all parts live in ONE table (a single chunk-level local):
-- LuaJIT allows at most 200 locals per function and this file was near the limit.
local C = {}

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

