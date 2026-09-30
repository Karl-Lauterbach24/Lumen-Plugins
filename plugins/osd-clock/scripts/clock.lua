-- Lumen-Plugin "osd-clock": Uhrzeit, Restlaufzeit und Ende einblenden (Strg+T)
local function fmt(seconds)
    seconds = math.floor(seconds + 0.5)
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

local function show()
    local left = mp.get_property_number("time-remaining")
    local speed = mp.get_property_number("speed", 1)
    local text = os.date("%H:%M")
    if left then
        text = text .. "   –" .. fmt(left) .. "   Ende " .. os.date("%H:%M", os.time() + math.floor(left / speed))
    end
    mp.osd_message(text, 3)
end

mp.add_key_binding("Ctrl+t", "show-clock", show)
-- Für Tests/Diagnose: Skript ist geladen
mp.set_property("user-data/osd-clock/loaded", "yes")
