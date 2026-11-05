# Corner widget

This fork of Ghostty adds a small widget to the top-right corner of every
terminal: the date, a big clock, the weather and the song playing in the room.

Click the record (the round album cover) to show the song's lyrics below
it, and click it again to hide them. The sheet scrolls; when the lyrics are
timed it follows the song, highlighting the current line, and returns to it
4 seconds after you scroll away.

It has two parts:

- **The widget** (`src/apprt/gtk/class/corner_widget.zig`,
  `src/apprt/gtk/ui/1.2/corner-widget.blp`, styles at the end of
  `src/apprt/gtk/css/style.css`). It only displays data, re-reading
  `$XDG_RUNTIME_DIR/ghostty-widget/state` once a second. Only the record and the
  open lyrics sheet take input; clicks and text selection anywhere else go
  straight through to the terminal.
- **The data service** (`widgetd.py`, run by `ghostty-widget.service`). It
  gets the weather from Open-Meteo every 10 minutes and, every 10 seconds,
  asks Shazam (through
  [SongRec](https://flathub.org/apps/re.fossplant.songrec)) what is playing,
  using the last 8 seconds from the microphone (if you set one up; music
  playing on this computer is read directly and always wins). The microphone stays open,
  so GNOME's microphone indicator stays on; only those 8 seconds are kept
  in memory, and each clip is deleted straight after. Song lengths come from
  the iTunes Search API, and lyrics from [LRCLIB](https://lrclib.net)
  (cached in `~/.cache/ghostty-widget/lyrics`).

## Build and install (Ubuntu)

```sh
sudo apt install libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev \
  blueprint-compiler gettext pkg-config libxml2-utils
# Zig 0.15.2 from https://ziglang.org/download/ (see build.zig.zon)

zig build -Doptimize=ReleaseFast -p ~/.local
```

## Data service

```sh
flatpak install --user flathub re.fossplant.songrec   # only for the microphone
mkdir -p ~/.local/share/ghostty-widget ~/.config/ghostty-widget
cp contrib/corner-widget/widgetd.py ~/.local/share/ghostty-widget/
cp contrib/corner-widget/ghostty-widget.service ~/.config/systemd/user/
```

Then put your settings in `~/.config/ghostty-widget/env`, for example:

```sh
WIDGET_CITY=Berlin
WIDGET_COUNTRY=DE
WIDGET_MIC=default
WIDGET_FOG=on
WIDGET_RIPPLE=on
```

- `WIDGET_CITY` / `WIDGET_COUNTRY`: where the weather is for. Leave the
  city out and the widget shows no weather.
- `WIDGET_MIC`: the microphone used to recognise music in the room, either
  `default` or a source name from `pactl list short sources`. Leave it out
  and the microphone is never opened: the widget then only shows what this
  computer is playing (Spotify, a browser tab, any MPRIS player), and
  SongRec isn't needed.

```sh
systemctl --user daemon-reload
systemctl --user enable --now ghostty-widget
```

- `WIDGET_FOG`: the glyph fog background (`glyph_fog.glsl`): faint streams
  of characters, blue by day and red in the evening, leaning red over SSH.
  `off` turns it off. On by default.
- `WIDGET_RIPPLE`: the fog's faint ripple where you click. `off` keeps the
  fog without it. On by default.

For the fog, also copy the shader and add one line to Ghostty's config
(`~/.config/ghostty/config`):

```sh
cp contrib/corner-widget/glyph_fog.glsl ~/.local/share/ghostty-widget/
echo 'config-file = ?~/.local/share/ghostty-widget/shaders.conf' >> ~/.config/ghostty/config
```

The service writes that file and makes Ghostty reload when the fog
settings change.

After changing the settings: `systemctl --user restart ghostty-widget`.
Timings are at the top of `widgetd.py`.

## Other fork additions

- **Shader inputs.** Stock Ghostty declares `iDate` and `iMouse` for custom
  shaders but leaves them at zero. Here `iDate` is (year, month 0-11, day,
  local seconds since midnight) and `iMouse` is (x, y, iTime of the click, 1)
  for the latest left click, y from the bottom like `gl_FragCoord`, and
  `iRemote` (below) is new.
- **SSH awareness.** A terminal whose title looks like an SSH session
  (`ssh ...`, `mosh ...`, or `user@host` for a host other than this
  computer) gets a red strip along the top with the server name hanging
  from it, its tab gets the `remote` CSS class so it can be styled through
  `gtk-custom-css`, and custom shaders get `iRemote.x = 1`
  (`src/apprt/gtk/remote.zig`).

## Updating to a new Ghostty release

```sh
contrib/update-fork.sh
```

It fetches Ghostty's releases, replays the fork's commits onto the newest
`vX.Y.Z` tag, installs the Zig version that release needs, builds, installs
to `~/.local` and pushes. If the fork's changes conflict with the release it
stops and explains how to continue. Then quit Ghostty completely
(`pkill -x ghostty`) and reopen it.
