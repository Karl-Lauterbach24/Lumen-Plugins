-- Lumen plugin "auto-rip": copies the main feature or the episodes of each disc you insert to MKV
-- files with MakeMKV, names and files them the way Jellyfin, Plex, Emby and Kodi expect, ejects the
-- disc and goes on with the next one.
--
-- Nothing happens until you press "Start auto rip" in the plugin's entry (Plugins tab): until then
-- Lumen plays discs as usual. While auto rip runs, Lumen leaves the drive alone.
--
-- Needs Lumen 1.4 or newer and MakeMKV (https://www.makemkv.com). The plugin contains no decryption
-- code: it starts the makemkvcon program of your MakeMKV installation. Copy only discs you own, and
-- only where the law lets you.
local utils = require "mp.utils"
local msg = require "mp.msg"

local PLUGIN = "auto-rip"
local platform = mp.get_property("platform") or ""
local WINDOWS = platform == "windows"
local MAC = platform == "darwin"
local SEP = WINDOWS and "\\" or "/"
local WIKIDATA = os.getenv("LUMEN_AUTORIP_WIKIDATA") or "https://www.wikidata.org"

local plugin_dir, config_dir
local settings = {}
local armed = false        -- "Start auto rip" was pressed
local job = nil            -- the disc being copied
local last_disc = nil      -- label of the disc copied last: not again until it has left the drive
local poll_timer, settle_timer
local requests = 0

-- ------------------------------------------------------------------ small helpers

local function status(text)
    mp.commandv("script-message", "lumen-plugin", "status", PLUGIN, text)
    msg.info(text)
end

local function action(id, label)
    mp.commandv("script-message", "lumen-plugin", "action", PLUGIN, id, label)
end

local function join(a, b)
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
    return a .. SEP .. b
end

local function exists(path)
    return utils.file_info(path) ~= nil
end

local function is_dir(path)
    local i = utils.file_info(path)
    return i ~= nil and i.is_dir
end

local function env(name)
    return os.getenv(name) or ""
end

local function home()
    return WINDOWS and env("USERPROFILE") or env("HOME")
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- one argument for /bin/sh
local function sh(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run(args, cb)
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false, capture_stdout = true,
                              capture_stderr = true, capture_size = 64 * 1024 * 1024 },
                            function(ok, res, err)
        if cb then cb(ok and res or nil, err) end
    end)
end

local function mkdirs(path)
    if is_dir(path) then return true end
    local res
    if WINDOWS then
        res = mp.command_native({ name = "subprocess", args = { "cmd.exe", "/c", "mkdir", path }, playback_only = false,
                                  capture_stdout = true, capture_stderr = true })
    else
        res = mp.command_native({ name = "subprocess", args = { "/bin/mkdir", "-p", path }, playback_only = false,
                                  capture_stdout = true, capture_stderr = true })
    end
    return is_dir(path), res
end

