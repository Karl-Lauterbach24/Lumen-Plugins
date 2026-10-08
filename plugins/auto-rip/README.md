# Auto rip

Copies disc after disc to MKV files with **your MakeMKV installation** and files them the way
Jellyfin, Plex, Emby and Kodi expect.

Nothing happens until you press **Start auto rip** in the plugin's entry (Plugins tab). Until then
Lumen plays discs as usual. After the start:

1. The disc in the drive is read. A film: the main feature is copied. A series disc: its episodes.
2. The files are named and moved into the library folders (below).
3. The disc is ejected.
4. Insert the next disc and close the drive: it is copied the same way. Go on until the pile is done,
   then press **Stop auto rip** – Lumen plays discs again.

While auto rip runs, Lumen neither scans nor plays the disc in the drive (MakeMKV needs it for
itself); the start page says so. Files, streams and images still play.

Needs **Lumen 1.4** or newer and **MakeMKV** (<https://www.makemkv.com>; the store plugin *My AACS
Plugin* can install it and keeps its beta key current). The plugin contains no decryption code: it
starts the `makemkvcon` program of your MakeMKV. **Copy only discs you own, and only where the law
lets you** – in many countries getting around a disc's copy protection is not allowed even for a
private copy.

## Where the files go

```
<output>/Movies/Alita - Battle Angel (2019)/Alita - Battle Angel (2019).mkv
<output>/Movies/Alita - Battle Angel (2019)/Alita - Battle Angel (2019) - 4K.mkv      (UHD disc)
<output>/Movies/Alita - Battle Angel (2019)/Alita - Battle Angel (2019) - 3D.mkv      (3D disc)
<output>/Shows/Class/Season 01/Class S01E01.mkv
<output>/Shows/Class/Season 01/Class S01E02.mkv
```

`<output>` is `Movies/Lumen Rips` in your home folder on macOS and `Videos/Lumen Rips` on Windows and
Linux unless you set another folder. Point Jellyfin's *Movies* library at `…/Movies` and its *Shows*
library at `…/Shows`.

- **Title and year** come from the disc's own name and a lookup on Wikidata (the disc's name is sent
  there). A hit of the wrong kind – a film for a series disc – is not used; then the name stands
  without a year. Switch the lookup off with `lookup = no`.
- **Film or series** is decided per disc: three or more titles of about the same length between 15 and
  75 minutes are episodes (two, if the disc's label names a season). A title as long as all of them
  together ("play all") is left out. Otherwise the longest title is the main feature; of several equally
  long ones the one with the most sound tracks and subtitles.
- **Season** comes from the disc's label (`CLASS_S1_D2`, `… SEASON 2 DISC 3`); without one it is season 1.
- **Episode numbers** continue from disc to disc: the plugin remembers per series and season which
  number comes next (`series.json` in the settings folder) and gives a disc the same numbers again when
  it comes back. Insert the discs of a season in order. The order on a disc is the order of its
  playlists, which is the episode order on most discs – check the first disc of a series.

## Settings

Button **Settings** opens the folder with `settings.txt` (restart Lumen after a change):

| Key | Default | Meaning |
|-----|---------|---------|
| `output` | *(see above)* | Folder for the copies |
| `movies_folder`, `shows_folder` | `Movies`, `Shows` | Sub-folders |
| `mode` | `auto` | `auto`, `movie` (always the main feature) or `episodes` (always all episodes) |
| `keep_3d` | `yes` | Blu-ray 3D: copy both views. `no` = MakeMKV's own choice, the 2D view |
| `min_length` | `120` | Seconds; shorter titles are never looked at |
| `episode_min`, `episode_max` | `15`, `75` | Minutes; how long an episode is |
| `eject` | `yes` | Eject the disc when it is done |
| `lookup` | `yes` | Title and year from Wikidata |
| `makemkvcon` | *(found by itself)* | Path of MakeMKV's `makemkvcon` |

## Good to know

- A Blu-ray takes 20 to 60 minutes, a UHD disc longer; the status line shows progress and the time left.
  You need as much free space as the film is large (25–90 GB).
- The copy is exactly what is on the disc (no re-encoding): all sound tracks and subtitles MakeMKV selects
  by default.
- **Blu-ray 3D:** MakeMKV by itself leaves out the second view. Auto rip adds it (a conversion profile for
  this one copy: MakeMKV's default profile with your selection rule plus `+sel:mvcvideo`), and the file is
  named `… - 3D.mkv`. It plays in 3D in Lumen and in 2D in players that know no 3D. With `keep_3d = no` the
  copy is 2D and carries no `- 3D`.
- If a disc cannot be copied, the status line says what MakeMKV reported, the disc stays in the drive,
  and auto rip waits for the next one.
- Stopping during a copy ends MakeMKV and removes the unfinished file.
- MakeMKV must be able to open the disc: registered or in its trial period (see *My AACS Plugin*).
