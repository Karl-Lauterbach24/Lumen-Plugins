# My AACS Plugin

Plays encrypted Blu-rays in Lumen with software **you** already have: your MakeMKV installation, or your own
`libaacs` / `libbdplus` together with your key file. The plugin contains no decryption software and no keys.

| Part | File | What it does |
|------|------|--------------|
| Disc libraries | `plugin.json` → `discLibraries` | Makes **your own** `libaacs` / `libbdplus` available to libbluray. Both are marked `optional`, so the rest of the plugin also works without them. |
| Native C plugin | `src/my_decrypt_plugin.c` → `bin/<platform>/` | Finds MakeMKV and points libbluray at it, installs a `KEYDB.cfg` you drop onto the Lumen window, supplies DCP content keys from `dcp-keys.txt`. Buttons: **Refresh**, **MakeMKV on/off**, **Instructions**. |
| mpv script | `scripts/status.lua` | Passes a dropped `KEYDB.cfg` to the native part. Shows a Blu-ray notice with the disc title when a Blu-ray starts. |

Enable the plugin in the *Plugins* tab and restart Lumen. The line under the plugin's description shows what is used
for Blu-rays. The button **Instructions** shows the steps below with the folders of your system.

You are responsible for making sure that using such software and keys is legal where you live.

## Blu-ray: two ways

### A) MakeMKV

1. Install [MakeMKV](https://www.makemkv.com/) and open a disc in MakeMKV itself once. MakeMKV must be registered or
   in its trial period, and it does not begin the trial when another program asks for a disc.
2. In Lumen, click **Refresh** on the plugin (or restart Lumen).

The status then reads `Blu-ray: MakeMKV (…)`. There is nothing else to set up, and no key file is needed: MakeMKV
brings its own keys and also handles BD+.

The plugin looks for MakeMKV's library `libmmbd` here:

| System  | Place |
|---------|-------|
| Windows | `libmmbd64.dll` in `C:\Program Files (x86)\MakeMKV` or `C:\Program Files\MakeMKV` |
| macOS   | `/Applications/MakeMKV.app` (`Contents/lib/libmmbd_new.dylib`, older versions `libmmbd.dylib`) |
| Linux   | `libmmbd.so.0` in `/usr/lib`, `/usr/lib64`, `/usr/local/lib`, `/usr/lib/x86_64-linux-gnu` or `/usr/lib/aarch64-linux-gnu` |

MakeMKV somewhere else: enter the MakeMKV folder (or the library itself) as `makemkv_path` in `settings.txt`, see below.
MakeMKV has no library for Windows on ARM, so this way is not available there.

### B) Your own libaacs and your key file

1. Copy libraries you obtained yourself into the plugin's `lib/` folder: in Lumen, *Plugins → Open plugin folder*, then
   `my-aacs-handler/lib/`. Use exactly these file names, then restart Lumen:

   | System  | Files |
   |---------|-------|
   | Windows | `libaacs-0.dll`, `libbdplus.dll`, plus the DLLs they depend on, e.g. `libgcrypt-20.dll` and `libgpg-error-0.dll` |
   | macOS   | `libaacs.dylib`, `libbdplus.dylib` |
   | Linux   | `libaacs.so.0`, `libbdplus.so` |

2. Drag your `KEYDB.cfg` from the file manager onto the Lumen window. The plugin checks that it is an AACS key
   database and installs it where libaacs reads it:

   | System  | Place |
   |---------|-------|
   | Windows | `%APPDATA%\aacs\KEYDB.cfg` |
   | macOS   | `~/Library/Preferences/aacs/KEYDB.cfg` |
   | Linux   | `~/.config/aacs/KEYDB.cfg` (`$XDG_CONFIG_HOME/aacs/` if that is set) |

   The status then starts with `KEYDB.cfg installed in …`. A different file that was there before is kept as
   `KEYDB.cfg.bak`. The file may also be called `keydb_….cfg`; unpack a ZIP first.

   Instead of dropping the file you can put it into the plugin's config folder (`config/my-aacs-handler/` inside the
   plugin folder) and click **Refresh**: the plugin moves it to the place above. Dropping needs Lumen 1.0 or newer.

If `lib/` is empty and MakeMKV is not used, libbluray falls back to a libaacs installed on your system (common on
Linux). The dropped `KEYDB.cfg` works for it as well.

### Which one is used

| In place | Used |
|----------|------|
| MakeMKV only | MakeMKV |
| Your own libaacs in `lib/`, with or without MakeMKV | your own libaacs |

**MakeMKV on/off** switches between the two, or turns MakeMKV off altogether. The choice is remembered and applies to
the next disc you open, no restart needed.

Updating the plugin from the store replaces the plugin folder: copy your libraries into `lib/` again afterwards.
`KEYDB.cfg`, `settings.txt` and `dcp-keys.txt` are not touched by an update.

### If a disc does not open

Lumen's *Titles* tab shows what libbluray reports for the disc, for example `AACS · error -1`.

- **MakeMKV** (status `Blu-ray: MakeMKV`): open the disc in MakeMKV itself. What MakeMKV can't open there, it can't
  open for Lumen: trial period not started or over, key expired, a drive it can't use. Lumen started from a terminal
  with `MMBD_TRACE=1` in the environment prints MakeMKV's own messages.
- **Your own libaacs**: the disc needs an entry in your `KEYDB.cfg`, or keys in it that still work with this disc and
  your drive. With `BD_DEBUG_MASK=0x858` in the environment, libbluray and libaacs print what they try.

## DCP keys

Put `dcp-keys.txt` into `config/my-aacs-handler/` inside the plugin folder, with one pair per line:

```
# key id                               key
7762f777-5e04-472c-ba5e-b872bdb33542   02f2606491e04888de2ad43d1010aaee
```

Then click *Refresh*. The CPL in the *Kino* tab then shows "Keys from plugin".

## settings.txt

`config/my-aacs-handler/settings.txt` is written by **MakeMKV on/off** and can be edited by hand:

```
# auto = use MakeMKV unless your own libaacs is in lib/, on, off
makemkv = auto
# the MakeMKV folder or its libmmbd library, if the plugin does not find it
makemkv_path =
```

## How it works

- libbluray loads the library named by `LIBAACS_PATH` and `LIBBDPLUS_PATH` each time it opens a disc. Lumen sets both
  from `discLibraries` for the files in `lib/`. For MakeMKV, the native part sets them to MakeMKV's `libmmbd`, which
  stands in for libaacs and libbdplus and lets MakeMKV do the work.
- libbluray appends the file extension to that name itself. That is why the files in `lib/` need the names above
  (macOS: `libaacs.dylib`, not `libaacs.0.dylib`).
- An additional `"env": {"LIBAACS_PATH": "${pluginDir}/lib"}` would point libbluray at a folder instead of the library,
  so this plugin leaves it out.
- A file dropped onto the window reaches mpv as "play this file". The script recognises a key database by its name and
  hands it to the native part through the plugin's URL scheme (`aacskeydb://<path>`). The native part installs the file
  and answers with an empty playlist, so nothing is played and no error appears.
- `dcp_content_key` has the signature
  `int (*)(void *ctx, const uint8_t key_id[16], uint8_t key[16])` (see `include/lumen/plugin.h`). It returns 1 when it wrote
  a key, 0 otherwise.
- mpv scripts use mpv's own API (`mp.register_event`, `mp.add_hook`, `mp.get_property`, …). There is no `on_event` callback.
