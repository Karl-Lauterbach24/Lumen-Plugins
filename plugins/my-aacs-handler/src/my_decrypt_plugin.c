/*
 * My AACS Plugin – native part: Blu-ray decryption through MakeMKV, the AACS
 * key database, DCP content keys and the buttons in the Plugins tab.
 *
 * Blu-ray: libbluray loads the library named by LIBAACS_PATH / LIBBDPLUS_PATH
 * every time it opens a disc. Lumen sets both for libraries in the plugin's
 * lib/ folder (plugin.json: discLibraries). If there are none and MakeMKV is
 * installed, this plugin points them at MakeMKV's libmmbd, which stands in for
 * libaacs and libbdplus. "MakeMKV on/off" overrides that choice; it is kept in
 * settings.txt in the plugin's config folder:
 *
 *     makemkv = auto | on | off
 *     makemkv_path = <MakeMKV folder or libmmbd library, if not found by itself>
 *
 * AACS keys: libaacs reads KEYDB.cfg from a fixed folder of the user. A
 * KEYDB.cfg dropped onto the Lumen window arrives here as aacskeydb://<path>
 * (scripts/status.lua), one in the config folder is picked up by "Refresh".
 * Both are installed where libaacs looks for it; a different previous file is
 * kept as KEYDB.cfg.bak.
 *
 * DCP: Lumen asks the plugin for a content key when no KDM delivered it
 * (dcp_content_key). Keys come from "dcp-keys.txt" in the config folder, one
 * "<key id> <key>" pair per line (hex, UUID dashes allowed).
 *
 * The plugin contains no decryption code and no keys.
 *
 * Build: see README.md (CMake) – needs only include/lumen/plugin.h.
 */
#include "lumen/plugin.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define SEP "\\"
#else
#include <sys/stat.h>
#include <unistd.h>
#define SEP "/"
#endif

#define MAX_KEYS 256
#define PATH_LEN 1024

/* mpv property with the result of the last KEYDB.cfg import, read by scripts/status.lua */
#define KEYDB_RESULT "user-data/my-aacs-handler/keydb"
/* what this plugin put into LIBAACS_PATH: a restarted Lumen inherits the environment */
#define ENV_OURS "LUMEN_MY_AACS_HANDLER_MMBD"

/* file names of libmmbd and the folders MakeMKV installs it to */
static const char *const mmbd_names[] = {
#if defined(_WIN32)
#if defined(_M_ARM64) || defined(__aarch64__)
    /* MakeMKV has no ARM64 library */
#elif defined(_WIN64)
    "libmmbd64.dll",
#else
    "libmmbd.dll",
#endif
#elif defined(__APPLE__)
    "libmmbd_new.dylib", "libmmbd.dylib",
#else
    "libmmbd.so.0",
#endif
    NULL};

#if defined(_WIN32)
static const char *const mmbd_dirs[] = {"%ProgramFiles(x86)%\\MakeMKV", "%ProgramFiles%\\MakeMKV", "%ProgramW6432%\\MakeMKV", NULL};
#define MMBD_SUFFIX ".dll"
#define OWN_LIBS "libaacs-0.dll and libbdplus.dll (with the DLLs they need)"
#elif defined(__APPLE__)
static const char *const mmbd_dirs[] = {"/Applications/MakeMKV.app/Contents/lib", NULL};
#define MMBD_SUFFIX ".dylib"
#define OWN_LIBS "libaacs.dylib and libbdplus.dylib"
#else
static const char *const mmbd_dirs[] = {"/usr/lib", "/usr/lib64", "/usr/local/lib", "/usr/lib/x86_64-linux-gnu",
                                        "/usr/lib/aarch64-linux-gnu", NULL};
#define MMBD_SUFFIX ".so.0"
#define OWN_LIBS "libaacs.so.0 and libbdplus.so"
#endif

enum { MAKEMKV_AUTO, MAKEMKV_ON, MAKEMKV_OFF };

