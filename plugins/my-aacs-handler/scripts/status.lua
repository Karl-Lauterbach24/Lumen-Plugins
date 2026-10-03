-- My AACS Plugin – on-screen notice when a Blu-ray starts, and a KEYDB.cfg
-- dropped onto the Lumen window.
-- mpv scripting API: https://mpv.io/manual/master/#lua-scripting

local function is_bluray(path)
    return path:find("^lumenbd://") or path:find("^bd://") or path:find("^bluray://")
end

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    if is_bluray(path) then
        print("Lumen: Blu-ray source detected")
        local title = mp.get_property("media-title", "")
        mp.commandv("show-text", "Blu-ray" .. (title ~= "" and (": " .. title) or ""), "2500")
    end
end)

-- A file dropped onto the window arrives as "play this file". A key database is
-- nothing to play: the native part installs it (aacskeydb://<path>), leaves the
-- result in a property and answers with an empty playlist, so the load ends
-- without an error message.
local RESULT = "user-data/my-aacs-handler/keydb"
local dropped = false

local function is_keydb(path)
    local name = path:match("[^/\\]*$"):lower()
    return name:find("^keydb.*%.cfg$") ~= nil
end

mp.add_hook("on_load", 10, function()
    local path = mp.get_property("stream-open-filename", "")
    dropped = not path:find("^%a[%w+.-]*://") and is_keydb(path)
    if dropped then
        mp.set_property(RESULT, "")
        mp.set_property("stream-open-filename", "aacskeydb://" .. path)
    end
end)

mp.add_hook("on_unload", 10, function()
    if not dropped then
        return
    end
    dropped = false
    -- nothing follows the key database, whatever the playlist options say
    mp.command("stop")
    local result = mp.get_property_native(RESULT, "")
    if result == "" then
        result = "KEYDB.cfg not installed: the native part of My AACS Plugin is not running"
    end
    print(result)
    mp.osd_message(result, 6)
end)

-- for tests/diagnostics: script is running
mp.set_property("user-data/my-aacs-handler/loaded", "yes")
