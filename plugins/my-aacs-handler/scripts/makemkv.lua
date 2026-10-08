-- My AACS Plugin – MakeMKV at the press of a button, and its beta key kept current.
--
--   Install MakeMKV   downloads MakeMKV from makemkv.com (checked against the SHA-256 list published
--                     there) and installs it: the application on macOS, the installer on Windows, a
--                     build from the official sources into the plugin's settings folder on Linux.
--   Beta key          MakeMKV is free while in beta; its author posts the current key in the MakeMKV
--                     forum. If MakeMKV has no key, or a beta key, the plugin enters the current one
--                     (checked once a day). A key you bought is never touched.
--                     Switch off: "beta_key = off" in makemkv.txt (settings folder).
--
-- Needs Lumen 1.4 or newer. This plugin contains no decryption software and no keys.
local utils = require "mp.utils"
local msg = require "mp.msg"

local PLUGIN = "my-aacs-handler"
local platform = mp.get_property("platform") or ""
local WINDOWS = platform == "windows"
local MAC = platform == "darwin"
local SEP = WINDOWS and "\\" or "/"

-- the environment variables exist for tests against a local server and a scratch folder
local SITE = os.getenv("LUMEN_AACS_MAKEMKV_SITE") or "https://www.makemkv.com"
local KEY_PAGE = os.getenv("LUMEN_AACS_KEY_PAGE") or "https://forum.makemkv.com/forum/viewtopic.php?f=5&t=1053"
local EULA = "https://www.makemkv.com/eula"

local plugin_dir, config_dir
local settings = { beta_key = "auto" }
local busy = false
local confirm_until = 0
local requests = 0

-- ------------------------------------------------------------------ helpers

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

local function exists(path) return utils.file_info(path) ~= nil end
local function env(name) return os.getenv(name) or "" end
local function home() return WINDOWS and env("USERPROFILE") or env("HOME") end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function run(args, cb)
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false, capture_stdout = true,
                              capture_stderr = true, capture_size = 4 * 1024 * 1024 },
                            function(ok, res)
        if cb then cb(ok and res or { status = -1, stdout = "", stderr = "" }) end
    end)
end

local function run_sync(args)
    return mp.command_native({ name = "subprocess", args = args, playback_only = false, capture_stdout = true,
                               capture_stderr = true }) or { status = -1, stdout = "", stderr = "" }
end

local function http_get(url, cb)
    requests = requests + 1
    local name = PLUGIN .. "-http-" .. requests
    mp.register_script_message(name, function(code, body)
        mp.unregister_script_message(name)
        cb(tonumber(code) or 0, body or "")
    end)
    mp.commandv("script-message", "lumen-plugin", "http", name, url, "{}")
end

local function refresh_native()
    -- the native part looks for MakeMKV again and shows the Blu-ray status
    mp.commandv("script-message", "lumen-plugin", "trigger", PLUGIN, "refresh_keys")
end

-- ------------------------------------------------------------------ where MakeMKV lives

local function apps_dir()
    local test = os.getenv("LUMEN_AACS_APPS_DIR")
    if test then return test end
    -- /Applications if we may write there, else the user's own Applications folder
    local probe = "/Applications/.lumen-write-test"
    if write_file(probe, "") then
        os.remove(probe)
        return "/Applications"
    end
    return join(home(), "Applications")
end

local function linux_prefix()
    return join(config_dir, "makemkv")
end

local function makemkv_installed()
    if MAC then
        return exists(join(apps_dir(), "MakeMKV.app")) or exists("/Applications/MakeMKV.app")
               or exists(join(home(), "Applications/MakeMKV.app"))
    elseif WINDOWS then
        for _, base in ipairs({ env("ProgramFiles(x86)"), env("ProgramFiles"), env("ProgramW6432") }) do
            if base ~= "" and (exists(base .. "\\MakeMKV\\makemkvcon64.exe") or exists(base .. "\\MakeMKV\\makemkvcon.exe")) then
                return true
            end
        end
        return false
    end
    if exists(join(linux_prefix(), "bin/makemkvcon")) then return true end
    for dir in (env("PATH") .. ":/usr/bin:/usr/local/bin"):gmatch("[^:]+") do
        if exists(join(dir, "makemkvcon")) then return true end
    end
    return false