typedef struct state {
    const lumen_host *host;
    int count;
    uint8_t ids[MAX_KEYS][16];
    uint8_t keys[MAX_KEYS][16];

    int makemkv;                /* MAKEMKV_* from settings.txt */
    char makemkv_path[PATH_LEN]; /* makemkv_path from settings.txt */
    char mmbd[PATH_LEN];        /* libmmbd of the MakeMKV installation, "" = not found */
    char own_aacs[PATH_LEN];    /* LIBAACS_PATH / LIBBDPLUS_PATH as Lumen started the plugin */
    char own_bdplus[PATH_LEN];
    int using_mmbd;
} state;

/* ---- files and environment, paths are UTF-8 ---- */

#ifdef _WIN32
static wchar_t *widen(const char *s)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t *w = n > 0 ? malloc((size_t)n * sizeof *w) : NULL;
    if (w)
        MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}
#endif

static FILE *open_file(const char *path, const char *mode)
{
#ifdef _WIN32
    wchar_t *wpath = widen(path), *wmode = widen(mode);
    FILE *f = wpath && wmode ? _wfopen(wpath, wmode) : NULL;
    free(wpath);
    free(wmode);
    return f;
#else
    return fopen(path, mode);
#endif
}

/* 0 = missing, 1 = file, 2 = folder */
static int path_kind(const char *path)
{
#ifdef _WIN32
    wchar_t *w = widen(path);
    DWORD a = w ? GetFileAttributesW(w) : INVALID_FILE_ATTRIBUTES;
    free(w);
    return a == INVALID_FILE_ATTRIBUTES ? 0 : (a & FILE_ATTRIBUTE_DIRECTORY) ? 2 : 1;
#else
    struct stat s;
    return stat(path, &s) != 0 ? 0 : S_ISDIR(s.st_mode) ? 2 : 1;
#endif
}

static void make_dir(const char *path)
{
#ifdef _WIN32
    wchar_t *w = widen(path);
    if (w)
        CreateDirectoryW(w, NULL);
    free(w);
#else
    mkdir(path, 0755);
#endif
}

/* the folder and the missing ones above it */
static void make_dirs(const char *path)
{
    char part[PATH_LEN];
    snprintf(part, sizeof part, "%s", path);
    for (char *p = part + 1; *p; ++p) {
        if (*p == '/' || *p == '\\') {
            char c = *p;
            *p = 0;
            make_dir(part);
            *p = c;
        }
    }
    make_dir(part);
}

static void remove_file(const char *path)
{
#ifdef _WIN32
    wchar_t *w = widen(path);
    if (w)
        DeleteFileW(w);
    free(w);
#else
    unlink(path);
#endif
}

/* replaces an existing target */
static int move_file(const char *from, const char *to)
{
#ifdef _WIN32
    wchar_t *wf = widen(from), *wt = widen(to);
    int ok = wf && wt && MoveFileExW(wf, wt, MOVEFILE_REPLACE_EXISTING);
    free(wf);
    free(wt);
    return ok;
#else
    return rename(from, to) == 0;
#endif
}

/* "" if the variable is not set */
static void env_get(const char *name, char *out, size_t size)
{
#ifdef _WIN32
    wchar_t *wname = widen(name), value[PATH_LEN];
    DWORD n = wname ? GetEnvironmentVariableW(wname, value, PATH_LEN) : 0;
    free(wname);
    out[0] = 0;
    if (n > 0 && n < PATH_LEN && !WideCharToMultiByte(CP_UTF8, 0, value, -1, out, (int)size, NULL, NULL))
        out[0] = 0;
#else
    const char *v = getenv(name);
    snprintf(out, size, "%s", v ? v : "");
#endif
}

