#!/usr/bin/env python3
"""Background service for the Ghostty corner widget (Windows).

Collects the weather (Open-Meteo, no API key) and what this computer is
playing (Windows' media sessions: Spotify, a browser tab, any app that
shows up in the volume flyout), with its album cover and lyrics (LRCLIB,
no API key; timed when available). Song lengths the player doesn't report
come from the iTunes Search API. Everything goes into a small state file
that Ghostty's corner widget (src/apprt/win32/CornerWidget.zig) reads
every second.

Runs hidden at logon under pythonw.exe (install.ps1 sets that up as a
Task Scheduler task). Needs `winsdk` (Python up to 3.12) or the `winrt-*`
packages (any Python) for the media sessions; the rest is standard library.

Settings come from %LOCALAPPDATA%\\ghostty-widget\\env (KEY=value lines;
real environment variables override them):

  WIDGET_CITY     city for the weather, e.g. "Sarajevo"; unset = no weather
  WIDGET_COUNTRY  two-letter country code to pick the right city, e.g. "BA"
  WIDGET_FOG      on/off: the glyph fog background shader (default on)
  WIDGET_RIPPLE   on/off: the fog's faint ripple where you click (default on)

For the fog, Ghostty's config needs this line (the service writes that file
and tells Ghostty to reload when the settings change):

  config-file = ?../ghostty-widget/shaders.conf
"""

import asyncio
import ctypes
import hashlib
import json
import os
import re
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# --- PATHS ---
DATA_DIR = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "ghostty-widget")
ENV_FILE = os.path.join(DATA_DIR, "env")
STATE = os.path.join(DATA_DIR, "state")
COVER = os.path.join(DATA_DIR, "cover")
LYRICS = os.path.join(DATA_DIR, "current-lyrics.txt")
LYRICS_CACHE = os.path.join(DATA_DIR, "lyrics")
GEO_CACHE = os.path.join(DATA_DIR, "location.json")
LOG = os.path.join(DATA_DIR, "widgetd.log")
# The shader ships next to this script; the copy Ghostty uses, with the
# settings applied, and the config snippet that loads it go in DATA_DIR.
SHADER_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "glyph_fog.glsl")
SHADER = os.path.join(DATA_DIR, "glyph_fog.active.glsl")
SHADER_CONF = os.path.join(DATA_DIR, "shaders.conf")


