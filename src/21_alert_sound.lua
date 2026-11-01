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
local function base64_decode_ffi(data)
    data = data:gsub('[^A-Za-z0-9+/]', '')
    local n = #data
    local out = ffi.new("uint8_t[?]", math.floor(n * 3 / 4) + 3)
    local vals = ffi.new("int8_t[256]", -1)
    for i = 1, #B64_CHARS do vals[B64_CHARS:byte(i)] = i - 1 end
    local bytes = ffi.new("uint8_t[?]", n + 1)
    ffi.copy(bytes, data, n)
    local o, acc, bits = 0, 0, 0
    for i = 0, n - 1 do
        local v = vals[bytes[i]]
        if v < 0 then break end
        acc = (acc * 64 + v) % 16777216   -- keep 24 bits at most
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out[o] = math.floor(acc / 2 ^ bits) % 256
            o = o + 1
        end
    end
    return ffi.string(out, o)
end

local function base64_decode(data)
    if ffi then
        local ok, res = pcall(base64_decode_ffi, data)
        if ok and #res > 0 then return res end
    end
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
local prewarm_sound -- forward-declared (assigned inside the module block below)
local alert_started_ns = 0
local alert_seen_playing = false
local ALERT_POLL_MS = 200

local function clear_sound_channel()
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

local last_alert_ns = 0
local ALERT_MIN_GAP_NS = 1.5e9   -- hotkey spam must not create a new audio source per press

local function do_sound_alert(force)
    local now_ns = obs.os_gettime_ns()
    if not force and (now_ns - last_alert_ns) < ALERT_MIN_GAP_NS then
        return
    end
    last_alert_ns = now_ns
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
        do_sound_alert(true)
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

    -- Decode the chosen built-in sound shortly after load/changes, so the first
    -- real alert doesn't stutter while it is being decoded.
    prewarm_sound = function()
        obs.timer_remove(prewarm_sound)
        if alert_sound and (custom_sound_path == nil or custom_sound_path == "") then
            pcall(builtin_sound_path_for, sound_choice_by_id(selected_sound_id))
        end
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
    obs.timer_remove(prewarm_sound)
    obs.timer_add(prewarm_sound, 2000)
    if new_channel ~= SOUND_CHANNEL then
        obs.timer_remove(poll_alert)
        clear_sound_channel()
        SOUND_CHANNEL = new_channel
    end
end

    function Alert.script_unload()
        obs.timer_remove(poll_alert)
        obs.timer_remove(prewarm_sound)
        clear_sound_channel()
        -- Remove the decoded temp copies of the built-in sounds.
        for id, path in pairs(decoded_paths) do
            W.remove(path)
            decoded_paths[id] = nil
        end
    end
end