end

local function labels()
    action("mk_install", makemkv_installed() and "Update MakeMKV" or "Install MakeMKV")
    action("mk_key", "Update beta key")
end

-- ------------------------------------------------------------------ the beta key

-- MakeMKV keeps its settings in a text file (macOS, Linux) or in the registry (Windows)
local function conf_file()
    local test = os.getenv("LUMEN_AACS_MAKEMKV_CONF")
    if test then return test end
    if MAC then return join(home(), "Library/MakeMKV/settings.conf") end
    return join(home(), ".MakeMKV/settings.conf")
end

local function current_key()
    if WINDOWS and not os.getenv("LUMEN_AACS_MAKEMKV_CONF") then
        local res = run_sync({ "reg", "query", "HKCU\\Software\\MakeMKV", "/v", "app_Key" })
        return trim((res.stdout or ""):match("app_Key%s+REG_SZ%s+([^\r\n]*)") or "")
    end
    local text = read_file(conf_file()) or ""
    return text:match('\n%s*app_Key%s*=%s*"([^"]*)"') or text:match('^%s*app_Key%s*=%s*"([^"]*)"') or ""
end

local function store_key(key)
    if WINDOWS and not os.getenv("LUMEN_AACS_MAKEMKV_CONF") then
        local res = run_sync({ "reg", "add", "HKCU\\Software\\MakeMKV", "/v", "app_Key", "/t", "REG_SZ", "/d", key, "/f" })
        return res.status == 0
    end
    local file = conf_file()
    local text = read_file(file)
    if not text then
        -- MakeMKV has not run yet: its folder may not exist
        local dir = file:match("^(.*)[/\\][^/\\]+$")
        if dir and not exists(dir) then
            run_sync(WINDOWS and { "cmd.exe", "/c", "mkdir", dir } or { "/bin/mkdir", "-p", dir })
        end
        text = "#\n# MakeMKV settings file\n#\n\n"
    end
    local line = 'app_Key = "' .. key .. '"'
    local n
    -- a line break in front, so that the pattern also finds the key in the file's first line
    text, n = ("\n" .. text):gsub('([\r\n])[ \t]*app_Key[ \t]*=[ \t]*"[^"\r\n]*"', function(nl) return nl .. line end, 1)
    text = text:sub(2)
    if n == 0 then
        if text ~= "" and text:sub(-1) ~= "\n" then text = text .. "\n" end
        text = text .. line .. "\n"
    end
    return write_file(file, text)
end

-- a beta key is a "T-" key; a key that was bought starts differently and is left alone
local function is_beta(key)
    return key == "" or key:match("^T%-") ~= nil
end

-- cb(note or nil): what was done, in words for the status line
local function update_key(manual, cb)
    local have = current_key()
    if not is_beta(have) then
        cb(manual and "MakeMKV is registered with a key of its own – nothing to update" or nil)
        return
    end
    http_get(KEY_PAGE, function(code, body)
        if code ~= 200 then
            cb(manual and ("Could not read the MakeMKV forum (" .. (code == 0 and body or ("HTTP " .. code)) .. ")") or nil)
            return
        end
        -- "The current beta key is <code>T-…</code> … valid until end of October 2026"
        local from = body:find("current beta key", 1, true) or 1
        local key = body:match("(T%-[%w_@%-]+)", from)
        if not key or #key < 40 then
            cb(manual and "The MakeMKV forum page shows no beta key right now" or nil)
            return
        end
        local valid = body:match("valid until end of ([%a]+ %d%d%d%d)", from)
        local until_text = valid and (" (valid until the end of " .. valid .. ")") or ""
        write_file(join(config_dir, "beta-key-checked.txt"), tostring(os.time()))
        if key == have then
            cb(manual and ("MakeMKV already has the current beta key" .. until_text) or nil)
        elseif store_key(key) then
            cb("MakeMKV beta key updated" .. until_text)
        else
            cb("Could not write MakeMKV's settings (" .. conf_file() .. ")")
        end
    end)
end

local function daily_key_check()
    if settings.beta_key == "off" or not makemkv_installed() then return end
    local last = tonumber(read_file(join(config_dir, "beta-key-checked.txt")) or "") or 0
    if os.time() - last < 20 * 3600 then return end
    update_key(false, function(note)
        if note then
            status(note .. " – click Refresh for the Blu-ray status")
        end
    end)
