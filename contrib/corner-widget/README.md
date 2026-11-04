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
  using the last 8 seconds from the microphone. The microphone stays open,
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
flatpak install --user flathub re.fossplant.songrec
mkdir -p ~/.local/share/ghostty-widget
cp contrib/corner-widget/widgetd.py ~/.local/share/ghostty-widget/
cp contrib/corner-widget/ghostty-widget.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ghostty-widget
```

City, microphone and timings are set at the top of `widgetd.py`.

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
