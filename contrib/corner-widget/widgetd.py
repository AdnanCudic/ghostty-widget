#!/usr/bin/env python3
"""Background service for the Ghostty corner widget.

Collects weather (Open-Meteo, no API key), the music and its lyrics: what a player on
this computer is playing (MPRIS, e.g. Spotify or a browser tab), or else
what is playing in the room (mic clip -> SongRec -> Shazam). Lyrics come
from LRCLIB (no API key), timed when available. Writes them to a small state file that
Ghostty's corner widget (src/apprt/gtk/class/corner_widget.zig) reads every
second. Standard library only.

The microphone stays open the whole time, keeping only the last few seconds
in memory, so GNOME's microphone indicator stays on instead of flashing for
every clip.

Settings come from the environment (the service reads them from
~/.config/ghostty-widget/env):

  WIDGET_CITY     city for the weather, e.g. "Berlin"; unset = no weather
  WIDGET_COUNTRY  two-letter country code to pick the right city, e.g. "DE"
  WIDGET_MIC      microphone for recognising music in the room: a PipeWire
                  source name (pactl list short sources), or "default";
                  unset = no microphone, only what this computer plays
"""

import json
import hashlib
import os
import re
import signal
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import wave

# --- CONFIGURATION ---
CITY = os.environ.get("WIDGET_CITY", "").strip()
COUNTRY_CODE = os.environ.get("WIDGET_COUNTRY", "").strip().upper()
MIC = os.environ.get("WIDGET_MIC", "").strip()
WEATHER_EVERY = 600   # seconds between weather updates
LISTEN_EVERY = 10     # seconds between song checks (start to start)
CLIP_SECONDS = 8      # length of each mic clip
FORGET_AFTER = 6      # misses in a row before the song is cleared (~1 min)

SAMPLE_RATE = 16000
CLIP_BYTES = SAMPLE_RATE * 2 * CLIP_SECONDS  # mono s16

SONGREC = "re.fossplant.songrec"
RUN_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ghostty-widget")
STATE = os.path.join(RUN_DIR, "state")
CLIP = os.path.join(RUN_DIR, "clip.wav")
COVER = os.path.join(RUN_DIR, "cover.png")
LYRICS = os.path.join(RUN_DIR, "lyrics")
CACHE_DIR = os.path.expanduser("~/.cache/ghostty-widget")
GEO_CACHE = os.path.join(CACHE_DIR, "location.json")
LYRICS_CACHE = os.path.join(CACHE_DIR, "lyrics")

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


