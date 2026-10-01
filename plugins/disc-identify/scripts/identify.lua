-- Lumen plugin "disc-identify": names the disc you insert.
--
--   Audio CD      MusicBrainz lookup by disc ID (computed by Lumen from the table of
--                 contents): album, artist, year, track names, cover (Cover Art Archive)
--   DVD/Blu-ray,  the volume label is tidied up ("THE_MATRIX_D1" -> "The Matrix") and
--   Video CD      looked up on Wikidata: film/series title and year
--
-- Needs Lumen 0.2.1 or newer. Lumen sends the script-message "lumen-event" for player
-- events and performs HTTP requests for scripts ("lumen-plugin" "http"), so no external
-- tools are required. Nothing is looked up until a disc is scanned; what is sent is the
-- disc ID / table of contents (audio CD) or the tidied disc label (video discs).
local utils = require "mp.utils"
local msg = require "mp.msg"

local PLUGIN = "disc-identify"
-- Endpoints (the environment variables exist for tests against a local server)
local MUSICBRAINZ = os.getenv("LUMEN_DISCID_MUSICBRAINZ") or "https://musicbrainz.org"
local COVERART = os.getenv("LUMEN_DISCID_COVERART") or "https://coverartarchive.org"
local WIKIDATA = os.getenv("LUMEN_DISCID_WIKIDATA") or "https://www.wikidata.org"

local generation = 0 -- a newer disc cancels answers that are still on their way
local requests = 0
local cache = {}     -- lookup key -> info, for re-scans of the same disc

local function status(text)
    mp.commandv("script-message", "lumen-plugin", "status", PLUGIN, text)
end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- HTTP GET through Lumen; cb(status, body). status 0 = network error (body = message)
local function http_get(url, cb)
    requests = requests + 1
    local name = PLUGIN .. "-http-" .. requests
    mp.register_script_message(name, function(code, body)
        mp.unregister_script_message(name)
        cb(tonumber(code) or 0, body or "")
    end)
    mp.commandv("script-message", "lumen-plugin", "http", name, url, '{"Accept":"application/json"}')
end

local function publish(disc, info)
    info.device = disc.device
    mp.commandv("script-message", "lumen-plugin", "disc-info", utils.format_json(info))
    local line = info.title or ""
    if info.artist and info.artist ~= "" then line = info.artist .. " – " .. line end
    status(line .. " (" .. (info.source or "?") .. ")")
end

-- ------------------------------------------------------------------ audio CD

local function credit(list)
    local s = ""
    for _, a in ipairs(list or {}) do
        s = s .. (a.name or "") .. (a.joinphrase or "")
    end
    return s
end

