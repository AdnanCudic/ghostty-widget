#!/usr/bin/env python3
"""Background service for the Ghostty corner widget.

Collects weather (Open-Meteo, no API key) and the song playing in the room
(mic clip -> SongRec -> Shazam) and writes them to a small state file that
Ghostty's corner widget (src/apprt/gtk/class/corner_widget.zig) reads every
second. Standard library only.
"""

import json
import os
import subprocess
import time
import urllib.parse
import urllib.request

# --- CONFIGURATION ---
CITY = "Tuzla"
COUNTRY_CODE = "BA"
MIC = "alsa_input.pci-0000_00_1f.3-platform-sof_sdw.HiFi__Mic__source"  # laptop mic; "" = system default
WEATHER_EVERY = 600   # seconds between weather updates
LISTEN_EVERY = 10     # seconds between song checks (start to start)
CLIP_SECONDS = 8      # length of each mic clip
FORGET_AFTER = 6      # misses in a row before the song is cleared (~1 min)

SONGREC = "re.fossplant.songrec"
RUN_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ghostty-widget")
STATE = os.path.join(RUN_DIR, "state")
CLIP = os.path.join(RUN_DIR, "clip.wav")
COVER = os.path.join(RUN_DIR, "cover.png")
CACHE_DIR = os.path.expanduser("~/.cache/ghostty-widget")
GEO_CACHE = os.path.join(CACHE_DIR, "location.json")

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


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "ghostty-widget/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def location():
    try:
        with open(GEO_CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    q = urllib.parse.urlencode({"name": CITY, "count": 10, "format": "json"})
    res = get_json(f"https://geocoding-api.open-meteo.com/v1/search?{q}").get("results", [])
    res = [r for r in res if r.get("country_code") == COUNTRY_CODE] or res
    loc = {"lat": res[0]["latitude"], "lon": res[0]["longitude"]}
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(GEO_CACHE, "w") as f:
        json.dump(loc, f)
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


def listen():
    """Record a clip and ask Shazam. Returns song fields, {} for no match, None on error."""
    cmd = ["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16"]
    if MIC:
        cmd += ["--target", MIC]
    try:
        subprocess.run(["timeout", str(CLIP_SECONDS)] + cmd + [CLIP], capture_output=True)
        started = time.time() - CLIP_SECONDS
        out = subprocess.run(
            ["flatpak", "run", "--filesystem=xdg-run/ghostty-widget:ro", SONGREC,
             "recognize", "--json", CLIP],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        try:
            os.remove(CLIP)  # never keep audio around
        except OSError:
            pass
    if "No match" in out.stderr:
        return {}
    try:
        data = json.loads(out.stdout)
    except ValueError:
        return None
    track = data.get("track") or {}
    if not track.get("title"):
        return {}
    offset = float((data.get("matches") or [{}])[0].get("offset", 0) or 0)
    images = track.get("images") or {}
    return {
        "cover_url": images.get("coverart") or images.get("background") or "",
        "s_title": track["title"],
        "s_artist": track.get("subtitle", ""),
        "s_pos0": str(round(offset)),           # song position at clip start, seconds
        "s_at": str(round(started)),            # unix time of clip start
    }


def song_length(title, artist):
    """Song length in seconds from the iTunes Search API (free, no key), or None."""
    q = urllib.parse.urlencode({"term": f"{artist} {title}", "entity": "song", "limit": 10})
    try:
        res = get_json(f"https://itunes.apple.com/search?{q}").get("results", [])
    except Exception:
        return None
    res = [r for r in res if r.get("trackTimeMillis")]
    # exact title first (keeps "Extended" / "Remix" versions apart), then the base title
    for r in res:
        if r.get("trackName", "").lower() == title.lower():
            return round(r["trackTimeMillis"] / 1000)
    base = title.lower().split(" (")[0].split(" [")[0]
    for r in res:
        if base in r.get("trackName", "").lower():
            return round(r["trackTimeMillis"] / 1000)
    return None


def fetch_cover(url):
    """Download the album cover and shrink it to a 128px PNG. Returns the path or ""."""
    if not url:
        return ""
    src = COVER + ".src"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ghostty-widget/1.0"})
        with urllib.request.urlopen(req, timeout=15) as r, open(src, "wb") as f:
            f.write(r.read())
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-i", src, "-vf", "scale=128:128", COVER + ".tmp.png"],
            check=True, timeout=30,
        )
        os.replace(COVER + ".tmp.png", COVER)
        return COVER
    except (OSError, subprocess.SubprocessError):
        return ""
    finally:
        try:
            os.remove(src)
        except OSError:
            pass


def write_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        for k, v in state.items():
            f.write(f"{k}\n{str(v).replace(chr(10), ' ')}\n")  # zsh reads key/value line pairs
    os.replace(tmp, STATE)


def main():
    os.makedirs(RUN_DIR, exist_ok=True)
    state = {"updated": str(int(time.time()))}
    next_weather = next_listen = 0.0
    misses = 0
    while True:
        now = time.time()
        if now >= next_weather:
            try:
                state.update(weather())
                next_weather = now + WEATHER_EVERY
            except Exception:
                next_weather = now + 60  # offline: retry soon
        if now >= next_listen:
            song = listen()
            if song:
                cover_url = song.pop("cover_url", "")
                if song["s_title"] != state.get("s_title"):
                    state.pop("s_len", None)
                    length = song_length(song["s_title"], song["s_artist"])
                    if length:
                        song["s_len"] = str(length)
                    song["s_cover"] = fetch_cover(cover_url)
                    song["s_cover_rev"] = str(int(time.time()))  # tells the widget to reload
                state.update(song)
                misses = 0
            elif song == {}:
                misses += 1
                if misses >= FORGET_AFTER:
                    for k in ("s_title", "s_artist", "s_pos0", "s_at", "s_len", "s_cover", "s_cover_rev"):
                        state.pop(k, None)
            next_listen = now + LISTEN_EVERY  # from when this check started
        state["updated"] = str(int(time.time()))
        write_state(state)
        time.sleep(1)


if __name__ == "__main__":
    main()