def load_settings():
    """KEY=value lines from ENV_FILE, then the real environment on top."""
    settings = {}
    try:
        with open(ENV_FILE, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                settings[key.strip()] = value.strip().strip("\"'")
    except OSError:
        pass
    for key in ("WIDGET_CITY", "WIDGET_COUNTRY", "WIDGET_FOG", "WIDGET_RIPPLE"):
        if os.environ.get(key):
            settings[key] = os.environ[key]
    return settings


SETTINGS = load_settings()


def switch(name, default=True):
    value = SETTINGS.get(name, "").strip().lower()
    return default if not value else value in ("1", "on", "yes", "true")


# --- CONFIGURATION ---
CITY = SETTINGS.get("WIDGET_CITY", "").strip()
COUNTRY_CODE = SETTINGS.get("WIDGET_COUNTRY", "").strip().upper()
FOG = switch("WIDGET_FOG")
RIPPLE = switch("WIDGET_RIPPLE")
WEATHER_EVERY = 600   # seconds between weather updates
TICK = 1              # seconds between state writes / player checks

WMO = {  # weather code -> (symbol, words)
    0: ("☀", "clear"), 1: ("☀", "mostly clear"), 2: ("☁", "partly cloudy"), 3: ("☁", "overcast"),
    45: ("≡", "fog"), 48: ("≡", "fog"),
    51: ("☂", "drizzle"), 53: ("☂", "drizzle"), 55: ("☂", "drizzle"), 56: ("☂", "drizzle"), 57: ("☂", "drizzle"),
    61: ("☂", "light rain"), 63: ("☂", "rain"), 65: ("☂", "heavy rain"), 66: ("☂", "icy rain"), 67: ("☂", "icy rain"),
    71: ("❄", "light snow"), 73: ("❄", "snow"), 75: ("❄", "heavy snow"), 77: ("❄", "snow"),
    80: ("☂", "showers"), 81: ("☂", "showers"), 82: ("☂", "heavy showers"),
    85: ("❄", "snow showers"), 86: ("❄", "snow showers"),
    95: ("ϟ", "thunderstorm"), 96: ("ϟ", "thunderstorm"), 99: ("ϟ", "thunderstorm"),
}

SONG_KEYS = ("s_title", "s_artist", "s_pos0", "s_at", "s_pos_ms", "s_at_ms", "s_len",
             "s_cover", "s_cover_rev", "s_key", "s_src", "s_lyrics_rev")


def log(msg):
    """pythonw has no console: append to a small log file instead."""
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 256 * 1024:
            os.replace(LOG, LOG + ".old")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "ghostty-widget/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def write_text(path, text):
    """Atomically replace `path` with UTF-8 text and \\n line endings."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


# --- WEATHER ---

def location():
    try:
        with open(GEO_CACHE, encoding="utf-8") as f:
            loc = json.load(f)
        if (loc.get("city"), loc.get("country")) == (CITY, COUNTRY_CODE):
            return loc
    except (OSError, ValueError):
        pass
    q = urllib.parse.urlencode({"name": CITY, "count": 10, "format": "json"})
    res = get_json(f"https://geocoding-api.open-meteo.com/v1/search?{q}").get("results", [])
    res = [r for r in res if r.get("country_code") == COUNTRY_CODE] or res
    loc = {"city": CITY, "country": COUNTRY_CODE,
           "lat": res[0]["latitude"], "lon": res[0]["longitude"]}
    write_text(GEO_CACHE, json.dumps(loc))
    return loc


def weather():
    loc = location()
    q = urllib.parse.urlencode({
        "latitude": loc["lat"], "longitude": loc["lon"],
        "current": "temperature_2m,weather_code,wind_speed_10m",
        "wind_speed_unit": "kmh", "timezone": "auto",
    })
    cur = get_json(f"https://api.open-meteo.com/v1/forecast?{q}")["current"]
    sym, words = WMO.get(int(cur["weather_code"]), ("·", ""))
    return {
        "w_sym": sym,
        "w_temp": str(round(cur["temperature_2m"])),
        "w_text": words,
        "w_wind": str(round(cur["wind_speed_10m"])),
    }


# --- NOW PLAYING (Windows media sessions) ---

try:  # winsdk: Python 3.8-3.12
    from winsdk.windows.media.control import (
        GlobalSystemMediaTransportControlsSessionManager as MediaManager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
    )
    from winsdk.windows.storage.streams import DataReader
except ImportError:
    try:  # the modular winrt-* packages: any Python 3
        from winrt.windows.media.control import (
            GlobalSystemMediaTransportControlsSessionManager as MediaManager,
            GlobalSystemMediaTransportControlsSessionPlaybackStatus as PlaybackStatus,
        )
        from winrt.windows.storage.streams import DataReader
    except ImportError:
        MediaManager = None


class Player:
    """Reads what's playing from Windows' media sessions (the same ones the
    volume flyout shows)."""

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.manager = None
        if MediaManager is None:
            log("winsdk/winrt not installed: no music (see README)")

    def now_playing(self):
        """Song fields plus "cover_bytes" (or None), or None when nothing plays."""
        if MediaManager is None:
            return None
        try:
            return self.loop.run_until_complete(self._now_playing())
        except Exception:
            log("media session error:\n" + traceback.format_exc())
            self.manager = None  # reconnect next time
            return None

    async def _now_playing(self):
        if self.manager is None:
            self.manager = await MediaManager.request_async()
        sessions = list(self.manager.get_sessions())
        current = self.manager.get_current_session()
        if current is not None:  # the one Windows considers current first
            ids = [s.source_app_user_model_id for s in sessions]
            if current.source_app_user_model_id in ids:
                sessions.insert(0, sessions.pop(ids.index(current.source_app_user_model_id)))
        for session in sessions:
            info = session.get_playback_info()
            if info is None or info.playback_status != PlaybackStatus.PLAYING:
                continue
            props = await session.try_get_media_properties_async()
            if props is None or not props.title:
                continue
            timeline = session.get_timeline_properties()
            length = position = 0.0
            read_at = time.time()
            if timeline is not None:
                length = (timeline.end_time - timeline.start_time).total_seconds()
                position = (timeline.position - timeline.start_time).total_seconds()
                # The position is from when the player last reported it.
                updated = timeline.last_updated_time
                if updated is not None and updated.year > 2000:
                    if updated.tzinfo is None:
                        updated = updated.replace(tzinfo=timezone.utc)
                    position += max(0.0, (datetime.now(timezone.utc) - updated).total_seconds())
                if length > 0:
                    position = min(position, length)
            return {
                "s_title": props.title,
                "s_artist": props.artist or props.album_artist or "",
                "s_len": round(length) if length > 0 else 0,
                "s_pos0": round(position),
                "s_pos_ms": round(position * 1000),
                "s_at_ms": round(read_at * 1000),
                "thumbnail": props.thumbnail,
                "app": session.source_app_user_model_id,
            }
        return None

    def read_thumbnail(self, ref):
        if ref is None:
            return None
        try:
            return self.loop.run_until_complete(self._read_thumbnail(ref))
        except Exception:
            log("album cover error:\n" + traceback.format_exc())
            return None

    @staticmethod
    async def _read_thumbnail(ref):
        stream = await ref.open_read_async()
        size = int(stream.size)
        if size <= 0 or size > 8 * 1024 * 1024:
            return None
        reader = DataReader(stream.get_input_stream_at(0))
        await reader.load_async(size)
        data = bytearray(size)
        reader.read_bytes(data)
        return bytes(data)


# --- SONG LENGTH AND COVER FALLBACK (iTunes Search API) ---

def itunes_lookup(title, artist):
    """(length in seconds or None, cover URL or "") from the iTunes Search API
    (free, no key)."""
    q = urllib.parse.urlencode({"term": f"{artist} {title}", "entity": "song", "limit": 10})
    try:
        res = get_json(f"https://itunes.apple.com/search?{q}").get("results", [])
    except Exception:
        return None, ""
    res = [r for r in res if r.get("trackTimeMillis")]
    # exact title first (keeps "Extended" / "Remix" versions apart), then the base title
    hit = next((r for r in res if r.get("trackName", "").lower() == title.lower()), None)
    if hit is None:
        base = title.lower().split(" (")[0].split(" [")[0]
        hit = next((r for r in res if base in r.get("trackName", "").lower()), None)
    if hit is None:
        return None, ""
    art = (hit.get("artworkUrl100") or "").replace("100x100bb", "300x300bb")
    return round(hit["trackTimeMillis"] / 1000), art


def download(url):
    if not url:
        return None
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ghostty-widget/1.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.read(8 * 1024 * 1024)
    except Exception:
        return None


def save_cover(data):
    """Writes the album cover for the widget; returns its path or ""."""
    if not data:
        return ""
    try:
        tmp = COVER + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, COVER)
        return COVER
    except OSError:
        return ""


# --- LYRICS (LRCLIB) ---

# Words that YouTube-style titles add around the song name.
VIDEO_WORDS = re.compile(
    r"\s*[(\[][^)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|remaster(ed)?|hd|4k|mv|live)\b[^)\]]*[)\]]",
    re.IGNORECASE)


def lyric_candidates(title, artist):
    """(title, artist) pairs to try, cleanest first."""
    t = VIDEO_WORDS.sub("", title).strip()
    a = re.sub(r"\s*(- Topic|VEVO)$", "", artist).strip()
    out = [(t, a)]
    if " - " in t:  # "Artist - Song" uploaded by some channel
        left, right = t.split(" - ", 1)
        out.append((right.strip(), left.strip()))
    return out


def find_lyrics(title, artist, length):
    """("synced", [(ms, line)]), ("plain", [line]), ("instrumental", []) or ("none", [])."""
    best = None
    for t, a in lyric_candidates(title, artist):
        if not t:
            continue
        q = urllib.parse.urlencode({"track_name": t, "artist_name": a} if a else {"q": t})
        try:
            res = get_json(f"https://lrclib.net/api/search?{q}")
        except Exception:
            continue
        if length:  # skip other versions of the song (live, extended, ...)
            res = [r for r in res if abs((r.get("duration") or length) - length) <= 8] or res
        for r in res:
            if r.get("syncedLyrics"):
                best = r
                break
            if best is None and (r.get("plainLyrics") or r.get("instrumental")):
                best = r
        if best and best.get("syncedLyrics"):
            break
    if not best:
        return "none", []
    if best.get("syncedLyrics"):
        lines = []
        for raw in best["syncedLyrics"].splitlines():
            m = re.match(r"\[(\d+):(\d+(?:\.\d+)?)\](.*)", raw)
            if m:
                ms = round((int(m[1]) * 60 + float(m[2])) * 1000)
                lines.append((ms, m[3].strip()))
        return "synced", lines
    if best.get("instrumental"):
        return "instrumental", []
    return "plain", best["plainLyrics"].splitlines()


class Lyrics:
    """Looks up the lyrics of each new song in the background and writes
    them to LYRICS: a first line saying synced/plain/instrumental/none, then
    one line per lyric line ("milliseconds<TAB>text" when synced)."""

    def __init__(self):
        self.key = None

    def update(self, state):
        if not state.get("s_title"):
            self.key = None  # song cleared (with its s_lyrics_rev): fetch again if it returns
            return
        key = f"{state['s_title']}|{state.get('s_artist', '')}"
        if key == self.key:
            return
        self.key = key
        args = (key, state["s_title"], state.get("s_artist", ""), int(state.get("s_len") or 0), state)
        threading.Thread(target=self.fetch, args=args, daemon=True).start()

    def fetch(self, key, title, artist, length, state):
        cache = os.path.join(LYRICS_CACHE, hashlib.sha1(key.encode()).hexdigest() + ".json")
        try:
            with open(cache, encoding="utf-8") as f:
                kind, lines = json.load(f)
        except (OSError, ValueError):
            kind, lines = find_lyrics(title, artist, length)
            if kind != "none":  # retry misses next time, the site grows
                os.makedirs(LYRICS_CACHE, exist_ok=True)
                write_text(cache, json.dumps([kind, lines]))
        if key != self.key:
            return  # the song changed meanwhile
        out = kind + "\n"
        for line in lines:
            if kind == "synced":
                out += f"{line[0]}\t{line[1]}\n"
            else:
                out += line.replace("\t", " ") + "\n"
        write_text(LYRICS, out)
        state["s_lyrics_rev"] = str(time.time_ns())  # tells the widget to reload


# --- FOG SHADER ---

def write_if_changed(path, text):
    try:
        with open(path, encoding="utf-8") as f:
            if f.read() == text:
                return False
    except OSError:
        pass
    write_text(path, text)
    return True


def reload_ghostty():
    """Ask every running Ghostty to reload its config (Windows has no
    SIGUSR2; Ghostty listens for this registered window message)."""
    if sys.platform != "win32":
        return
    user32 = ctypes.windll.user32
    user32.RegisterWindowMessageW.restype = ctypes.c_uint
    msg = user32.RegisterWindowMessageW("GhosttyReloadConfig")
    if msg:
        HWND_BROADCAST = 0xFFFF
        user32.PostMessageW(ctypes.c_void_p(HWND_BROADCAST), msg, 0, 0)


def apply_shader_settings():
    """Write the fog shader and the Ghostty config snippet for the current
    settings, and make running Ghostty reload its config if they changed."""
    conf = "# Written by the ghostty-widget service; set WIDGET_FOG / WIDGET_RIPPLE\n"
    conf += "# in %LOCALAPPDATA%\\ghostty-widget\\env instead of editing this.\n"
    changed = False
    if FOG:
        try:
            with open(SHADER_SRC, encoding="utf-8") as f:
                shader = f.read()
        except OSError:
            shader = None
            log(f"fog shader not found next to the service: {SHADER_SRC}")
        if shader is not None:
            if not RIPPLE:
                shader = re.sub(r"(const float CLICK_RIPPLE\s*=\s*)[0-9.]+", r"\g<1>0.0", shader)
            changed |= write_if_changed(SHADER, shader)
            # Forward slashes: Ghostty's config takes them on Windows too.
            conf += f"custom-shader = {SHADER.replace(os.sep, '/')}\ncustom-shader-animation = always\n"
    changed |= write_if_changed(SHADER_CONF, conf)
    if changed:
        reload_ghostty()


# --- MAIN LOOP ---

def write_state(state):
    # key/value line pairs; values never contain newlines
    write_text(STATE, "".join(f"{k}\n{str(v).replace(chr(10), ' ').replace(chr(13), ' ')}\n"
                              for k, v in state.items()))


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    log(f"started (city={CITY or '-'}, fog={'on' if FOG else 'off'}, ripple={'on' if RIPPLE else 'off'})")
    apply_shader_settings()
    player = Player()
    lyrics = Lyrics()
    state = {"updated": str(int(time.time()))}
    next_weather = 0.0
    while True:
        now = time.time()
        if CITY and now >= next_weather:
            try:
                state.update(weather())
                next_weather = now + WEATHER_EVERY
            except Exception:
                next_weather = now + 60  # offline: retry soon

        np = player.now_playing()
        if np:
            thumb = np.pop("thumbnail")
            app = np.pop("app")
            key = f"{np['s_title']}|{np['s_artist']}|{app}"
            if key != state.get("s_key"):
                # New song: cover from the player, else from iTunes; length
                # from iTunes when the player doesn't say (browsers often don't).
                cover = player.read_thumbnail(thumb)
                length, art_url = (None, "")
                if not np["s_len"] or not cover:
                    length, art_url = itunes_lookup(np["s_title"], np["s_artist"])
                state["s_cover"] = save_cover(cover or download(art_url))
                state["s_cover_rev"] = str(int(now))  # tells the widget to reload
                state["s_key"] = key
                state["s_len_fallback"] = str(length or 0)
            if not np["s_len"]:
                np["s_len"] = int(state.get("s_len_fallback") or 0)
            state.update({k: str(v) for k, v in np.items()})
            state["s_at"] = str(int(now))
            state["s_src"] = "player"
        elif state.get("s_src") == "player":
            # Player stopped or paused: clear the song.
            for k in SONG_KEYS + ("s_len_fallback",):
                state.pop(k, None)

        lyrics.update(state)
        state["updated"] = str(int(time.time()))
        try:
            write_state(dict(state))
        except OSError:
            pass  # the widget is reading it right now; next second
        time.sleep(TICK)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log("crashed:\n" + traceback.format_exc())
        raise