end

-- ------------------------------------------------------------------ installing MakeMKV

local function fail(text)
    busy = false
    status(text)
    labels()
end

local function done(text)
    busy = false
    labels()
    refresh_native()
    -- after the native part has written its status: say what happened
    mp.add_timeout(1.5, function()
        update_key(false, function(note)
            status(text .. (note and (" · " .. note) or "") .. " – click Refresh for the Blu-ray status")
        end)
    end)
end

-- SHA-256 of a file with the system's own tool
local function sha256(path, cb)
    local args
    if WINDOWS then args = { "certutil", "-hashfile", path, "SHA256" }
    elseif MAC then args = { "/usr/bin/shasum", "-a", "256", path }
    else args = { "sha256sum", path } end
    run(args, function(res)
        local out = (res.stdout or ""):lower():gsub("%s", "")
        cb(out:match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)"))
    end)
end

-- download one file and check it against the published list; cb(path or nil, error)
local function fetch(version, name, sums, cb)
    local want = sums:match("(%x+)%s+" .. name:gsub("[%.%-]", "%%%0"))
    if not want or #want ~= 64 then
        cb(nil, "the published checksum list does not name " .. name)
        return
    end
    local dir = join(config_dir, "download")
    run_sync(WINDOWS and { "cmd.exe", "/c", "mkdir", dir } or { "/bin/mkdir", "-p", dir })
    local path = join(dir, name)
    os.remove(path)
    status("Downloading " .. name .. " from makemkv.com …")
    run({ "curl", "-fL", "--retry", "2", "--silent", "--show-error", "-o", path, SITE .. "/download/" .. name }, function(res)
        if res.status ~= 0 or not exists(path) then
            cb(nil, "download failed: " .. trim(res.stderr ~= "" and res.stderr or "curl is not available"))
            return
        end
        sha256(path, function(got)
            if got ~= want:lower() then
                os.remove(path)
                cb(nil, name .. " does not match the checksum published on makemkv.com – not installed")
            else
                cb(path)
            end
        end)
    end)
end

