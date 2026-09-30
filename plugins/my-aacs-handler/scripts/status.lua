-- My AACS Plugin – on-screen notice when a Blu-ray starts.
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

-- for tests/diagnostics: script is running
mp.set_property("user-data/my-aacs-handler/loaded", "yes")