/* "" removes the variable */
static void env_set(const char *name, const char *value)
{
#ifdef _WIN32
    /* through the C runtime: libbluray reads the variables with getenv() */
    wchar_t *wname = widen(name), *wvalue = widen(value);
    if (wname && wvalue)
        _wputenv_s(wname, wvalue);
    free(wname);
    free(wvalue);
#else
    if (*value)
        setenv(name, value, 1);
    else
        unsetenv(name);
#endif
}

static int ends_with(const char *s, const char *suffix)
{
    size_t n = strlen(s), m = strlen(suffix);
    return n >= m && strcmp(s + n - m, suffix) == 0;
}

/* ---- settings.txt ---- */

static char *trim(char *s)
{
    char *end;
    while (isspace((unsigned char)*s))
        ++s;
    end = s + strlen(s);
    while (end > s && isspace((unsigned char)end[-1]))
        *--end = 0;
    return s;
}

static void load_settings(state *st)
{
    char path[PATH_LEN], line[PATH_LEN + 64];
    FILE *f;
    st->makemkv = MAKEMKV_AUTO;
    st->makemkv_path[0] = 0;
    snprintf(path, sizeof path, "%s" SEP "settings.txt", st->host->config_dir(st->host->ctx));
    f = open_file(path, "r");
    if (!f)
        return;
    while (fgets(line, sizeof line, f)) {
        char *key = trim(line), *value = strchr(key, '=');
        if (*key == '#' || !value)
            continue;
        *value++ = 0;
        key = trim(key);
        value = trim(value);
        if (strcmp(key, "makemkv") == 0)
            st->makemkv = strcmp(value, "on") == 0 ? MAKEMKV_ON : strcmp(value, "off") == 0 ? MAKEMKV_OFF : MAKEMKV_AUTO;
        else if (strcmp(key, "makemkv_path") == 0)
            snprintf(st->makemkv_path, sizeof st->makemkv_path, "%s", value);
    }
    fclose(f);
}

static void save_settings(state *st)
{
    static const char *const modes[] = {"auto", "on", "off"};
    char path[PATH_LEN];
    FILE *f;
    snprintf(path, sizeof path, "%s" SEP "settings.txt", st->host->config_dir(st->host->ctx));
    f = open_file(path, "w");
    if (!f)
        return;
    fprintf(f, "# My AACS Plugin\n"
               "# makemkv: auto = use MakeMKV unless your own libaacs is in the plugin's lib/ folder, on, off\n"
               "makemkv = %s\n"
               "# makemkv_path: the MakeMKV folder or its libmmbd library, if the plugin does not find it\n"
               "makemkv_path = %s\n",
            modes[st->makemkv], st->makemkv_path);
    fclose(f);
}

/* ---- Blu-ray: MakeMKV ---- */

/* libbluray appends the suffix itself, so only a library named like that can be used */
static int try_mmbd(state *st, const char *file)
{
    if (path_kind(file) != 1 || !ends_with(file, MMBD_SUFFIX))
        return 0;
    snprintf(st->mmbd, sizeof st->mmbd, "%s", file);
    return 1;
}

static int try_mmbd_dir(state *st, const char *dir)
{
    char file[PATH_LEN];
    for (int i = 0; mmbd_names[i]; ++i) {
        snprintf(file, sizeof file, "%s" SEP "%s", dir, mmbd_names[i]);
        if (try_mmbd(st, file))
            return 1;
    }
    return 0;
}

static void find_makemkv(state *st)
{
    char dir[PATH_LEN];
    st->mmbd[0] = 0;
    if (st->makemkv_path[0]) {
        /* the library itself, the MakeMKV folder or (macOS) MakeMKV.app */
        snprintf(dir, sizeof dir, "%s" SEP "Contents" SEP "lib", st->makemkv_path);
        if (try_mmbd(st, st->makemkv_path) || try_mmbd_dir(st, st->makemkv_path) || try_mmbd_dir(st, dir))
            return;
    }
    for (int i = 0; mmbd_dirs[i]; ++i) {
#ifdef _WIN32
        wchar_t *w = widen(mmbd_dirs[i]), expanded[PATH_LEN];
        DWORD n = w ? ExpandEnvironmentStringsW(w, expanded, PATH_LEN) : 0;
        free(w);
        if (n == 0 || n > PATH_LEN || !WideCharToMultiByte(CP_UTF8, 0, expanded, -1, dir, (int)sizeof dir, NULL, NULL))
            continue;
#else
        snprintf(dir, sizeof dir, "%s", mmbd_dirs[i]);
#endif
        if (try_mmbd_dir(st, dir))
            return;
    }
}