-- The release and the medium (disc of a set) that belong to this CD
local function pick_release(releases, disc_id, track_count)
    local fallback
    for _, r in ipairs(releases or {}) do
        for _, m in ipairs(r.media or {}) do
            for _, d in ipairs(m.discs or {}) do
                if d.id == disc_id then return r, m end
            end
            if not fallback and (m["track-count"] == track_count or #(m.tracks or {}) == track_count) then
                fallback = { r, m }
            end
        end
    end
    if fallback then return fallback[1], fallback[2] end
    local r = releases and releases[1]
    return r, r and r.media and r.media[1]
end

local function lookup_cd(disc, gen)
    local id = disc.mbDiscId
    local toc = disc.toc or {}
    local offsets = toc.offsets or {}
    local key = "cd:" .. id
    if cache[key] then publish(disc, cache[key]) return end

    local url = MUSICBRAINZ .. "/ws/2/discid/" .. urlencode(id) .. "?fmt=json&cdstubs=no&inc=artist-credits+recordings"
    if toc.first and toc.last and toc.leadout and #offsets > 0 then
        -- with the table of contents MusicBrainz falls back to a fuzzy match for unknown IDs
        local parts = { toc.first, toc.last, toc.leadout }
        for _, o in ipairs(offsets) do parts[#parts + 1] = o end
        for i, v in ipairs(parts) do parts[i] = string.format("%d", v) end
        url = url .. "&toc=" .. table.concat(parts, "+")
    end
    status("Looking up the CD on MusicBrainz …")
    http_get(url, function(code, body)
        if gen ~= generation then return end
        if code == 404 then status("CD not found on MusicBrainz") return end
        if code ~= 200 then status("MusicBrainz: " .. (code == 0 and body or ("HTTP " .. code))) return end
        local data = utils.parse_json(body)
        if type(data) ~= "table" then status("MusicBrainz: unreadable answer") return end
        local release, medium = pick_release(data.releases, id, #offsets)
        if not release then status("CD not found on MusicBrainz") return end

        local info = {
            title = release.title,
            artist = credit(release["artist-credit"]),
            year = (release.date or ""):match("^(%d%d%d%d)") or "",
            source = "MusicBrainz",
            tracks = {},
        }
        for _, t in ipairs(medium and medium.tracks or {}) do
            info.tracks[#info.tracks + 1] = { title = t.title or "", artist = credit(t["artist-credit"]) }
        end
        if #info.tracks == 0 then info.tracks = nil end
        local art = release["cover-art-archive"]
        if art and art.front and release.id then
            info.cover = COVERART .. "/release/" .. release.id .. "/front-250"
        end
        cache[key] = info
        publish(disc, info)
    end)
end

-- ------------------------------------------------------------------ video discs

local GENERIC = {
    [""] = true, ["dvd"] = true, ["dvd video"] = true, ["dvdvideo"] = true, ["dvdvolume"] = true, ["video ts"] = true,
    ["bdrom"] = true, ["bdmv"] = true, ["blu ray"] = true, ["bluray"] = true, ["logical volume id"] = true,
    ["new"] = true, ["new volume"] = true, ["cdrom"] = true, ["disc"] = true, ["video"] = true, ["movie"] = true,
    ["untitled"] = true, ["unknown"] = true,
}
-- label words that describe the pressing, not the film
local NOISE = {
    "DISC%s*%d+", "DISK%s*%d+", "CD%s*%d+", "D%d+", "DVD%d*", "BD%d*", "BLURAY", "BLU RAY", "UHD", "4K",
    "WS", "FS", "16X9", "4X3", "NTSC", "PAL", "R%d", "REGION%s*%d", "UNRATED", "EXTENDED",
    "SPECIAL EDITION", "WIDESCREEN", "FULLSCREEN", "BONUS",
}

local function tidy_label(label)
    local s = " " .. tostring(label or ""):upper():gsub("[_%.%-]+", " "):gsub("%b<>", " "):gsub("%b[]", " ") .. " "
    local changed = true
    while changed do
        changed = false
        for _, pat in ipairs(NOISE) do
            local n
            s, n = s:gsub(" " .. pat .. " ", " ")
            if n > 0 then
                s = " " .. s:gsub("^%s+", ""):gsub("%s+$", "") .. " "
                changed = true
            end
        end
    end
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    -- Title Case
    s = s:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
    return s
end

local FILM_WORDS = { "film", "movie", "television series", "tv series", "miniseries", "anime", "animated",
                     "documentary", "television film", "serial", "sitcom", "concert" }

local function lookup_video(disc, gen)
    -- Blu-rays often carry a proper title in their metadata; otherwise the volume label
    local name = disc.discName
    if not name or name == "" then name = disc.volumeId end
    if not name or name == "" then name = disc.label end
    local proper = name and name:match("%l") ~= nil -- has lowercase letters: already a real title
    local query = proper and name or tidy_label(name)
    if GENERIC[query:lower()] or #query < 2 then
        status("The disc label says nothing about the content")
        return
    end
    local key = "video:" .. query
    if cache[key] then publish(disc, cache[key]) return end

    local url = WIKIDATA .. "/w/api.php?action=wbsearchentities&format=json&language=en&uselang=en&type=item&limit=10&search="
                .. urlencode(query)
    status("Looking up “" .. query .. "” on Wikidata …")
    http_get(url, function(code, body)
        if gen ~= generation then return end
        local info = { title = query, source = "Disc label" }
        local data = code == 200 and utils.parse_json(body) or nil
        if type(data) == "table" then
            for _, hit in ipairs(data.search or {}) do
                local d = (hit.description or ""):lower()
                local is_film = false
                for _, w in ipairs(FILM_WORDS) do
                    if d:find(w, 1, true) then is_film = true break end
                end
                if is_film then
                    info = {
                        title = hit.label or query,
                        year = (hit.description or ""):match("(%d%d%d%d)") or "",
                        overview = hit.description or "",
                        source = "Wikidata",
                    }
                    break
                end
            end
        end
        cache[key] = info
        publish(disc, info)
    end)
end

-- ------------------------------------------------------------------ events

mp.register_script_message("lumen-event", function(event, json)
    if event ~= "disc" then return end
    local disc = utils.parse_json(json or "")
    if type(disc) ~= "table" then return end
    generation = generation + 1
    local kind = disc.kind or ""
    if kind == "cdda" then
        if disc.mbDiscId and disc.mbDiscId ~= "" then
            lookup_cd(disc, generation)
        else
            status("No table of contents for this CD (needs a drive or an image, not a folder)")
        end
    elseif kind == "dvd" or kind == "bluray" or kind == "hddvd" or kind == "vcd" or kind == "svcd" then
        lookup_video(disc, generation)
    end
end)

status("Ready – waiting for a disc")
-- a disc that was scanned before this script started: ask Lumen to repeat the event
mp.commandv("script-message", "lumen-plugin", "ready")
msg.verbose("disc-identify loaded")
