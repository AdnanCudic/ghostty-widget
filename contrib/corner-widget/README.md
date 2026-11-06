# Corner widget (Windows)

This fork of the Windows Ghostty port adds a small widget to the top-right
corner of every terminal: the date, a big clock, the weather and the song
playing on this computer, with its album cover drawn as a record and the
song's progress as a ring around it.

Click the record to show the song's lyrics below it, and click it again to
hide them. The sheet scrolls with the mouse wheel. When the lyrics are timed,
it follows the song, highlights the current line, and returns to it 4 seconds
after you scroll away. Only the record and the open sheet take the mouse;
clicks and text selection anywhere else go straight through to the terminal.

It has two parts:

- **The widget** (`src/apprt/win32/CornerWidget.zig`). It is drawn with GDI+
  into a transparent layered window that follows each terminal, the same
  technique the port uses for its scrollbar. It only displays data: it
  re-reads `%LOCALAPPDATA%\ghostty-widget\state` once a second.
- **The data service** (`widgetd.py`, started at logon by `install.ps1`).
  It gets the weather from Open-Meteo every 10 minutes and reads what this
  computer is playing (Spotify, a browser tab, anything that appears in the
  Windows volume flyout) from Windows' media sessions. Song lengths that
  the player doesn't report come from the iTunes Search API. Lyrics come
  from [LRCLIB](https://lrclib.net) and are cached in
  `%LOCALAPPDATA%\ghostty-widget\lyrics`.

## Build Ghostty

You need [Zig 0.17](https://ziglang.org/download/) (the version in
`build.zig.zon`) on `PATH`. In PowerShell, from the repository:

```powershell
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

This produces `zig-out\bin\ghostty.exe`. Keep it together with
`conpty.dll`, `OpenConsole.exe` and the `zig-out\share` folder. You can also
build from WSL with the same command.

## Install the data service

You need Python 3 from [python.org](https://www.python.org/downloads/windows/).
Then run:

```powershell
powershell -ExecutionPolicy Bypass -File contrib\corner-widget\install.ps1
```

It:

- installs the Python package for Windows media sessions (`winsdk` on
  Python 3.12 and older, the `winrt-*` packages on newer versions);
- copies `widgetd.py` and `glyph_fog.glsl` to `%LOCALAPPDATA%\ghostty-widget`;
- registers a Task Scheduler task, **ghostty-widget**, that runs the service
  hidden (`pythonw.exe`) at every logon, and starts it now;
- sets up Ghostty's config (`%LOCALAPPDATA%\ghostty\config.ghostty`). If you
  have no config yet, it copies [`config.ghostty`](../ghostty-config/config.ghostty);
  otherwise it adds the line that loads the fog settings. Use `-NoConfig`
  to leave your config alone.

The settings are in `%LOCALAPPDATA%\ghostty-widget\env`:

```ini
WIDGET_CITY=Sarajevo
WIDGET_COUNTRY=BA
WIDGET_FOG=on
WIDGET_RIPPLE=on
```

- `WIDGET_CITY` / `WIDGET_COUNTRY`: where the weather is for. Leave the city
  empty and the widget shows no weather.
- `WIDGET_FOG`: the glyph fog background (`glyph_fog.glsl`): faint streams
  of characters, blue by day and red in the evening, redder over SSH.
  `off` turns it off. On by default.
- `WIDGET_RIPPLE`: the fog's faint ripple where you click. `off` keeps the
  fog without the ripple. On by default.

After editing the settings, run `install.ps1` again. It restarts the service,
and running Ghostty windows reload the fog settings by themselves. Any
problems are written to `%LOCALAPPDATA%\ghostty-widget\widgetd.log`. To
remove the service: `install.ps1 -Uninstall`.

The fog settings reach Ghostty through this line in its config (the
installer adds it):

```
config-file = ?../ghostty-widget/shaders.conf
```

For the intended look, install the [Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk)
font (the static Light, Regular and Medium files). Without it, the widget
uses Segoe UI.

## Drop-down terminal

The included config opens a quake-style terminal from the top of the screen
with the key left of `1` (`¸` on a Bosnian/Croatian keyboard). It works from
any program, with no modifier, and the widget and fog work there too:

```
keybind = global:backquote=toggle_quick_terminal
quick-terminal-position = top
quick-terminal-size = 40%
quick-terminal-autohide = true
```

`backquote` means the key's position, so it is the same key on every
keyboard layout. While Ghostty runs, that key no longer types in other
programs.

## Other fork additions

- **Shader inputs.** Upstream Ghostty declares `iDate` and `iMouse` for
  custom shaders but leaves them at zero. Here `iDate` is (year, month 0-11,
  day, local seconds since midnight), and `iMouse` is (x, y, iTime of the
  click, 1) for the latest left click, with y measured from the bottom like
  `gl_FragCoord`. `iRemote` is new (see below).
- **SSH awareness.** A terminal whose title looks like an SSH session gets a
  red strip along the top with the server name, its tab turns red, and
  custom shaders get `iRemote.x = 1`. "Looks like an SSH session" means
  `ssh ...`, `ssh.exe ...` or `mosh ...`, or `user@host` for a host other
  than this computer. The PowerShell integration shows the running command
  in the title, so `ssh server` is recognised right away.
- **Config reload from outside.** A program can broadcast the registered
  window message `GhosttyReloadConfig` to make running Ghostty windows
  reload their config. This is the Windows replacement for `SIGUSR2`, and
  the service uses it.
