/*
 * Lumen plugin API (C ABI)
 *
 * A plugin is a folder with a manifest "plugin.json" (see plugins/README.md).
 * It may contain a native library that exports
 *
 *     LUMEN_PLUGIN_EXPORT const lumen_plugin *lumen_plugin_entry(void);
 *
 * Lumen itself contains no copy-protection circumvention. Plugins are
 * installed and enabled by the user, who is responsible for complying with
 * the law that applies to them.
 *
 * Rules
 *  - All structs start with a size field; Lumen and plugins only read fields
 *    that fit into the size the other side reports (forward compatible).
 *  - Host functions may be called from the thread that called into the
 *    plugin (init/on_event/on_action run on the GUI thread).
 *  - Stream callbacks and dcp_content_key are called from worker threads and
 *    must be thread-safe.
 *  - Strings are UTF-8. Strings returned by the host must be released with
 *    host->free_string().
 */
#ifndef LUMEN_PLUGIN_H
#define LUMEN_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUMEN_PLUGIN_API_VERSION 1

#if defined(_WIN32)
#define LUMEN_PLUGIN_EXPORT __declspec(dllexport)
#else
#define LUMEN_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

enum lumen_log_level {
    LUMEN_LOG_ERROR = 0,
    LUMEN_LOG_WARN = 1,
    LUMEN_LOG_INFO = 2,
    LUMEN_LOG_DEBUG = 3
};

/* Functions Lumen offers to a plugin. */
typedef struct lumen_host {
    uint32_t struct_size;
    uint32_t api_version;
    void *ctx; /* pass as first argument */

    void (*log)(void *ctx, int level, const char *message);
    /* mpv command, NULL-terminated argument list, e.g. {"show-text", "Hi", NULL}. 0 = ok */
    int (*command)(void *ctx, const char **args);
    /* mpv property as string (NULL if unavailable); release with free_string */
    char *(*get_property)(void *ctx, const char *name);
    int (*set_property)(void *ctx, const char *name, const char *value);
    void (*free_string)(void *ctx, char *s);
    /* On-screen message in the player window */
    void (*show_text)(void *ctx, const char *text, int duration_ms);
    /* Button in the plugin's entry in the control window; triggers on_action(id) */
    int (*add_action)(void *ctx, const char *id, const char *label);
    /* Status line shown under the plugin's name */
    void (*set_status)(void *ctx, const char *text);
    /* Folder of the plugin and a writable folder for its settings */
    const char *(*plugin_dir)(void *ctx);
    const char *(*config_dir)(void *ctx);
    /* Open a file/URL in the player (like the "Open" button) */
    int (*open)(void *ctx, const char *url);
} lumen_host;

/* A readable stream behind one of the plugin's URL schemes (mirrors mpv's stream_cb). */
typedef struct lumen_stream {
    uint32_t struct_size;
    void *cookie;
    /* bytes read, 0 = end, -1 = error */
    int64_t (*read)(void *cookie, char *buf, uint64_t size);
    /* new position or -1 (NULL = not seekable) */
    int64_t (*seek)(void *cookie, int64_t offset);
    /* total size or -1 if unknown (NULL = unknown) */
    int64_t (*size)(void *cookie);
    void (*close)(void *cookie);
} lumen_stream;

typedef struct lumen_plugin {
    uint32_t struct_size;
    uint32_t api_version; /* LUMEN_PLUGIN_API_VERSION */

    /* Called once after loading; the returned pointer is passed back as ctx.
       Return NULL to refuse loading (set a status with host->set_status first). */
    void *(*init)(const lumen_host *host);
    void (*shutdown)(void *ctx);

    /* Player events, payload is a JSON object:
       "file-loaded"  {"path", "kind", "title"}
       "end-file"     {"path"}
       "disc"         {"device", "kind", "label"}  (disc inserted / scanned)
       "shutdown"     {} */
    void (*on_event)(void *ctx, const char *event, const char *json);
    void (*on_action)(void *ctx, const char *action_id);

    /* Own URL schemes ("myscheme" for "myscheme://..."), NULL-terminated list or NULL */
    const char *const *schemes;
    /* Open a stream for one of the schemes. 0 = ok, fill *out. */
    int (*stream_open)(void *ctx, const char *url, lumen_stream *out);

    /* DCP: content key for a key id (both 16 bytes). Called when no KDM
       delivered the key. 1 = key written, 0 = unknown. */
    int (*dcp_content_key)(void *ctx, const uint8_t key_id[16], uint8_t key[16]);
} lumen_plugin;

typedef const lumen_plugin *(*lumen_plugin_entry_fn)(void);

#ifdef __cplusplus
}
#endif

#endif /* LUMEN_PLUGIN_H */