static void apply_backend(state *st)
{
    char spec[PATH_LEN];
    st->using_mmbd = st->mmbd[0] && (st->makemkv == MAKEMKV_ON || (st->makemkv == MAKEMKV_AUTO && !st->own_aacs[0]));
    if (st->using_mmbd) {
        snprintf(spec, sizeof spec, "%.*s", (int)(strlen(st->mmbd) - strlen(MMBD_SUFFIX)), st->mmbd);
        env_set("LIBAACS_PATH", spec);
        env_set("LIBBDPLUS_PATH", spec);
        env_set(ENV_OURS, spec);
    } else {
        env_set("LIBAACS_PATH", st->own_aacs);
        env_set("LIBBDPLUS_PATH", st->own_bdplus);
        env_set(ENV_OURS, "");
    }
}

/* ---- AACS key database ---- */

/* the folder libaacs reads KEYDB.cfg from */
static void keydb_dir(char *out, size_t size)
{
    char base[PATH_LEN];
#if defined(_WIN32)
    env_get("APPDATA", base, sizeof base);
    snprintf(out, size, "%s\\aacs", base);
#elif defined(__APPLE__)
    env_get("HOME", base, sizeof base);
    snprintf(out, size, "%s/Library/Preferences/aacs", base);
#else
    env_get("XDG_CONFIG_HOME", base, sizeof base);
    if (base[0]) {
        snprintf(out, size, "%s/aacs", base);
    } else {
        env_get("HOME", base, sizeof base);
        snprintf(out, size, "%s/.config/aacs", base);
    }
#endif
}

static int is_hex(const char *s, int n)
{
    for (int i = 0; i < n; ++i)
        if (!isxdigit((unsigned char)s[i]))
            return 0;
    return 1;
}

/* An entry of a key database: "| DK | …", "| PK | …", "| HC | …" or "0x<disc id> = …" */
static int is_keydb_entry(const char *line)
{
    while (isspace((unsigned char)*line))
        ++line;
    if (*line == '|') {
        ++line;
        while (*line == ' ' || *line == '\t')
            ++line;
        return strncmp(line, "DK", 2) == 0 || strncmp(line, "PK", 2) == 0 || strncmp(line, "HC", 2) == 0;
    }
    if (strncmp(line, "0x", 2) == 0 && is_hex(line + 2, 40)) {
        line += 42;
        while (*line == ' ' || *line == '\t')
            ++line;
        return *line == '=';
    }
    return 0;
}

static int same_content(FILE *a, FILE *b)
{
    char x[4096], y[4096];
    size_t n;
    do {
        n = fread(x, 1, sizeof x, a);
        if (fread(y, 1, sizeof y, b) != n || memcmp(x, y, n) != 0)
            return 0;
    } while (n > 0);
    return 1;
}

/* Copies a key database to where libaacs reads it. Returns 1 and the folder in
   msg, or 0 and the reason. */
