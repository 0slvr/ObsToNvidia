----------------------------------------------------------------------
-- Clip Saved Notification (optional, OFF by default; a checkbox inside
-- the "3) Clip Alert Sound" group)
-- Shows a normal Windows toast ("Clip saved" + file name) when a clip is
-- saved. No module to install: it runs the PowerShell that ships with
-- Windows once, hidden, per notification. It never touches OBS, the clip,
-- the Replay Buffer or any other module, and any failure is swallowed.
----------------------------------------------------------------------
local Toast = {}
do
    local enabled = false

    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function base64(s)
        local out, n = {}, #s
        for i = 1, n, 3 do
            local a, b, c = s:byte(i, i + 2)
            local v = a * 65536 + (b or 0) * 256 + (c or 0)
            local c1 = math.floor(v / 262144) % 64
            local c2 = math.floor(v / 4096) % 64
            local c3 = math.floor(v / 64) % 64
            local c4 = v % 64
            out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1) ..
                (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
        end
        return table.concat(out)
    end

    -- Text that is safe inside a PowerShell single-quoted string.
    local function ps_quote(text)
        text = tostring(text or ""):gsub("[%c]", " "):gsub("'", "''")
        return text
    end

    -- Name of the clip OBS just saved ("" if OBS can't tell).
    local function saved_clip_name()
        local rb = obs.obs_frontend_get_replay_buffer_output()
        if rb == nil then return "" end
        local cd = obs.calldata_create()
        obs.proc_handler_call(obs.obs_output_get_proc_handler(rb), "get_last_replay", cd)
        local path = obs.calldata_string(cd, "path")
        obs.calldata_destroy(cd)
        obs.obs_output_release(rb)
        if path == nil or path == "" then return "" end
        return (path:match("([^\\/]+)$")) or ""
    end

    local function show_toast(title, body)
        if not sorter_available then return false end
        local ps = "[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];" ..
            "$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(1);" ..
            "$t=$x.GetElementsByTagName('text');" ..
            "[void]$t.Item(0).AppendChild($x.CreateTextNode('" .. ps_quote(title) .. "'));" ..
            "[void]$t.Item(1).AppendChild($x.CreateTextNode('" .. ps_quote(body) .. "'));" ..
            "$n=[Windows.UI.Notifications.ToastNotification]::new($x);" ..
            "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(" ..
            "'{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe').Show($n)"
        local wide = utf8_to_wide(ps)
        if wide == nil then return false end
        local n = 0
        while wide[n] ~= 0 do n = n + 1 end
        local encoded = base64(ffi.string(wide, n * 2)) -- UTF-16LE, what -EncodedCommand expects
        local args = utf8_to_wide("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand " .. encoded)
        local exe = utf8_to_wide("powershell.exe")
        if args == nil or exe == nil then return false end
        local r = shell32.ShellExecuteW(nil, nil, exe, args, nil, 0) -- 0 = SW_HIDE
        return tonumber(ffi.cast("intptr_t", r)) > 32
    end

    function Toast.on_replay_saved()
        if not enabled then return end
        local ok, err = pcall(function()
            local name = saved_clip_name()
            show_toast("Clip saved", name ~= "" and name or "Replay Buffer clip saved")
        end)
        if not ok then
            obs.script_log(obs.LOG_WARNING, "Clip Notification: couldn't show the notification: " .. tostring(err))
        end
    end

    -- Ticking the box shows one test notification (no separate test button,
    -- to keep the window short). Unticking shows nothing.
    local function toggled(props, property, settings)
        if obs.obs_data_get_bool(settings, "clip_toast") then
            pcall(show_toast, "Clip saved", "Notifications are on")
        end
        return false
    end

    function Toast.script_properties(props)
        -- Lives inside the "3) Clip Alert Sound" group (see 90_main.lua), so it
        -- only fires while that group is switched on.
        local p = obs.obs_properties_add_bool(props, "clip_toast",
            "Also show a Windows notification when a clip is saved")
        obs.obs_property_set_modified_callback(p, toggled)
    end

    function Toast.script_defaults(settings)
        obs.obs_data_set_default_bool(settings, "clip_toast", false)
    end

    function Toast.script_update(settings)
        enabled = obs.obs_data_get_bool(settings, "clip_toast") and
            obs.obs_data_get_bool(settings, "alert_sound")
    end
end

