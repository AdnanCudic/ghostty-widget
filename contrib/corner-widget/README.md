# Corner widget

This fork of Ghostty adds a small widget to the top-right corner of every
terminal: the date, a big clock, the weather and the song playing in the room.

It has two parts:

- **The widget** (`src/apprt/gtk/class/corner_widget.zig`,
  `src/apprt/gtk/ui/1.2/corner-widget.blp`, styles at the end of
  `src/apprt/gtk/css/style.css`). It only displays data, re-reading
  `$XDG_RUNTIME_DIR/ghostty-widget/state` once a second. It never takes
  input, so clicks and text selection go straight through to the terminal.
- **The data service** (`widgetd.py`, run by `ghostty-widget.service`). It
  gets the weather from Open-Meteo every 10 minutes and, every 10 seconds,
  asks Shazam (through
  [SongRec](https://flathub.org/apps/re.fossplant.songrec)) what is playing,
  using the last 8 seconds from the microphone. The microphone stays open,
  so GNOME's microphone indicator stays on; only those 8 seconds are kept
  in memory, and each clip is deleted straight after. Song lengths come from
  the iTunes Search API.

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

## Updating to a new Ghostty release

The fork's changes live on the `widget` branch on top of an upstream tag.

```sh
git remote add upstream https://github.com/ghostty-org/ghostty.git  # once
git fetch upstream --tags
git rebase --onto vX.Y.Z v1.3.1 widget   # replace with the new and old tags
zig build -Doptimize=ReleaseFast -p ~/.local
```
