# My AACS Plugin

A plugin that combines all three kinds of Lumen plugins:

| Part | File | What it does |
|------|------|--------------|
| Disc libraries | `plugin.json` → `discLibraries` | Makes **your own** `libaacs` / `libbdplus` available to libbluray. Both are marked `optional`, so the rest of the plugin also works without them. |
| Native C plugin | `src/my_decrypt_plugin.c` → `bin/<platform>/` | Supplies DCP content keys from `dcp-keys.txt` when no KDM delivers them. Adds a **Refresh DCP Keys** button. |
| mpv script | `scripts/status.lua` | Shows a Blu-ray notice with the disc title when a Blu-ray starts. |

## Adding your libraries

This plugin contains **no** decryption libraries. Copy libraries you obtained yourself into the plugin's `lib/`
folder: in Lumen, open the plugin folder from *Plugins → Open plugin folder*, then go to `my-aacs-handler/lib/`.

| System  | Files |
|---------|-------|
| Windows | `libaacs-0.dll`, `libbdplus.dll`, plus the DLLs they depend on, e.g. `libgcrypt-20.dll` and `libgpg-error-0.dll` |
| macOS   | `libaacs.0.dylib`, `libbdplus.dylib` |
| Linux   | `libaacs.so.0`, `libbdplus.so` |

libaacs also needs its key database (`KEYDB.cfg`) in its usual location. Then enable the plugin and restart Lumen.
The plugin card shows whether the libraries were found.

You are responsible for making sure that using such libraries is legal where you live.

## DCP keys

Put `dcp-keys.txt` into `config/my-aacs-handler/` inside the plugin folder, with one pair per line:

```
# key id                               key
7762f777-5e04-472c-ba5e-b872bdb33542   02f2606491e04888de2ad43d1010aaee
```

Then click *Refresh DCP Keys*. The CPL in the *Kino* tab then shows "Keys from plugin".

## Notes on the example this is based on

- Lumen sets `LIBAACS_PATH` itself from `discLibraries`. An additional `"env": {"LIBAACS_PATH": "${pluginDir}/lib"}` would
  point libbluray at a folder instead of the library, so this plugin leaves it out.
- `dcp_content_key` has the signature
  `int (*)(void *ctx, const uint8_t key_id[16], uint8_t key[16])` (see `include/lumen/plugin.h`). It returns 1 when it wrote
  a key, 0 otherwise.
- mpv scripts use mpv's own API (`mp.register_event`, `mp.get_property`, …). There is no `on_event` callback.