local function write_file(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- the end of a file that grows
local function read_tail(path, bytes)
    local f = io.open(path, "rb")
    if not f then return "" end
    local size = f:seek("end") or 0
    f:seek("set", math.max(0, size - bytes))
    local s = f:read("*a") or ""
    f:close()
    return s
end

local function http_get(url, cb)
    requests = requests + 1
    local name = PLUGIN .. "-http-" .. requests
    mp.register_script_message(name, function(code, body)
        mp.unregister_script_message(name)
        cb(tonumber(code) or 0, body or "")
    end)
    mp.commandv("script-message", "lumen-plugin", "http", name, url, '{"Accept":"application/json"}')
end

local function hms(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

-- ------------------------------------------------------------------ settings

local DEFAULTS = {
    { "output", "", "Folder for the copies. Empty: Movies/Lumen Rips (macOS), Videos/Lumen Rips (Windows, Linux)." },
    { "movies_folder", "Movies", "Sub-folder for films: <output>/Movies/Title (Year)/Title (Year).mkv" },
    { "shows_folder", "Shows", "Sub-folder for series: <output>/Shows/Series/Season 01/Series S01E01.mkv" },
    { "mode", "auto", "auto = decide per disc, movie = always the main feature, episodes = always all episodes" },
    { "min_length", "120", "Seconds. Shorter titles (logos, trailers) are never looked at." },
    { "episode_min", "15", "Minutes. Episodes of a series are at least this long …" },
    { "episode_max", "75", "… and at most this long." },
    { "eject", "yes", "Eject the disc when it is done, so the next one can go in." },
    { "lookup", "yes", "Look up title and year on Wikidata (sends the disc's name). no = name from the disc alone." },
    { "makemkvcon", "", "Path of the makemkvcon program. Empty: found by itself." },
}

local function default_output()
    if MAC then return join(join(home(), "Movies"), "Lumen Rips") end
    return join(join(home(), "Videos"), "Lumen Rips")
end

local function load_settings()
    for _, d in ipairs(DEFAULTS) do settings[d[1]] = d[2] end
    local file = join(config_dir, "settings.txt")
    local text = read_file(file)
    if not text then
        local out = { "# Auto rip – settings. Lines starting with # are comments. Restart Lumen after a change.", "" }
        for _, d in ipairs(DEFAULTS) do
            out[#out + 1] = "# " .. d[3]
            out[#out + 1] = d[1] .. " = " .. d[2]
            out[#out + 1] = ""
        end
        write_file(file, table.concat(out, "\n"))
        return
    end
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and not line:match("^%s*#") and settings[k] ~= nil then settings[k] = v end
    end
end

local function output_root()
    local o = settings.output
    if o == "" then return default_output() end
    if o:sub(1, 2) == "~/" or o:sub(1, 2) == "~\\" then o = join(home(), o:sub(3)) end
    return o
end

local function find_makemkvcon()
    local list = {}
    local function add(p) if p and p ~= "" then list[#list + 1] = p end end
    add(os.getenv("LUMEN_AUTORIP_MAKEMKVCON"))
    add(settings.makemkvcon)
    if MAC then
        add("/Applications/MakeMKV.app/Contents/MacOS/makemkvcon")
        add(join(home(), "Applications/MakeMKV.app/Contents/MacOS/makemkvcon"))
    elseif WINDOWS then
        for _, base in ipairs({ env("ProgramFiles(x86)"), env("ProgramFiles"), env("ProgramW6432") }) do
            if base ~= "" then
                add(base .. "\\MakeMKV\\makemkvcon64.exe")
                add(base .. "\\MakeMKV\\makemkvcon.exe")
            end
        end
    else
        -- built by My AACS Plugin into its settings folder, then the usual places
        add(join(config_dir, "../my-aacs-handler/makemkv/bin/makemkvcon"))
        for dir in (env("PATH") .. ":/usr/bin:/usr/local/bin"):gmatch("[^:]+") do add(join(dir, "makemkvcon")) end
    end
    for _, p in ipairs(list) do
        if exists(p) then return p end
    end
    return nil
end

-- ------------------------------------------------------------------ MakeMKV's robot output

-- "TINFO:0,9,0,\"1:58:03\"" -> "TINFO", {"0", "9", "0", "1:58:03"}
local function parse_line(line)
    local kind, rest = line:match("^(%u+):(.*)$")
    if not kind then return nil end
    local fields, cur, quoted, i = {}, {}, false, 1
    while i <= #rest do
        local c = rest:sub(i, i)
        if quoted then
            if c == "\\" and i < #rest then
                cur[#cur + 1] = rest:sub(i + 1, i + 1)
                i = i + 1
            elseif c == '"' then
                quoted = false
            else
                cur[#cur + 1] = c
            end
        elseif c == '"' then
            quoted = true
        elseif c == "," then
            fields[#fields + 1] = table.concat(cur)
            cur = {}
        else
            cur[#cur + 1] = c
        end
        i = i + 1
    end
    fields[#fields + 1] = table.concat(cur)
    return kind, fields
end

local function seconds_of(text)
    local h, m, s = tostring(text or ""):match("^(%d+):(%d+):(%d+)$")
    if not h then return 0 end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

-- drives: {index, state, name, label, device}; state 2 = a disc is in
local function parse_drives(text)
    local drives = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local kind, f = parse_line(line)
        if kind == "DRV" and f[5] and f[5] ~= "" then
            drives[#drives + 1] = { index = tonumber(f[1]), state = tonumber(f[2]), name = f[5], label = f[6] or "",
                                    device = f[7] or "" }
        end
    end
    return drives
end

-- disc: {name, label, kind, titles = {{id, name, chapters, duration, bytes, source, outfile, audio, subs, is3d, uhd}}}
local function parse_info(text)
    local disc = { name = "", label = "", kind = "", titles = {}, messages = {} }
    local by_id = {}
    local function title(id)
        if not by_id[id] then
            by_id[id] = { id = id, name = "", chapters = 0, duration = 0, bytes = 0, source = "", outfile = "", audio = 0,
                          subs = 0, is3d = false, uhd = false }
            disc.titles[#disc.titles + 1] = by_id[id]
        end
        return by_id[id]
    end
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local kind, f = parse_line(line)
        if kind == "CINFO" then
            local id, value = tonumber(f[1]), f[3] or ""
            if id == 1 then disc.kind = value
            elseif id == 2 then disc.name = value
            elseif id == 32 then disc.label = value
            elseif id == 30 and disc.name == "" then disc.name = value end
        elseif kind == "TINFO" then
            local t, id, value = title(tonumber(f[1])), tonumber(f[2]), f[4] or ""
            if id == 2 then t.name = value
            elseif id == 8 then t.chapters = tonumber(value) or 0
            elseif id == 9 then t.duration = seconds_of(value)
            elseif id == 11 then t.bytes = tonumber(value) or 0
            elseif id == 16 then t.source = value
            elseif id == 27 then t.outfile = value end
        elseif kind == "SINFO" then
            local t, id, value = title(tonumber(f[1])), tonumber(f[3]), f[5] or ""
            if id == 1 then
                if value == "Audio" then t.audio = t.audio + 1 elseif value == "Subtitles" then t.subs = t.subs + 1 end
            end
            if value:find("MVC", 1, true) then t.is3d = true end
            if id == 19 and value:match("^3840x") then t.uhd = true end
        elseif kind == "MSG" then
            disc.messages[#disc.messages + 1] = f[4] or ""
        end
    end
    table.sort(disc.titles, function(a, b) return a.id < b.id end)
    return disc
end

-- ------------------------------------------------------------------ what to copy

local function median(list)
    local s = {}
    for _, v in ipairs(list) do s[#s + 1] = v end
    table.sort(s)
    if #s == 0 then return 0 end
    return s[math.floor((#s + 1) / 2)]
end

-- season and disc number from a label such as "CLASS_S1_D1", "THE WIRE SEASON 2 DISC 3"
local function season_of(label)
    local u = " " .. tostring(label or ""):upper():gsub("[_%.%-]+", " ") .. " "
    local season = u:match(" SEASON%s*(%d+)") or u:match(" STAFFEL%s*(%d+)") or u:match(" SERIES%s*(%d+)")
                   or u:match(" S(%d+)%s*D%d") or u:match(" S(%d+) ") or u:match(" S(%d+)E%d")
    local disc = u:match(" DIS[CK]%s*(%d+)") or u:match(" S%d+%s*D(%d+)") or u:match(" D(%d+) ")
    return tonumber(season), tonumber(disc)
end

-- titles to copy: {mode = "movie" | "episodes", titles = {...}}
local function choose(disc)
    local list = {}
    for _, t in ipairs(disc.titles) do
        if t.duration >= (tonumber(settings.min_length) or 120) then list[#list + 1] = t end
    end
    if #list == 0 then return nil end

    local lo, hi = (tonumber(settings.episode_min) or 15) * 60, (tonumber(settings.episode_max) or 75) * 60
    local eps, longest = {}, list[1]
    for _, t in ipairs(list) do
        if t.duration > longest.duration then longest = t end
        if t.duration >= lo and t.duration <= hi then eps[#eps + 1] = t end
    end
    -- episodes are about equally long; one title that is as long as all of them together is "play all"
    local durations = {}
    for _, t in ipairs(eps) do durations[#durations + 1] = t.duration end
    local med = median(durations)
    local similar = {}
    for _, t in ipairs(eps) do
        if math.abs(t.duration - med) <= med * 0.35 then similar[#similar + 1] = t end
    end
    -- the same playlist twice (another angle, another language menu): keep the first of each source
    local seen, unique = {}, {}
    for _, t in ipairs(similar) do
        local key = t.source ~= "" and (t.source .. "/" .. t.duration) or tostring(t.id)
        if not seen[key] then
            seen[key] = true
            unique[#unique + 1] = t
        end
    end
    local season = season_of(disc.label ~= "" and disc.label or disc.name)
    local series = #unique >= 3 or (#unique >= 2 and season ~= nil)
    if settings.mode == "episodes" then series = #unique >= 1 end
    if settings.mode == "movie" then series = false end
    -- a film with a long bonus feature is still a film
    if series and settings.mode ~= "episodes" and longest.duration > hi and longest.duration < med * (#unique - 0.5) then
        series = false
    end
    if series then
        table.sort(unique, function(a, b)
            if a.source ~= b.source then return a.source < b.source end
            return a.id < b.id
        end)
        return { mode = "episodes", titles = unique }
    end

    -- the main feature: the longest title; of several equally long ones the one with the most sound
    -- tracks and subtitles, then the lowest playlist number
    local best = longest
    for _, t in ipairs(list) do
        if t ~= best and math.abs(t.duration - longest.duration) <= math.max(2, longest.duration * 0.01) then
            local a, b = t.audio + t.subs, best.audio + best.subs
            if a > b or (a == b and t.source ~= "" and (best.source == "" or t.source < best.source)) then best = t end
        end
    end
    return { mode = "movie", titles = { best } }
end

-- ------------------------------------------------------------------ names

local NOISE = {
    "DISC%s*%d+", "DISK%s*%d+", "CD%s*%d+", "D%d+", "DVD%d*", "BD%d*", "BLURAY", "BLU RAY", "UHD", "4K", "3D",
    "WS", "FS", "16X9", "4X3", "NTSC", "PAL", "R%d", "REGION%s*%d", "UNRATED", "EXTENDED",
    "SPECIAL EDITION", "WIDESCREEN", "FULLSCREEN", "BONUS", "SEASON%s*%d+", "STAFFEL%s*%d+", "S%d+", "S%d+%s*D%d+",
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
                s = " " .. trim(s) .. " "
                changed = true
            end
        end
    end
    s = trim(s:gsub("%s+", " "))
    return (s:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- a name every file system takes
local function safe_name(name)
    local s = tostring(name or ""):gsub("%s*:%s*", " - "):gsub('[<>:"/\\|%?%*%c]', " "):gsub("%s+", " ")
    s = trim(s):gsub("[%. ]+$", "")
    if s == "" then s = "Disc" end
    return s
end

local FILM_WORDS = { "film", "movie", "anime", "animated", "documentary", "concert" }
local SERIES_WORDS = { "television series", "tv series", "miniseries", "serial", "sitcom", "anime", "web series",
                       "television program", "tv program", "drama" }

-- cb({title, year}); never fails: without an answer the name from the disc stands.
-- series: the disc holds episodes, so a series of that name is wanted, not a film (and the other way round)
local function identify(disc, series, cb)
    local name = disc.name
    local proper = name ~= "" and name:match("%l") ~= nil -- lower case letters: a real title, not a volume label
    local query = proper and name or tidy_label(disc.label ~= "" and disc.label or name)
    if proper then
        -- "Class: Season 1 Disc 1" -> "Class"
        query = trim(query:gsub("[%s:,%-]*[Ss]eason%s*%d+.*$", ""):gsub("[%s:,%-]*[Dd]is[ck]%s*%d+.*$", ""))
    end
    if query == "" then query = "Disc" end
    local result = { title = query, year = "" }
    if settings.lookup ~= "yes" or #query < 2 then
        cb(result)
        return
    end
    local url = WIKIDATA .. "/w/api.php?action=wbsearchentities&format=json&language=en&uselang=en&type=item&limit=10&search="
                .. urlencode(query)
    http_get(url, function(code, body)
        local data = code == 200 and utils.parse_json(body) or nil
        if type(data) == "table" then
            for _, hit in ipairs(data.search or {}) do
                local d = (hit.description or ""):lower()
                local is_series = false
                for _, w in ipairs(SERIES_WORDS) do
                    if d:find(w, 1, true) then is_series = true break end
                end
                local is_film = false
                for _, w in ipairs(FILM_WORDS) do
                    if d:find(w, 1, true) then is_film = true break end
                end
                -- a wrong year is worse than none: only take a hit of the right kind
                if (series and is_series) or (not series and is_film and not d:find("series", 1, true)) then
                    result = { title = hit.label or query, year = (hit.description or ""):match("(%d%d%d%d)") or "" }
                    break
                end
            end
        end
        cb(result)
    end)
end

-- which episode numbers a disc of a series gets: the next free ones, and the same again when the
-- same disc comes back
local function episode_numbers(series, season, label, count)
    local file = join(config_dir, "series.json")
    local data = utils.parse_json(read_file(file) or "") or {}
    local key = series:lower() .. "|" .. season
    local entry = data[key] or { next = 1, discs = {} }
    entry.discs = entry.discs or {}
    local first = entry.discs[label]
    if not first then
        first = entry.next or 1
        entry.discs[label] = first
        entry.next = first + count
    end
    data[key] = entry
    write_file(file, utils.format_json(data))
    return first
end

-- free name: "Film (2019).mkv", then "Film (2019) (2).mkv"
local function free_path(dir, base)
    local path, n = join(dir, base .. ".mkv"), 1
    while exists(path) do
        n = n + 1
        path = join(dir, base .. " (" .. n .. ").mkv")
    end
    return path
end

-- where each chosen title goes
local function plan_targets(disc, plan, id)
    local root = output_root()
    local targets = {}
    local label = disc.label ~= "" and disc.label or disc.name
    if plan.mode == "episodes" then
        local season, disc_no = season_of(label)
        season = season or 1
        local series = safe_name(id.title)
        local show = id.year ~= "" and (series .. " (" .. id.year .. ")") or series
        local dir = join(join(join(root, settings.shows_folder), show), string.format("Season %02d", season))
        local first = episode_numbers(series, season, label, #plan.titles)
        for i, t in ipairs(plan.titles) do
            targets[#targets + 1] = { title = t, dir = dir,
                                      base = string.format("%s S%02dE%02d", series, season, first + i - 1) }
        end
        return targets, string.format("%s, season %d%s, %d episodes", series, season,
                                      disc_no and (", disc " .. disc_no) or "", #plan.titles)
    end
    local t = plan.titles[1]
    local film = safe_name(id.title)
    if id.year ~= "" then film = film .. " (" .. id.year .. ")" end
    -- several versions of a film side by side: "Film (2019) - 4K.mkv" next to "Film (2019).mkv"
    local version = t.uhd and " - 4K" or (t.is3d and " - 3D" or "")
    targets[1] = { title = t, dir = join(join(root, settings.movies_folder), film), base = film .. version }
    return targets, film .. version
end

-- ------------------------------------------------------------------ copying

local toggle_label

local function release()
    if poll_timer then poll_timer:kill() poll_timer = nil end
    if settle_timer then settle_timer:kill() settle_timer = nil end
    job = nil
end

local function disarm(text)
    release()
    armed = false
    mp.commandv("script-message", "lumen-plugin", "hold-discs", PLUGIN, "0")
    toggle_label()
    status(text or "Stopped – Lumen plays discs again")
end

local look_for_disc

local function wait_for_disc(text)
    release()
    status(text or "Waiting for the next disc – insert one and close the drive")
end

-- the job's working folder: script, log, process id; a failed copy leaves its partial file there
local function clean_up(j)
    if not j or not j.tmp then return end
    for _, name in ipairs({ "rip.sh", "rip.cmd", "makemkv.log", "makemkv.pid" }) do os.remove(join(j.tmp, name)) end
    for _, name in ipairs(utils.readdir(j.tmp, "dirs") or {}) do
        for _, file in ipairs(utils.readdir(join(j.tmp, name), "files") or {}) do os.remove(join(join(j.tmp, name), file)) end
        os.remove(join(j.tmp, name))
    end
    os.remove(j.tmp)
    os.remove(join(output_root(), ".auto-rip"))
end

local function finish_disc(ok, text)
    local device = job and job.drive and job.drive.device or ""
    last_disc = job and job.drive and job.drive.label or nil
    clean_up(job)
    release()
    if ok and settings.eject == "yes" and device ~= "" then
        mp.commandv("script-message", "lumen-plugin", "eject", device)
        last_disc = nil
    end
    if armed then
        wait_for_disc(text .. (ok and " – insert the next disc" or ""))
    end
end

-- makemkvcon runs on its own (it outlives a restart of the player's video engine) and writes its
-- progress to a file that a timer reads
local function start_title(n)
    local target = job.targets[n]
    if not target then
        finish_disc(true, string.format("Done: %s (%d file%s)", job.summary, #job.done, #job.done == 1 and "" or "s"))
        return
    end
    local tmp = join(job.tmp, "t" .. target.title.id)
    mkdirs(tmp)
    local log, pid = join(job.tmp, "makemkv.log"), join(job.tmp, "makemkv.pid")
    os.remove(log)
    os.remove(pid)
    local min = tostring(tonumber(settings.min_length) or 120)
    local script
    if WINDOWS then
        script = join(job.tmp, "rip.cmd")
        write_file(script, table.concat({
            "@echo off", "chcp 65001 > nul",
            string.format('"%s" -r --progress=-same --minlength=%s mkv disc:%d %d "%s" > "%s" 2>&1', job.makemkvcon, min,
                          job.drive.index, target.title.id, tmp, log),
            string.format('echo EXIT:%%ERRORLEVEL%%>> "%s"', log), "" }, "\r\n"))
        mp.command_native_async({ name = "subprocess", args = { "cmd.exe", "/c", script }, playback_only = false,
                                  detach = true }, function() end)
    else
        script = join(job.tmp, "rip.sh")
        write_file(script, table.concat({
            "#!/bin/sh",
            string.format("%s -r --progress=-same --minlength=%s mkv disc:%d %d %s > %s 2>&1 &", sh(job.makemkvcon), min,
                          job.drive.index, target.title.id, sh(tmp), sh(log)),
            string.format("echo $! > %s", sh(pid)), "wait $!", string.format('echo "EXIT:$?" >> %s', sh(log)), "" }, "\n"))
        mp.command_native_async({ name = "subprocess", args = { "/bin/sh", script }, playback_only = false,
                                  detach = true }, function() end)
    end
    job.pidfile = pid
    local started = mp.get_time()
    local prefix = #job.targets > 1 and string.format("%d/%d ", n, #job.targets) or ""

    poll_timer = mp.add_periodic_timer(1, function()
        local tail = read_tail(log, 8192)
        local exit = tail:match("EXIT:(%-?%d+)")
        if not exit then
            local cur, total, max
            for a, b, c in tail:gmatch("PRGV:(%d+),(%d+),(%d+)") do cur, total, max = a, b, c end
            if total and tonumber(max) and tonumber(max) > 0 then
                local part = tonumber(total) / tonumber(max)
                local left = ""
                if part > 0.02 then left = " · " .. hms((mp.get_time() - started) * (1 - part) / part) .. " left" end
                status(string.format("Copying %s%s – %d %%%s", prefix, target.base, math.floor(part * 100), left))
            else
                status(string.format("Copying %s%s – opening the disc …", prefix, target.base))
            end
            return
        end
        poll_timer:kill()
        poll_timer = nil
        -- the finished file: the only .mkv in the title's folder
        local file
        for _, name in ipairs(utils.readdir(tmp, "files") or {}) do
            if name:lower():match("%.mkv$") then file = join(tmp, name) end
        end
        if tonumber(exit) ~= 0 or not file then
            local why = ""
            for line in read_tail(log, 65536):gmatch("[^\r\n]+") do
                local kind, f = parse_line(line)
                if kind == "MSG" and f[4] and not f[4]:match("^DEBUG") then why = f[4] end
            end
            finish_disc(false, "Copying " .. target.base .. " failed: " .. (why ~= "" and why or ("makemkvcon ended with " .. exit)))
            return
        end
        mkdirs(target.dir)
        local final = free_path(target.dir, target.base)
        local moved, err = os.rename(file, final)
        if not moved then
            finish_disc(false, "Copied, but could not move the file to " .. final .. ": " .. tostring(err))
            return
        end
        os.remove(tmp)
        job.done[#job.done + 1] = final
        msg.info("saved " .. final)
        start_title(n + 1)
    end)
end

local function copy_disc(makemkvcon, drive)
    job = { makemkvcon = makemkvcon, drive = drive, done = {} }
    status("Reading “" .. (drive.label ~= "" and drive.label or drive.name) .. "” …")
    run({ makemkvcon, "-r", "--minlength=" .. tostring(tonumber(settings.min_length) or 120), "info", "disc:" .. drive.index },
        function(res)
        if not armed or not job or job.drive ~= drive then return end
        local disc = parse_info(res and res.stdout or "")
        if #disc.titles == 0 then
            local why = disc.messages[#disc.messages] or "no answer from makemkvcon"
            for i = #disc.messages, 1, -1 do
                if not disc.messages[i]:match("^DEBUG") then why = disc.messages[i] break end
            end
            finish_disc(false, "Nothing to copy on this disc: " .. why)
            return
        end
        if disc.label == "" then disc.label = drive.label end
        local plan = choose(disc)
        if not plan then
            finish_disc(false, "Nothing to copy on this disc: no title is longer than " .. settings.min_length .. " seconds")
            return
        end
        status("Looking up “" .. (disc.name ~= "" and disc.name or disc.label) .. "” …")
        identify(disc, plan.mode == "episodes", function(id)
            if not armed or not job or job.drive ~= drive then return end
            local root = output_root()
            job.tmp = join(join(root, ".auto-rip"), tostring(os.time()))
            if not mkdirs(job.tmp) then
                disarm("Cannot write to " .. root .. " – set another folder in settings.txt (button Settings)")
                return
            end
            job.targets, job.summary = plan_targets(disc, plan, id)
            start_title(1)
        end)
    end)
end

look_for_disc = function()
    if not armed or job then return end
    local makemkvcon = find_makemkvcon()
    if not makemkvcon then
        disarm("MakeMKV not found – install it (My AACS Plugin has a button for that) and start again")
        return
    end
    status("Looking for a disc …")
    run({ makemkvcon, "-r", "--cache=1", "info", "disc:9999" }, function(res)
        if not armed or job then return end
        local drives = parse_drives(res and res.stdout or "")
        if #drives == 0 then
            wait_for_disc("MakeMKV sees no drive – connect one, then insert a disc")
            return
        end
        for _, d in ipairs(drives) do
            if d.state == 2 and d.label ~= "" then
                if d.label == last_disc then
                    wait_for_disc("“" .. d.label .. "” is done – take it out and insert the next disc")
                else
                    copy_disc(makemkvcon, d)
                end
                return
            end
        end
        last_disc = nil
        wait_for_disc()
    end)
end

local function arm()
    if not find_makemkvcon() then
        status("MakeMKV not found – install it (My AACS Plugin has a button for that) and start again")
        return
    end
    local root = output_root()
    if not mkdirs(root) then
        status("Cannot create " .. root .. " – set another folder in settings.txt (button Settings)")
        return
    end
    armed = true
    last_disc = nil
    -- the drive is ours now: stop a disc that is playing, tell Lumen not to open discs
    mp.commandv("script-message", "lumen-plugin", "hold-discs", PLUGIN, "1")
    local path = mp.get_property("path", "")
    if path:match("^lumenbd://") or path:match("^lumendvd://") or path:match("^bd://") or path:match("^dvd://") then
        mp.command("stop")
    end
    toggle_label()
    -- give a disc that was playing a moment to be closed
    settle_timer = mp.add_timeout(2, function() settle_timer = nil look_for_disc() end)
end

local function stop()
    local j = job
    if j and j.pidfile then
        if WINDOWS then
            run({ "taskkill", "/F", "/IM", "makemkvcon64.exe", "/IM", "makemkvcon.exe" })
        else
            local pid = trim(read_file(j.pidfile) or "")
            if pid:match("^%d+$") then run({ "/bin/kill", pid }) end
        end
    end
    disarm()
    -- the partial file goes once makemkvcon has let go of it
    if j then mp.add_timeout(3, function() clean_up(j) end) end
end

toggle_label = function()
    action("toggle", armed and "Stop auto rip" or "Start auto rip")
end

-- ------------------------------------------------------------------ Lumen

mp.register_script_message("lumen-action", function(id, name)
    if id ~= PLUGIN or not config_dir then return end
    if name == "toggle" then
        if armed then stop() else arm() end
    elseif name == "folder" then
        local root = output_root()
        mkdirs(root)
        mp.commandv("script-message", "lumen-plugin", "open-folder", root)
    elseif name == "settings" then
        mp.commandv("script-message", "lumen-plugin", "open-folder", config_dir)
    end
end)

mp.register_script_message("lumen-event", function(event, json)
    -- a disc went in: give the drive a moment to read it, then look
    if event == "drive" and armed and not job then
        if settle_timer then settle_timer:kill() end
        status("A disc went in …")
        settle_timer = mp.add_timeout(10, function() settle_timer = nil look_for_disc() end)
    end
end)

mp.register_script_message(PLUGIN .. "-dirs", function(dir, config)
    if config_dir then return end
    plugin_dir, config_dir = dir, config
    load_settings()
    toggle_label()
    action("folder", "Open folder")
    action("settings", "Settings")
    if find_makemkvcon() then
        status("Ready – press Start auto rip, then insert a disc. Copies go to " .. output_root())
    else
        status("MakeMKV not found – install it (My AACS Plugin has a button for that)")
    end
end)

-- for tests: the pure functions
if os.getenv("LUMEN_AUTORIP_SELFTEST") then
    _G.autorip = { parse_line = parse_line, parse_drives = parse_drives, parse_info = parse_info, choose = choose,
                   tidy_label = tidy_label, safe_name = safe_name, season_of = season_of, settings = settings }
    for _, d in ipairs(DEFAULTS) do settings[d[1]] = d[2] end
end

-- Lumen answers once its plugin host is attached to the player; ask until it does
local asked = 0
local function ask_dirs()
    if config_dir then return end
    asked = asked + 1
    if asked > 30 then
        -- no answer: a Lumen before 1.4 does not know the question
        mp.commandv("script-message", "lumen-plugin", "status", PLUGIN, "This plugin needs Lumen 1.4 or newer")
        return
    end
    mp.commandv("script-message", "lumen-plugin", "dirs", PLUGIN, PLUGIN .. "-dirs")
    mp.add_timeout(1, ask_dirs)
end
ask_dirs()