static int install_keydb(const char *src, char *msg, size_t size)
{
    char dir[PATH_LEN], dst[PATH_LEN + 16], tmp[PATH_LEN + 16], bak[PATH_LEN + 16], buf[16384];
    FILE *in, *out;
    size_t n;
    int valid = 0, ok, kept;

    in = open_file(src, "rb");
    if (!in) {
        snprintf(msg, size, "KEYDB.cfg not installed: the file can't be read");
        return 0;
    }
    while (!valid && fgets(buf, sizeof buf, in))
        valid = is_keydb_entry(buf);
    if (!valid) {
        fclose(in);
        snprintf(msg, size, "KEYDB.cfg not installed: no AACS key entries in this file");
        return 0;
    }
    rewind(in);

    keydb_dir(dir, sizeof dir);
    snprintf(dst, sizeof dst, "%s" SEP "KEYDB.cfg", dir);
    snprintf(tmp, sizeof tmp, "%s.new", dst);
    snprintf(bak, sizeof bak, "%s.bak", dst);
    out = open_file(dst, "rb");
    if (out) {
        /* dropped a second time: the backup stays the file from before */
        valid = same_content(in, out);
        fclose(out);
        if (valid) {
            fclose(in);
            snprintf(msg, size, "KEYDB.cfg is already installed in %s", dir);
            return 1;
        }
        rewind(in);
    }
    if (path_kind(dir) != 2)
        make_dirs(dir);
    out = open_file(tmp, "wb");
    if (!out) {
        fclose(in);
        snprintf(msg, size, "KEYDB.cfg not installed: can't write to %s", dir);
        return 0;
    }
    ok = 1;
    while (ok && (n = fread(buf, 1, sizeof buf, in)) > 0)
        ok = fwrite(buf, 1, n, out) == n;
    ok = ok && !ferror(in);
    fclose(in);
    ok = fclose(out) == 0 && ok;
    kept = ok && path_kind(dst) == 1 && move_file(dst, bak);
    if (!ok || !move_file(tmp, dst)) {
        if (kept)
            move_file(bak, dst);
        remove_file(tmp);
        snprintf(msg, size, "KEYDB.cfg not installed: can't write to %s", dir);
        return 0;
    }
    snprintf(msg, size, "KEYDB.cfg installed in %s", dir);
    return 1;
}

/* ---- DCP keys ---- */