class MicStream:
    """One pw-record kept running, holding the last CLIP_SECONDS of audio."""

    def __init__(self):
        self.lock = threading.Lock()
        self.buf = bytearray()
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        cmd = ["pw-record", "--rate", str(SAMPLE_RATE), "--channels", "1", "--format", "s16"]
        if MIC != "default":
            cmd += ["--target", MIC]
        cmd.append("-")  # stdout: a small AU header, then little-endian samples
        while True:
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            except OSError:
                time.sleep(10)
                continue
            try:
                head = proc.stdout.read(8)  # magic, data offset
                if len(head) == 8:
                    proc.stdout.read(int.from_bytes(head[4:8], "little") - 8)
                    while chunk := proc.stdout.read(SAMPLE_RATE // 5):  # 0.1 s
                        with self.lock:
                            self.buf += chunk
                            del self.buf[:-CLIP_BYTES]
            finally:
                proc.kill()
                proc.wait()
                with self.lock:
                    self.buf.clear()
            time.sleep(5)  # stream ended (audio server restart, mic gone): reopen

    def clip(self):
        """The last CLIP_SECONDS of audio, or None until that much is buffered."""
        with self.lock:
            return bytes(self.buf) if len(self.buf) == CLIP_BYTES else None


def listen(mic):
    """Ask Shazam about the last clip. Returns song fields, {} for no match, None on error."""
    audio = mic.clip()
    if audio is None:
        return None
    started = time.time() - CLIP_SECONDS
    try:
        with wave.open(CLIP, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SAMPLE_RATE)
            w.writeframes(audio)
        # --nosocket=pulseaudio: SongRec only reads the file, and without this
        # every run opens an audio-server connection. In its own session so
        # a hung run can be killed whole (flatpak + bwrap + songrec); killing
        # only `flatpak` left them behind and they used up the audio server's
        # connection limit, breaking audio in other apps.
        proc = subprocess.Popen(
            ["flatpak", "run", "--nosocket=pulseaudio",
             "--filesystem=xdg-run/ghostty-widget:ro", SONGREC,
             "recognize", "--json", CLIP],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            return None
        out = subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
    except (OSError, wave.Error, subprocess.TimeoutExpired):
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
        "s_pos_ms": str(round(offset * 1000)),  # the same two in milliseconds,
        "s_at_ms": str(round(started * 1000)),  # for following the lyrics
    }


SONG_KEYS = ("s_title", "s_artist", "s_pos0", "s_at", "s_pos_ms", "s_at_ms", "s_len",
             "s_cover", "s_cover_rev", "s_key", "s_src", "s_lyrics_rev")


def busctl_json(*args):
    out = subprocess.run(["busctl", "--user", "--json=short", *args],
                         capture_output=True, text=True, timeout=5)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout else None


def now_playing():
    """What a media player on this computer is playing (MPRIS), or None."""
    try:
        names = [x["name"] for x in busctl_json("list") or []
                 if x["name"].startswith("org.mpris.MediaPlayer2.")]
        for name in names:
            prop = lambda p: busctl_json("get-property", name, "/org/mpris/MediaPlayer2",
                                         "org.mpris.MediaPlayer2.Player", p)
            status = prop("PlaybackStatus")
            if not status or status["data"] != "Playing":
                continue
            meta = {k: v["data"] for k, v in (prop("Metadata") or {}).get("data", {}).items()}
            title = meta.get("xesam:title", "")
            if not title:
                continue
            artist = meta.get("xesam:artist") or [""]
            position = (prop("Position") or {}).get("data", 0) or 0
            read_at = time.time()
            return {
                "s_title": title,
                "s_artist": ", ".join(artist) if isinstance(artist, list) else str(artist),
                "s_len": round((meta.get("mpris:length") or 0) / 1e6),
                "s_pos0": round(position / 1e6),
                "s_pos_ms": round(position / 1e3),
                "s_at_ms": round(read_at * 1000),
                "art_url": meta.get("mpris:artUrl", ""),
            }
    except (OSError, ValueError, subprocess.SubprocessError, KeyError):
        pass
    return None


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
    local = url.startswith("file://")
    src = urllib.parse.unquote(url[len("file://"):]) if local else COVER + ".src"
    try:
        if not local:
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
        if not local:
            try:
                os.remove(src)
            except OSError:
                pass


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
            with open(cache) as f:
                kind, lines = json.load(f)
        except (OSError, ValueError):
            kind, lines = find_lyrics(title, artist, length)
            if kind != "none":  # retry misses next time, the site grows
                os.makedirs(LYRICS_CACHE, exist_ok=True)
                with open(cache, "w") as f:
                    json.dump([kind, lines], f)
        if key != self.key:
            return  # the song changed meanwhile
        tmp = LYRICS + ".tmp"
        with open(tmp, "w") as f:
            f.write(kind + "\n")
            for line in lines:
                if kind == "synced":
                    f.write(f"{line[0]}\t{line[1]}\n")
                else:
                    f.write(line.replace("\t", " ") + "\n")
        os.replace(tmp, LYRICS)
        state["s_lyrics_rev"] = str(time.time_ns())  # tells the widget to reload


def write_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        for k, v in state.items():
            f.write(f"{k}\n{str(v).replace(chr(10), ' ')}\n")  # zsh reads key/value line pairs
    os.replace(tmp, STATE)


def main():
    os.makedirs(RUN_DIR, exist_ok=True)
    mic = MicStream() if MIC else None  # no mic set: no Shazam
    lyrics = Lyrics()
    state = {"updated": str(int(time.time()))}
    next_weather = next_listen = 0.0
    misses = 0
    while True:
        now = time.time()
        if CITY and now >= next_weather:
            try:
                state.update(weather())
                next_weather = now + WEATHER_EVERY
            except Exception:
                next_weather = now + 60  # offline: retry soon
        np = now_playing()
        if np:
            # A player on this computer wins over the mic, and needs no Shazam.
            art_url = np.pop("art_url")
            key = f"{np['s_title']}|{np['s_artist']}|{art_url}"
            if key != state.get("s_key"):
                state["s_cover"] = fetch_cover(art_url)
                state["s_cover_rev"] = str(int(now))  # tells the widget to reload
                state["s_key"] = key
            state.update({k: str(v) for k, v in np.items()})
            state["s_at"] = str(int(now))
            state["s_src"] = "player"
            misses = 0
        elif state.get("s_src") == "player":
            # Player stopped or paused: clear it and go back to the mic.
            for k in SONG_KEYS:
                state.pop(k, None)
            next_listen = now
        elif mic and now >= next_listen:
            song = listen(mic)
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
                state["s_src"] = "mic"
                misses = 0
            elif song == {}:
                misses += 1
                if misses >= FORGET_AFTER:
                    for k in SONG_KEYS:
                        state.pop(k, None)
            next_listen = now + LISTEN_EVERY  # from when this check started
        lyrics.update(state)
        state["updated"] = str(int(time.time()))
        write_state(dict(state))
        time.sleep(1)


if __name__ == "__main__":
    main()
