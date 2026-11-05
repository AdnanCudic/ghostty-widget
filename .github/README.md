# Ghostty, with a widget

A personal fork of [Ghostty](https://github.com/ghostty-org/ghostty) (Linux,
GTK) that adds:

- **A corner widget** in every terminal: the date, a big clock, the weather,
  and the song that's playing, with its album cover drawn as a record and
  the song's progress as a ring around it. Music comes from any player on
  the computer (Spotify, a browser tab), or from the microphone through
  Shazam if you set one up.
- **Lyrics.** Click the record to open them below; they follow the song.
- **SSH awareness.** A terminal connected to any server gets a red strip at
  the top with the server's name, its tab turns red and the fog leans red.
  It works out which host is "this computer" from your hostname, so
  nothing to configure.
- **Glyph fog**: a faint background of drifting characters, blue by day,
  turning red through the afternoon, with a barely visible ripple where you
  click. Each part can be switched off.
- **A sleek window**: no titlebar or buttons, and minimal "pill" tabs that
  only appear once there are two.

Everything Ghostty does is unchanged. For Ghostty itself see
[its README](../README.md) and [docs](https://ghostty.org/docs).

## Install

You need Ubuntu (or another GNOME desktop) and the build tools:

```sh
sudo apt install libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev \
  blueprint-compiler gettext pkg-config libxml2-utils
```

plus [Zig](https://ziglang.org/download/) at the version named in
`build.zig.zon`. Then:

```sh
zig build -Doptimize=ReleaseFast -p ~/.local
```

This installs `~/.local/bin/ghostty` and an app launcher that uses it. Quit
any running Ghostty completely before starting the new one.

1. **Widget data service** (weather, music, lyrics, fog): see
   [contrib/corner-widget](../contrib/corner-widget/README.md). Your city,
   microphone and the fog switches go in `~/.config/ghostty-widget/env`.
2. **Config**: copy [`config`](../contrib/ghostty-config/config) and
   [`tabs.css`](../contrib/ghostty-config/tabs.css) from
   `contrib/ghostty-config` to `~/.config/ghostty/`.

To move to a newer Ghostty release later: `contrib/update-fork.sh`.

## Keys

With the included config. `ctrl+shift+p` opens the command palette, which
lists everything else.

| Keys | Does |
|---|---|
| `ctrl+shift+t` | New tab |
| `ctrl+shift+[` / `ctrl+shift+]` | Previous / next tab |
| `ctrl+tab` / `ctrl+shift+tab` | Next / previous tab |
| `alt+1` … `alt+8`, `alt+9` | Go to tab 1–8, last tab |
| `ctrl+shift+w` | Close tab |
| `ctrl+shift+-` | Split down |
| `ctrl+shift+=` | Split right |
| `ctrl+shift+←` `→` `↑` `↓` | Move to the split in that direction |
| `ctrl+shift+enter` | Zoom the current split (again to unzoom) |
| `ctrl+shift+x` | Close the current split (or tab, if it's the last one) |
| `ctrl+shift+c` / `ctrl+shift+v` | Copy / paste |
| `ctrl+shift+f` | Search the scrollback |
| `shift+page up` / `shift+page down` | Scroll a page |
| `ctrl+=` / `ctrl+-` / `ctrl+0` | Bigger / smaller / reset text |
| `ctrl+shift+n` | New window |
| `ctrl+shift+p` | Command palette |
| `ctrl+,` / `ctrl+shift+,` | Open / reload the config |

Mouse: select text to copy it, middle-click a tab to close it, click the
record in the corner for lyrics.

## Drop-down terminal (optional)

Ghostty works well as a drop-down terminal with the
[Quake Terminal](https://extensions.gnome.org/extension/6307/quake-terminal/)
GNOME extension. The settings used here:

| Setting | Value |
|---|---|
| Terminal application | Ghostty |
| Shortcut | `` ` `` (the key left of 1) |
| Animation time | 0 |
| Vertical size | 70% |
| Horizontal size | 100% |
| Always on top | On |
| Show on current display | On |

If the shortcut stops opening Ghostty after you reinstall it, quit Ghostty
completely (`pkill -x ghostty`) and turn the extension off and on again.

## License

MIT, like Ghostty. See [LICENSE](../LICENSE).
