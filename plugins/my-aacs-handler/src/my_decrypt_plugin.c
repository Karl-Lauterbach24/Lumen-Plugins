/*
 * My AACS Plugin – native part: DCP content keys and a UI action.
 *
 * Lumen asks the plugin for a content key when no KDM delivered it
 * (dcp_content_key). Keys come from "dcp-keys.txt" in the plugin's config
 * folder (Lumen: Plugins tab -> plugin folder -> config/my-aacs-handler/),
 * one "<key id> <key>" pair per line (hex, UUID dashes allowed). The button
 * "Refresh DCP Keys" re-reads the file.
 *
 * Build: see README.md (CMake) – needs only include/lumen/plugin.h.
 */
#include "lumen/plugin.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_KEYS 256

typedef struct state {
    const lumen_host *host;
    int count;
    uint8_t ids[MAX_KEYS][16];
    uint8_t keys[MAX_KEYS][16];
} state;

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
    char path[1024], line[256], status[160];
    FILE *f;
    st->count = 0;
    snprintf(path, sizeof path, "%s/dcp-keys.txt", st->host->config_dir(st->host->ctx));
    f = fopen(path, "r");
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
    snprintf(status, sizeof status, "%d DCP key(s) loaded from dcp-keys.txt", st->count);
    st->host->set_status(st->host->ctx, status);
}

static void *init(const lumen_host *host)
{
    state *st = calloc(1, sizeof *st);
    if (!st)
        return NULL;
    st->host = host;
    /* Register a custom action button in the UI */
    host->add_action(host->ctx, "refresh_keys", "Refresh DCP Keys");
    host->log(host->ctx, LUMEN_LOG_INFO, "My Decrypt Plugin initialized");
    load_keys(st);
    return st;
}

static void plugin_shutdown(void *ctx)
{
    free(ctx);
}

static void on_action(void *ctx, const char *id)
{
    state *st = ctx;
    if (strcmp(id, "refresh_keys") == 0) {
        char text[96];
        load_keys(st);
        snprintf(text, sizeof text, "Keys refreshed: %d", st->count);
        st->host->show_text(st->host->ctx, text, 2000);
    }
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
        NULL,            /* schemes */
        NULL,            /* stream_open */
        dcp_content_key, /* hook for DCP keys */
    };
    return &p;
}