local function install_mac(version, sums)
    local name = "makemkv_v" .. version .. "_osx.dmg"
    fetch(version, name, sums, function(dmg, err)
        if not dmg then return fail("MakeMKV not installed: " .. err) end
        local mount = join(config_dir, "download/volume")
        local target = join(apps_dir(), "MakeMKV.app")
        status("Installing MakeMKV " .. version .. " …")
        run({ "/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg }, function(res)
            if res.status ~= 0 then return fail("MakeMKV not installed: the disk image did not open (" .. trim(res.stderr) .. ")") end
            run({ "/usr/bin/ditto", join(mount, "MakeMKV.app"), target }, function(copy)
                run({ "/usr/bin/hdiutil", "detach", mount, "-force" }, function()
                    os.remove(dmg)
                    if copy.status ~= 0 then
                        return fail("MakeMKV not installed: could not copy to " .. target .. " (" .. trim(copy.stderr) .. "). Is MakeMKV running?")
                    end
                    done("MakeMKV " .. version .. " installed in " .. apps_dir())
                end)
            end)
        end)
    end)
end

local function install_windows(version, sums)
    local name = "Setup_MakeMKV_v" .. version .. ".exe"
    fetch(version, name, sums, function(exe, err)
        if not exe then return fail("MakeMKV not installed: " .. err) end
        status("Installing MakeMKV " .. version .. " – Windows asks for permission …")
        -- the installer needs administrator rights: Windows shows its own question
        run({ "powershell", "-NoProfile", "-Command",
              "try { Start-Process -FilePath '" .. exe:gsub("'", "''") .. "' -ArgumentList '/S' -Verb RunAs -Wait; exit 0 } catch { exit 1 }" },
            function(res)
            os.remove(exe)
            if res.status ~= 0 or not makemkv_installed() then
                return fail("MakeMKV not installed: the installer was cancelled or failed")
            end
            done("MakeMKV " .. version .. " installed")
        end)
    end)
end

-- Linux: MakeMKV comes as source (open part) plus a binary part; the script builds both into the
-- plugin's settings folder, without administrator rights
local function install_linux(version, sums)
    local oss, bin = "makemkv-oss-" .. version .. ".tar.gz", "makemkv-bin-" .. version .. ".tar.gz"
    fetch(version, oss, sums, function(a, err)
        if not a then return fail("MakeMKV not installed: " .. err) end
        fetch(version, bin, sums, function(b, err2)
            if not b then return fail("MakeMKV not installed: " .. err2) end
            local log = join(config_dir, "download/build.log")
            status("Building MakeMKV " .. version .. " – this takes a few minutes …")
            run({ "/bin/sh", join(plugin_dir, "scripts/build-makemkv-linux.sh"), a, b, linux_prefix(), log }, function(res)
                os.remove(a)
                os.remove(b)
                if res.status ~= 0 then
                    local why = trim((res.stdout or ""):match("[^\n]*\n?$") or "")
                    return fail("MakeMKV not built: " .. (why ~= "" and why or "see " .. log))
                end
                -- tell the native part where libmmbd is
                local file = join(config_dir, "settings.txt")
                local text = read_file(file) or ""
                local mode = text:match("\n%s*makemkv%s*=%s*(%a+)") or text:match("^%s*makemkv%s*=%s*(%a+)") or "auto"
                write_file(file, "# My AACS Plugin\n"
                    .. "# makemkv: auto = use MakeMKV unless your own libaacs is in the plugin's lib/ folder, on, off\n"
                    .. "makemkv = " .. mode .. "\n"
                    .. "# makemkv_path: the MakeMKV folder or its libmmbd library, if the plugin does not find it\n"
                    .. "makemkv_path = " .. join(linux_prefix(), "lib") .. "\n")
                done("MakeMKV " .. version .. " built in " .. linux_prefix())
            end)
        end)
    end)
end

local function install()
    if busy then return end
    -- installing means accepting MakeMKV's licence: say so first, go ahead on the second click
    if mp.get_time() > confirm_until then
        confirm_until = mp.get_time() + 90
        status("MakeMKV is shareware by GuinpinSoft, free to use while in beta. The plugin downloads it from makemkv.com; "
               .. "installing it means accepting its licence: " .. EULA .. " – click the button again to go ahead.")
        return
    end
    confirm_until = 0
    busy = true
    status("Asking makemkv.com for the current version …")
    http_get(SITE .. "/download/", function(code, body)
        local version = code == 200 and body:match("makemkv_v([%d%.]+)_osx%.dmg") or nil
        if not version then
            return fail("Could not read makemkv.com (" .. (code == 0 and body or ("HTTP " .. code)) .. ")")
        end
        http_get(SITE .. "/download/makemkv-sha-" .. version .. ".txt", function(code2, sums)
            if code2 ~= 200 then return fail("Could not read the checksum list of MakeMKV " .. version) end
            if MAC then install_mac(version, sums)
            elseif WINDOWS then install_windows(version, sums)
            else install_linux(version, sums) end
        end)
    end)
end

-- ------------------------------------------------------------------ Lumen

mp.register_script_message("lumen-action", function(id, name)
    if id ~= PLUGIN or not config_dir then return end
    if name == "mk_install" then
        install()
    elseif name == "mk_key" then
        if not makemkv_installed() then
            status("MakeMKV is not installed – use Install MakeMKV first")
            return
        end
        update_key(true, function(note) status((note or "Nothing to do") .. " – click Refresh for the Blu-ray status") end)
    end
end)

mp.register_script_message(PLUGIN .. "-mk-dirs", function(dir, config)
    if config_dir then return end
    plugin_dir, config_dir = dir, config
    for line in (read_file(join(config_dir, "makemkv.txt")) or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and not line:match("^%s*#") then settings[k] = v end
    end
    labels()
    -- not at once: Lumen is still starting
    mp.add_timeout(8, daily_key_check)
end)

local asked = 0
local function ask_dirs()
    if config_dir then return end
    asked = asked + 1
    -- no answer: a Lumen before 1.4 does not know the question; the rest of the plugin works as before
    if asked > 30 then return end
    mp.commandv("script-message", "lumen-plugin", "dirs", PLUGIN, PLUGIN .. "-mk-dirs")
    mp.add_timeout(1, ask_dirs)
end
ask_dirs()
