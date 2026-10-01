# Disc identification

Names the disc you insert, without typing anything.

| Disc | What you get | Source |
|------|--------------|--------|
| Audio CD | album, artist, year, track names, cover | [MusicBrainz](https://musicbrainz.org) and the [Cover Art Archive](https://coverartarchive.org) |
| DVD, Blu-ray, HD DVD, Video CD | film or series title and year | the disc label, looked up on [Wikidata](https://www.wikidata.org) |

The result appears in the control window: the disc name with year and cover on the **Titles** tab, and the
track names in the title list and next to the transport controls. If a CD carries CD-Text, Lumen shows that
on its own; this plugin replaces it with the MusicBrainz entry when one exists.

Needs **Lumen 0.2.1 or newer**. It is a script plugin: no native code, the same files on Windows, macOS and
Linux.

## What is sent where

Nothing is sent until a disc has been scanned. Then, once per disc:

- **Audio CD:** the MusicBrainz disc ID and the table of contents (track start positions) go to
  `musicbrainz.org`. If a cover exists, Lumen loads it from `coverartarchive.org`.
- **Video discs:** the tidied-up disc label (for example `THE_MATRIX_D1` becomes `The Matrix`) goes to
  `wikidata.org` as a search term.

No account, no API key. Both services see your IP address, as with any web request. Disable the plugin
in Lumen's **Plugins** tab to stop all lookups.

## Limits

- An audio CD is found only if someone has entered it into MusicBrainz. Unknown discs keep their
  generic track names.
- A CD opened as a folder of `.cda` files has no table of contents; use the drive itself or an image.
- Video discs are matched by label only. A disc labelled `DVD_VIDEO` cannot be identified, and a
  short or ambiguous label can match the wrong film. When Wikidata has no film for the label, the
  tidied label is shown instead (source "Disc label").

## Script interface used

The plugin shows how an mpv script talks to Lumen (see Lumen's `plugins/README.md`):

```lua
mp.register_script_message("lumen-event", function(event, json) ... end)          -- "disc", "file-loaded", ...
mp.commandv("script-message", "lumen-plugin", "http", reply_name, url)             -- answer: reply_name <status> <body>
mp.commandv("script-message", "lumen-plugin", "disc-info", json)                   -- title, artist, year, cover, tracks
mp.commandv("script-message", "lumen-plugin", "status", "disc-identify", "text")   -- line under the plugin's name
```