static int nibble(int c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    c = tolower(c);
    return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

/* 32 hex digits (dashes and "urn:uuid:" ignored) -> 16 bytes */
static int parse16(const char *s, uint8_t out[16])
{
    int n = 0, hi = -1;
    if (strncmp(s, "urn:uuid:", 9) == 0)
        s += 9;
    for (; *s && n < 16; ++s) {
        int v;
        if (*s == '-')
            continue;
        v = nibble((unsigned char)*s);
        if (v < 0)
            return 0;
        if (hi < 0) {
            hi = v;
        } else {
            out[n++] = (uint8_t)(hi << 4 | v);
            hi = -1;
        }
    }
    return n == 16;
}

static void load_keys(state *st)
{
    char path[PATH_LEN], line[256];
    FILE *f;
    st->count = 0;
    snprintf(path, sizeof path, "%s" SEP "dcp-keys.txt", st->host->config_dir(st->host->ctx));
    f = open_file(path, "r");
    if (f) {
        while (st->count < MAX_KEYS && fgets(line, sizeof line, f)) {
            char id[80], key[80];
            if (line[0] == '#' || sscanf(line, "%79s %79s", id, key) != 2)
                continue;
            if (parse16(id, st->ids[st->count]) && parse16(key, st->keys[st->count]))
                ++st->count;
        }
        fclose(f);
    }
}

/* ---- status line, buttons ---- */

static void status_text(state *st, char *out, size_t size)
{
    char keydb[PATH_LEN + 16], bluray[PATH_LEN + 160];
    if (st->using_mmbd) {
        /* MakeMKV brings its own keys */
        snprintf(bluray, sizeof bluray, "Blu-ray: MakeMKV (%s)", st->mmbd);
    } else {
        const char *makemkv = !st->mmbd[0] ? "MakeMKV not found" : st->makemkv == MAKEMKV_OFF ? "MakeMKV switched off" : "MakeMKV not used";
        keydb_dir(keydb, PATH_LEN);
        strcat(keydb, SEP "KEYDB.cfg");
        snprintf(bluray, sizeof bluray, "Blu-ray: %s, %s \xc2\xb7 %s",
                 st->own_aacs[0] ? "your own libaacs" : "no libaacs in lib/ (see Instructions)", makemkv,
                 path_kind(keydb) == 1 ? "KEYDB.cfg installed" : "KEYDB.cfg missing: drop it onto the Lumen window");
    }
    snprintf(out, size, "%s \xc2\xb7 %d DCP key(s)", bluray, st->count);
}

/* note: what just happened, shown in front of the status */
static void update_status(state *st, const char *note)
{
    char status[2 * PATH_LEN + 320], text[3 * PATH_LEN + 400];
    status_text(st, status, sizeof status);
    snprintf(text, sizeof text, "%s%s%s", note, *note ? " \xc2\xb7 " : "", status);
    st->host->set_status(st->host->ctx, text);
}

static void show_instructions(state *st)
{
    char keydb[PATH_LEN], text[4 * PATH_LEN + 1600];
    const char *plugin = st->host->plugin_dir(st->host->ctx), *config = st->host->config_dir(st->host->ctx);
    keydb_dir(keydb, sizeof keydb);
    snprintf(text, sizeof text,
             "Encrypted Blu-rays need one of these two:\n"
             "\n"
             "A) MakeMKV. Install MakeMKV and start it once, so that it is registered or its trial runs. "
             "Click Refresh: the status then says \"Blu-ray: MakeMKV\". Nothing else to set up, no key file needed. "
             "Installed in an unusual place? Enter it as makemkv_path in %s" SEP "settings.txt.\n"
             "\n"
             "B) Your own libaacs with a key file. 1. Copy " OWN_LIBS " into %s" SEP "lib and restart Lumen. "
             "2. Drop your KEYDB.cfg onto the Lumen window; it is installed in %s (a previous one is kept as KEYDB.cfg.bak). "
             "Instead of dropping it you can put it into %s and click Refresh.\n"
             "\n"
             "With both in place your own libaacs is used; \"MakeMKV on/off\" switches. The change applies to the next disc you open.\n"
             "\n"
             "DCP: content keys, one \"key-id key\" pair per line, in %s" SEP "dcp-keys.txt, then Refresh.\n"
             "\n"
             "This plugin contains no decryption software and no keys. You are responsible for making sure that "
             "using them is legal where you live. Click Refresh to see the status again.",
             config, plugin, keydb, config, config);
    st->host->set_status(st->host->ctx, text);
}

/* settings, MakeMKV, a KEYDB.cfg waiting in the config folder, DCP keys */
static void refresh(state *st, char *note, size_t size)
{
    char staged[PATH_LEN];
    note[0] = 0;
    load_settings(st);
    find_makemkv(st);
    apply_backend(st);
    snprintf(staged, sizeof staged, "%s" SEP "KEYDB.cfg", st->host->config_dir(st->host->ctx));
    if (path_kind(staged) == 1 && install_keydb(staged, note, size))
        remove_file(staged);
    load_keys(st);
    update_status(st, note);
}

static void *init(const lumen_host *host)
{
    char ours[PATH_LEN], note[PATH_LEN + 64];
    state *st = calloc(1, sizeof *st);
    if (!st)
        return NULL;
    st->host = host;
    /* What Lumen set for libraries in lib/. Not what this plugin set before a restart of Lumen. */
    env_get("LIBAACS_PATH", st->own_aacs, sizeof st->own_aacs);
    env_get("LIBBDPLUS_PATH", st->own_bdplus, sizeof st->own_bdplus);
    env_get(ENV_OURS, ours, sizeof ours);
    if (ours[0] && strcmp(st->own_aacs, ours) == 0)
        st->own_aacs[0] = 0;
    if (ours[0] && strcmp(st->own_bdplus, ours) == 0)
        st->own_bdplus[0] = 0;

    host->add_action(host->ctx, "refresh_keys", "Refresh");
    host->add_action(host->ctx, "toggle_makemkv", "MakeMKV on/off");
    host->add_action(host->ctx, "help", "Instructions");
    refresh(st, note, sizeof note);
    if (note[0])
        host->log(host->ctx, LUMEN_LOG_INFO, note);
    host->log(host->ctx, LUMEN_LOG_INFO, st->using_mmbd ? "Blu-ray decryption through MakeMKV" : "MakeMKV not used");
    return st;
}

static void plugin_shutdown(void *ctx)
{
    free(ctx);
}

static void on_action(void *ctx, const char *id)
{
    state *st = ctx;
    char text[2 * PATH_LEN + 320];
    if (strcmp(id, "refresh_keys") == 0) {
        refresh(st, text, sizeof text);
        if (!text[0])
            status_text(st, text, sizeof text);
        st->host->show_text(st->host->ctx, text, 4000);
    } else if (strcmp(id, "toggle_makemkv") == 0) {
        refresh(st, text, sizeof text);
        if (!st->mmbd[0]) {
            st->host->show_text(st->host->ctx, "MakeMKV not found: see Instructions", 4000);
            return;
        }
        st->makemkv = st->using_mmbd ? MAKEMKV_OFF : MAKEMKV_ON;
        save_settings(st);
        apply_backend(st);
        update_status(st, "");
        st->host->show_text(st->host->ctx, st->using_mmbd ? "Blu-ray: MakeMKV" : "Blu-ray: MakeMKV switched off", 3000);
    } else if (strcmp(id, "help") == 0) {
        show_instructions(st);
    }
}

/* aacskeydb://<path>: a KEYDB.cfg dropped onto the Lumen window (scripts/status.lua).
   There is nothing to play: install the file, leave the result for the script and
   give mpv an empty playlist, which it closes without an error message.
   Runs on a thread of mpv. */
static const char *const schemes[] = {"aacskeydb", NULL};
static const char empty_playlist[] = "#EXTM3U\n";

static int64_t playlist_read(void *cookie, char *buf, uint64_t size)
{
    size_t *pos = cookie, left = sizeof empty_playlist - 1 - *pos;
    if (size > left)
        size = left;
    memcpy(buf, empty_playlist + *pos, (size_t)size);
    *pos += (size_t)size;
    return (int64_t)size;
}

static void playlist_close(void *cookie)
{
    free(cookie);
}

static int stream_open(void *ctx, const char *url, lumen_stream *out)
{
    state *st = ctx;
    char msg[PATH_LEN + 64];
    const char *path = strstr(url, "://");
    size_t *pos = calloc(1, sizeof *pos);
    if (!path || !pos) {
        free(pos);
        return -1;
    }
    install_keydb(path + 3, msg, sizeof msg);
    st->host->log(st->host->ctx, LUMEN_LOG_INFO, msg);
    st->host->set_property(st->host->ctx, KEYDB_RESULT, msg);
    update_status(st, msg);
    out->cookie = pos;
    out->read = playlist_read;
    out->close = playlist_close;
    return 0;
}

/* If Lumen can't find a key in the KDM, it asks the plugin here */
static int dcp_content_key(void *ctx, const uint8_t key_id[16], uint8_t key[16])
{
    state *st = ctx;
    for (int i = 0; i < st->count; ++i) {
        if (memcmp(st->ids[i], key_id, 16) == 0) {
            memcpy(key, st->keys[i], 16);
            return 1;
        }
    }
    return 0;
}

LUMEN_PLUGIN_EXPORT const lumen_plugin *lumen_plugin_entry(void)
{
    static const lumen_plugin p = {
        sizeof(lumen_plugin),
        LUMEN_PLUGIN_API_VERSION,
        init,
        plugin_shutdown,
        NULL,            /* on_event */
        on_action,
        schemes,         /* aacskeydb:// */
        stream_open,
        dcp_content_key, /* hook for DCP keys */
    };
    return &p;
}
