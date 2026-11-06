//! Fork addition: the corner widget, the Win32 version of the GTK fork's
//! corner_widget.zig ("Clay" design). Pinned to the top-right corner of
//! every terminal: the date, a big clock, the weather and the song playing
//! on this computer (artist, title and the album cover drawn as a record,
//! with the song's progress as a ring around it).
//!
//! Clicking the record shows the song's lyrics in a sheet below it. The
//! sheet scrolls with the mouse wheel; when the lyrics are timed it
//! follows the song, highlighting the current line, and snaps back to it
//! 4 seconds after you scroll away.
//!
//! It only displays data. The ghostty-widget service (contrib/corner-widget,
//! widgetd.py) writes key/value line pairs to
//! %LOCALAPPDATA%\ghostty-widget\state and the current song's lyrics to
//! ...\current-lyrics.txt; we re-read the state once a second.
//!
//! Drawn into a layered popup (Overlay.zig) with GDI+. Only the record and
//! the open lyrics sheet take the mouse; clicks and selection anywhere else
//! go straight through to the terminal.
const CornerWidget = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");
const gdip = @import("gdip.zig");
const Overlay = @import("Overlay.zig");
const global = @import("../../global.zig");

const log = std.log.scoped(.win32_corner_widget);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

// Design colours ("Clay").
const clay = gdip.rgb(0xD97757);
const amber = gdip.rgb(0xEF9F27);
const text_main = gdip.rgb(0xF0EEE6);
const text_dim = gdip.rgb(0x9A9893);
const text_past = gdip.rgb(0x5F5E5A);
const text_note = gdip.rgb(0x6B6A66);
const ring_track = gdip.rgb(0x2A1A14);
const cover_fallback = gdip.rgb(0x4A2A20);
const sheet_bg = gdip.argb(224, 0, 0, 0); // rgba(0, 0, 0, 0.88)
const slider = gdip.rgb(0x4A2A20);

// Fonts: Space Grotesk when installed, else Segoe UI. GDI+ does no font
// fallback, so symbols (weather, ♪) use a symbol font explicitly.
const fonts_regular = [_][:0]const u16{ L("Space Grotesk"), L("Segoe UI") };
const fonts_medium = [_][:0]const u16{ L("Space Grotesk Medium"), L("Space Grotesk"), L("Segoe UI Semibold"), L("Segoe UI") };
const fonts_light = [_][:0]const u16{ L("Space Grotesk Light"), L("Space Grotesk"), L("Segoe UI Light"), L("Segoe UI") };
const fonts_symbol = [_][:0]const u16{ L("Segoe UI Symbol"), L("Segoe UI") };

// Layout, in unscaled pixels (like the GTK CSS).
const MARGIN_TOP = 16;
const MARGIN_RIGHT = 20;
const WIDTH = 300;
const DATE_H = 18;
const TIME_Y = 12;
const TIME_H = 70;
const WEATHER_H = 18;
const SONG_GAP = 14;
const RECORD = 58;
const SONG_TEXT_W = 210;
const LYRICS_GAP = 12;
const LYRICS_W = 260;
const LYRICS_H = 190;
const LYRIC_PAD_Y = 3;
const LYRIC_PAD_R = 10;
const LYRIC_PAD_L = 12;

// Timers.
const TICK_TIMER: usize = 1;
const LYRICS_TIMER: usize = 2;
const ANIM_TIMER: usize = 3;

const SNAP_BACK_MS = 4000;
const SCROLL_ANIM_MS = 450;

const Line = struct {
    /// Into `lyrics_text`.
    start: usize,
    len: usize,
    /// Start time when timed, ms into the song.
    time: i64 = 0,
    note: bool = false,
    symbol: bool = false,
    /// Layout within the sheet's content, pixels.
    y: f32 = 0,
    h: f32 = 0,
};

alloc: Allocator,
overlay: *Overlay,

/// Surface client size and DPI scale.
surface_w: i32 = 0,
surface_h: i32 = 0,
scale: f32 = 1,

// --- what we show ---
date: [64]u16 = undefined,
date_len: usize = 0,
clock: [8]u16 = undefined,
clock_len: usize = 0,
w_sym: [8]u16 = undefined,
w_sym_len: usize = 0,
w_rest: [64]u16 = undefined,
w_rest_len: usize = 0,
title: [256]u16 = undefined,
title_len: usize = 0,
artist: [256]u16 = undefined,
artist_len: usize = 0,
cover: ?gdip.Image = null,
cover_rev: i64 = -1,
/// Song progress 0..1, or below 0 when the length is unknown.
progress: f64 = -1,
/// Song position: `pos_ms` into the song at unix time `at_ms`.
pos_ms: i64 = 0,
at_ms: i64 = 0,

// --- lyrics ---
lyrics_rev: i64 = -1,
lyrics_text: std.ArrayList(u16) = .empty,
lines: std.ArrayList(Line) = .empty,
synced: bool = false,
current: ?usize = null,
/// Laid out for this scale (0 = needs layout).
lyrics_layout_scale: f32 = 0,
content_h: f32 = 0,
open: bool = false,
scroll: f32 = 0,
anim_from: f32 = 0,
anim_to: f32 = 0,
anim_start_ms: i64 = 0,
animating: bool = false,
user_scroll_at_ms: i64 = 0,
user_scrolled: bool = false,
need_scroll: bool = false,

/// Cached fonts for `fonts_scale`.
fonts: ?Fonts = null,
fonts_scale: f32 = 0,

/// Last painted signature, to skip identical repaints.
painted: u64 = 0,
was_shown: bool = false,

const Fonts = struct {
    date: gdip.Font,
    time: gdip.Font,
    body: gdip.Font,
    small: gdip.Font,
    title: gdip.Font,
    symbol: gdip.Font,
    lyric: gdip.Font,
    lyric_symbol: gdip.Font,

    fn init(s: f32) ?Fonts {
        var f: Fonts = undefined;
        f.date = gdip.Font.init(&fonts_medium, 13 * s, .regular) orelse return null;
        f.time = gdip.Font.init(&fonts_light, 60 * s, .regular) orelse return null;
        f.body = gdip.Font.init(&fonts_regular, 13 * s, .regular) orelse return null;
        f.small = gdip.Font.init(&fonts_regular, 12 * s, .regular) orelse return null;
        f.title = gdip.Font.init(&fonts_medium, 14 * s, .regular) orelse return null;
        f.symbol = gdip.Font.init(&fonts_symbol, 13 * s, .regular) orelse return null;
        f.lyric = gdip.Font.init(&fonts_regular, 13 * s, .regular) orelse return null;
        f.lyric_symbol = gdip.Font.init(&fonts_symbol, 13 * s, .regular) orelse return null;
        return f;
    }

    fn deinit(self: Fonts) void {
        inline for (@typeInfo(Fonts).@"struct".field_names) |name| @field(self, name).deinit();
    }
};

pub fn create(alloc: Allocator, surface_hwnd: w32.HWND, hinstance: w32.HINSTANCE) !*CornerWidget {
    const self = try alloc.create(CornerWidget);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .overlay = undefined };
    self.overlay = try Overlay.create(alloc, surface_hwnd, hinstance, .{
        .ctx = self,
        .hitTest = hitTest,
        .mouse = onMouse,
        .timer = onTimer,
        .handCursor = handCursor,
    });
    self.overlay.setTimer(TICK_TIMER, 1000);
    return self;
}

pub fn destroy(self: *CornerWidget) void {
    const alloc = self.alloc;
    self.overlay.killTimer(TICK_TIMER);
    self.overlay.killTimer(LYRICS_TIMER);
    self.overlay.killTimer(ANIM_TIMER);
    self.overlay.destroy(alloc);
    if (self.cover) |c| c.deinit();
    if (self.fonts) |f| f.deinit();
    self.lyrics_text.deinit(alloc);
    self.lines.deinit(alloc);
    alloc.destroy(self);
}

/// Called when the surface is resized or its DPI changes.
pub fn resize(self: *CornerWidget, width: i32, height: i32, scale: f32) void {
    self.surface_w = width;
    self.surface_h = height;
    if (scale != self.scale) {
        self.scale = scale;
        self.lyrics_layout_scale = 0;
    }
    self.refresh();
    self.layout();
}

/// Follows the surface's visibility (see Overlay.sync); refreshes right
/// away when it comes into view, since hidden widgets skip their ticks.
pub fn sync(self: *CornerWidget) void {
    self.overlay.sync();
    if (self.overlay.shown and !self.was_shown) {
        self.refresh();
        self.layout();
    }
    self.was_shown = self.overlay.shown;
}

/// Mouse wheel that reached the terminal while the pointer was over the
/// open lyrics sheet (Windows sends the wheel to the focused window unless
/// "scroll inactive windows" is on). Returns true when consumed.
pub fn wheelAtCursor(self: *CornerWidget, wparam: usize) bool {
    if (!self.open or !self.overlay.shown) return false;
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return false;
    _ = w32.ScreenToClient(self.overlay.hwnd, &pt);
    if (!self.inSheet(pt.x, pt.y)) return false;
    self.wheel(wparam);
    return true;
}

// ---------------------------------------------------------------------
// Geometry

fn px(self: *const CornerWidget, v: f32) f32 {
    return @round(v * self.scale);
}

fn hasSong(self: *const CornerWidget) bool {
    return self.title_len > 0;
}

fn hasWeather(self: *const CornerWidget) bool {
    return self.w_rest_len > 0;
}

fn songY(self: *const CornerWidget) f32 {
    var y: f32 = TIME_Y + TIME_H;
    if (self.hasWeather()) y += WEATHER_H;
    return self.px(y + SONG_GAP);
}

fn sheetRect(self: *const CornerWidget) gdip.RectF {
    const w = self.px(LYRICS_W);
    return .{
        .x = self.px(WIDTH) - w,
        .y = self.songY() + self.px(RECORD + LYRICS_GAP),
        .w = w,
        .h = self.px(LYRICS_H),
    };
}

fn recordCenter(self: *const CornerWidget) [3]f32 {
    const r = self.px(RECORD) / 2;
    return .{ self.px(WIDTH) - r, self.songY() + r, r };
}

fn totalHeight(self: *const CornerWidget) f32 {
    var y: f32 = TIME_Y + TIME_H;
    if (self.hasWeather()) y += WEATHER_H;
    var h = self.px(y);
    if (self.hasSong()) {
        h = self.songY() + self.px(RECORD);
        if (self.open) h += self.px(LYRICS_GAP + LYRICS_H);
    }
    return h + self.px(4);
}

fn inRecord(self: *const CornerWidget, x: i32, y: i32) bool {
    if (!self.hasSong()) return false;
    const c = self.recordCenter();
    const dx = @as(f32, @floatFromInt(x)) - c[0];
    const dy = @as(f32, @floatFromInt(y)) - c[1];
    return dx * dx + dy * dy <= c[2] * c[2];
}

fn inSheet(self: *const CornerWidget, x: i32, y: i32) bool {
    if (!self.open or !self.hasSong()) return false;
    const r = self.sheetRect();
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    return fx >= r.x and fx < r.x + r.w and fy >= r.y and fy < r.y + r.h;
}

/// Positions the popup (top-right of the surface) and repaints it.
fn layout(self: *CornerWidget) void {
    const w: i32 = @intFromFloat(self.px(WIDTH));
    const h: i32 = @intFromFloat(@ceil(self.totalHeight()));
    const margin_r: i32 = @intFromFloat(self.px(MARGIN_RIGHT));
    const margin_t: i32 = @intFromFloat(self.px(MARGIN_TOP));
    // Too small a terminal (a narrow split): leave it alone.
    const fits = self.surface_w >= w + 2 * margin_r and self.surface_h >= h + 2 * margin_t;
    self.overlay.setRect(self.surface_w - margin_r - w, margin_t, w, h);
    self.painted = 0;
    if (fits) self.repaint();
    self.overlay.setWanted(fits);
    self.was_shown = self.overlay.shown;
}

// ---------------------------------------------------------------------
// Data

fn nowMs() i64 {
    const ns = std.Io.Clock.now(.real, global.io()).toNanoseconds();
    return @intCast(@divFloor(ns, std.time.ns_per_ms));
}

fn monoMs() i64 {
    return @intCast(w32.GetTickCount64());
}

var paths_buf: [2][512]u8 = undefined;
var paths: ?[2][]const u8 = null;

/// %LOCALAPPDATA%\ghostty-widget\state and ...\current-lyrics.txt.
fn dataPaths(alloc: Allocator) ?[2][]const u8 {
    if (paths) |p| return p;
    const dir = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch |err| {
        log.warn("LOCALAPPDATA not available err={}", .{err});
        return null;
    };
    defer alloc.free(dir);
    const state = std.fmt.bufPrint(&paths_buf[0], "{s}\\ghostty-widget\\state", .{dir}) catch return null;
    const lyrics = std.fmt.bufPrint(&paths_buf[1], "{s}\\ghostty-widget\\current-lyrics.txt", .{dir}) catch return null;
    paths = .{ state, lyrics };
    return paths;
}

/// Parsed contents of the state file. Slices point into `buf`.
pub const State = struct {
    buf: [8192]u8 = undefined,
    w_sym: []const u8 = "",
    w_temp: []const u8 = "",
    w_wind: []const u8 = "",
    s_title: []const u8 = "",
    s_artist: []const u8 = "",
    s_cover: []const u8 = "",
    s_cover_rev: i64 = 0,
    s_pos0: i64 = 0,
    s_at: i64 = 0,
    s_pos_ms: i64 = 0,
    s_at_ms: i64 = 0,
    s_len: i64 = 0,
    s_lyrics_rev: i64 = 0,

    fn load(self: *State, alloc: Allocator) void {
        const p = dataPaths(alloc) orelse return;
        const data = std.Io.Dir.cwd().readFile(global.io(), p[0], &self.buf) catch return;
        self.parse(data);
    }

    pub fn parse(self: *State, data: []const u8) void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |key_raw| {
            const value_raw = lines.next() orelse break;
            const key = std.mem.trimEnd(u8, key_raw, "\r");
            const value = std.mem.trimEnd(u8, value_raw, "\r");
            inline for (.{ "w_sym", "w_temp", "w_wind", "s_title", "s_artist", "s_cover" }) |name| {
                if (std.mem.eql(u8, key, name)) @field(self, name) = value;
            }
            inline for (.{ "s_cover_rev", "s_pos0", "s_at", "s_len", "s_pos_ms", "s_at_ms", "s_lyrics_rev" }) |name| {
                if (std.mem.eql(u8, key, name)) @field(self, name) = std.fmt.parseInt(i64, value, 10) catch 0;
            }
        }
    }
};

/// Re-reads the clock and the state file.
fn refresh(self: *CornerWidget) void {
    var st: w32.SYSTEMTIME = undefined;
    w32.GetLocalTime(&st);

    // FRI · 23 OCT, in the user's language.
    const n = w32.GetDateFormatW(w32.LOCALE_USER_DEFAULT, 0, &st, L("ddd' · 'dd MMM"), &self.date, @intCast(self.date.len));
    self.date_len = if (n > 0) @intCast(n - 1) else 0;
    _ = w32.CharUpperBuffW(&self.date, @intCast(self.date_len));

    var clock_buf: [8]u8 = undefined;
    const clock = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}", .{ st.wHour, st.wMinute }) catch "";
    self.clock_len = gdip.utf16(&self.clock, clock).len;

    var state: State = .{};
    state.load(self.alloc);

    // Weather: the symbol in amber, then "12° · wind 9 km/h".
    if (state.w_temp.len > 0) {
        var buf: [128]u8 = undefined;
        const rest = std.fmt.bufPrint(&buf, " {s}° · wind {s} km/h", .{ state.w_temp, state.w_wind }) catch "";
        self.w_rest_len = gdip.utf16(&self.w_rest, rest).len;
        self.w_sym_len = gdip.utf16(&self.w_sym, state.w_sym).len;
    } else {
        self.w_rest_len = 0;
        self.w_sym_len = 0;
    }

    const had_song = self.hasSong();
    self.title_len = gdip.utf16(&self.title, state.s_title).len;
    self.artist_len = gdip.utf16(&self.artist, state.s_artist).len;
    if (!self.hasSong()) {
        if (had_song and self.open) self.setOpen(false);
        return;
    }

    if (state.s_cover_rev != self.cover_rev) {
        self.cover_rev = state.s_cover_rev;
        self.loadCover(state.s_cover);
    }

    // Song position: where the player was, plus time since then.
    const now_s = @divFloor(nowMs(), 1000);
    const pos = state.s_pos0 + (now_s - state.s_at);
    self.progress = if (state.s_len > 0 and pos >= 0 and pos <= state.s_len)
        @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(state.s_len))
    else
        -1;

    if (state.s_at_ms > 0) {
        self.pos_ms = state.s_pos_ms;
        self.at_ms = state.s_at_ms;
    } else {
        self.pos_ms = state.s_pos0 * 1000;
        self.at_ms = state.s_at * 1000;
    }
    if (state.s_lyrics_rev != self.lyrics_rev) {
        self.lyrics_rev = state.s_lyrics_rev;
        self.loadLyrics(state.s_lyrics_rev != 0);
    }
    _ = self.updateCurrent();
}

fn loadCover(self: *CornerWidget, path: []const u8) void {
    if (self.cover) |c| c.deinit();
    self.cover = null;
    if (path.len == 0) return;
    if (!gdip.startup()) return;
    const data = std.Io.Dir.cwd().readFileAlloc(global.io(), path, self.alloc, .limited(8 * 1024 * 1024)) catch |err| {
        log.debug("unable to read album cover err={}", .{err});
        return;
    };
    defer self.alloc.free(data);
    self.cover = gdip.Image.fromBytes(data);
    if (self.cover == null) log.debug("unable to decode album cover", .{});
}

/// Rebuilds the lyrics from the file the service writes: a first line
/// saying synced/plain/instrumental/none, then one line per lyric
/// ("milliseconds<TAB>text" when synced). `ready` is false while the
/// service is still looking.
fn loadLyrics(self: *CornerWidget, ready: bool) void {
    self.lyrics_text.clearRetainingCapacity();
    self.lines.clearRetainingCapacity();
    self.synced = false;
    self.current = null;
    self.need_scroll = true;
    self.scroll = 0;
    self.animating = false;
    self.lyrics_layout_scale = 0;

    if (!ready) return self.addNote("Looking for lyrics…");

    const p = dataPaths(self.alloc) orelse return self.addNote("No lyrics found");
    const data = std.Io.Dir.cwd().readFileAlloc(global.io(), p[1], self.alloc, .limited(1 << 20)) catch
        return self.addNote("No lyrics found");
    defer self.alloc.free(data);
    self.parseLyrics(data) catch return;
}

pub fn parseLyrics(self: *CornerWidget, data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const kind = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
    if (std.mem.eql(u8, kind, "instrumental")) return self.addNote("Instrumental");
    if (!std.mem.eql(u8, kind, "synced") and !std.mem.eql(u8, kind, "plain"))
        return self.addNote("No lyrics found");
    self.synced = std.mem.eql(u8, kind, "synced");

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var text = line;
        var time: i64 = 0;
        if (self.synced) {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            time = std.fmt.parseInt(i64, line[0..tab], 10) catch continue;
            text = line[tab + 1 ..];
        } else if (lines.peek() == null and line.len == 0) break;

        // Timed lyrics mark instrumental breaks with an empty line.
        const symbol = text.len == 0;
        try self.addLine(if (symbol) "♪" else text, time, false, symbol);
    }
    if (self.lines.items.len == 0) self.addNote("No lyrics found");
}

fn addNote(self: *CornerWidget, text: []const u8) void {
    self.addLine(text, 0, true, false) catch {};
}

fn addLine(self: *CornerWidget, text: []const u8, time: i64, note: bool, symbol: bool) !void {
    var buf: [1024]u16 = undefined;
    const t16 = gdip.utf16(&buf, text);
    const start = self.lyrics_text.items.len;
    try self.lyrics_text.appendSlice(self.alloc, t16);
    try self.lines.append(self.alloc, .{ .start = start, .len = t16.len, .time = time, .note = note, .symbol = symbol });
}

fn lineText(self: *const CornerWidget, line: Line) []const u16 {
    return self.lyrics_text.items[line.start..][0..line.len];
}

/// Picks the line being sung. Returns whether it changed.
fn updateCurrent(self: *CornerWidget) bool {
    if (!self.synced or self.lines.items.len == 0) return false;
    // A little early, so the line is lit as it starts.
    const pos = self.pos_ms + (nowMs() - self.at_ms) + 200;
    var current: ?usize = null;
    for (self.lines.items, 0..) |line, i| {
        if (line.time > pos) break;
        current = i;
    }
    if (current == self.current) return false;
    self.current = current;
    return true;
}

// ---------------------------------------------------------------------
// Lyrics sheet

fn setOpen(self: *CornerWidget, open: bool) void {
    self.open = open;
    if (open) {
        self.need_scroll = true;
        self.user_scroll_at_ms = 0;
        self.overlay.setTimer(LYRICS_TIMER, 200);
    } else {
        self.overlay.killTimer(LYRICS_TIMER);
        self.overlay.killTimer(ANIM_TIMER);
        self.animating = false;
    }
    self.layout();
}

/// Measures every line for the current scale.
fn layoutLyrics(self: *CornerWidget) void {
    if (self.lyrics_layout_scale == self.scale) return;
    const fonts = self.getFonts() orelse return;
    var pixel: [1]u32 = .{0};
    const canvas = gdip.Canvas.init(&pixel, 1, 1) orelse return;
    defer canvas.deinit();

    const text_w = self.px(LYRICS_W - LYRIC_PAD_L - LYRIC_PAD_R);
    const pad = self.px(LYRIC_PAD_Y);
    var y: f32 = self.px(6);
    for (self.lines.items) |*line| {
        const font = if (line.symbol) fonts.lyric_symbol else fonts.lyric;
        line.y = y;
        line.h = canvas.measureWrapped(font, self.lineText(line.*), text_w) + 2 * pad;
        y += line.h;
    }
    self.content_h = y + self.px(6);
    self.lyrics_layout_scale = self.scale;
}

fn maxScroll(self: *const CornerWidget) f32 {
    return @max(0, self.content_h - self.px(LYRICS_H));
}

/// Scrolls (smoothly) so the current line is in the middle of the sheet.
fn scrollToCurrent(self: *CornerWidget) void {
    self.layoutLyrics();
    var target: f32 = 0;
    if (self.current) |c| {
        const line = self.lines.items[c];
        target = line.y + line.h / 2 - self.px(LYRICS_H) / 2;
    }
    target = std.math.clamp(target, 0, self.maxScroll());
    if (@abs(target - self.scroll) < 0.5) return;
    self.anim_from = self.scroll;
    self.anim_to = target;
    self.anim_start_ms = monoMs();
    self.animating = true;
    self.overlay.setTimer(ANIM_TIMER, 16);
}

fn onLyricsTick(self: *CornerWidget) void {
    const changed = self.updateCurrent();
    const held = monoMs() - self.user_scroll_at_ms < SNAP_BACK_MS;
    if (!held and (changed or self.need_scroll or self.user_scrolled)) {
        self.need_scroll = false;
        self.user_scrolled = false;
        self.scrollToCurrent();
    }
    if (changed) self.repaint();
}

fn onAnimTick(self: *CornerWidget) void {
    const t = @min(1.0, @as(f32, @floatFromInt(monoMs() - self.anim_start_ms)) / SCROLL_ANIM_MS);
    const ease = 1 - std.math.pow(f32, 1 - t, 3);
    self.scroll = self.anim_from + (self.anim_to - self.anim_from) * ease;
    if (t >= 1) {
        self.animating = false;
        self.overlay.killTimer(ANIM_TIMER);
    }
    self.repaint();
}

fn wheel(self: *CornerWidget, wparam: usize) void {
    const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
    const notches = @as(f32, @floatFromInt(delta)) / 120.0;
    self.layoutLyrics();
    self.animating = false;
    self.overlay.killTimer(ANIM_TIMER);
    self.scroll = std.math.clamp(self.scroll - notches * self.px(48), 0, self.maxScroll());
    self.user_scroll_at_ms = monoMs();
    self.user_scrolled = true;
    self.repaint();
}

// ---------------------------------------------------------------------
// Overlay callbacks

fn hitTest(ctx: *anyopaque, x: i32, y: i32) bool {
    const self: *CornerWidget = @ptrCast(@alignCast(ctx));
    return self.inRecord(x, y) or self.inSheet(x, y);
}

fn handCursor(ctx: *anyopaque, x: i32, y: i32) bool {
    const self: *CornerWidget = @ptrCast(@alignCast(ctx));
    return self.inRecord(x, y);
}

fn onMouse(ctx: *anyopaque, msg: u32, x: i32, y: i32, wparam: usize) void {
    const self: *CornerWidget = @ptrCast(@alignCast(ctx));
    switch (msg) {
        w32.WM_LBUTTONDOWN, w32.WM_LBUTTONDBLCLK => if (self.inRecord(x, y)) self.setOpen(!self.open),
        w32.WM_MOUSEWHEEL => if (self.inSheet(x, y)) self.wheel(wparam),
        else => {},
    }
}

fn onTimer(ctx: *anyopaque, id: usize) void {
    const self: *CornerWidget = @ptrCast(@alignCast(ctx));
    switch (id) {
        TICK_TIMER => {
            // Hidden (another tab, minimized, quick terminal away): skip;
            // sync() refreshes when it comes back.
            if (!self.overlay.shown) return;
            const had_song = self.hasSong();
            const had_weather = self.hasWeather();
            self.refresh();
            if (had_song != self.hasSong() or had_weather != self.hasWeather()) {
                self.layout();
            } else {
                self.repaint();
            }
        },
        LYRICS_TIMER => if (self.overlay.shown) self.onLyricsTick(),
        ANIM_TIMER => self.onAnimTick(),
        else => {},
    }
}

// ---------------------------------------------------------------------
// Painting

fn getFonts(self: *CornerWidget) ?Fonts {
    if (self.fonts != null and self.fonts_scale == self.scale) return self.fonts;
    if (!gdip.startup()) return null;
    if (self.fonts) |f| f.deinit();
    self.fonts = Fonts.init(self.scale);
    self.fonts_scale = self.scale;
    return self.fonts;
}

/// Repaints unless nothing visible changed since the last paint.
fn repaint(self: *CornerWidget) void {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.sliceAsBytes(self.date[0..self.date_len]));
    h.update(std.mem.sliceAsBytes(self.clock[0..self.clock_len]));
    h.update(std.mem.sliceAsBytes(self.w_rest[0..self.w_rest_len]));
    h.update(std.mem.sliceAsBytes(self.title[0..self.title_len]));
    h.update(std.mem.sliceAsBytes(self.artist[0..self.artist_len]));
    h.update(std.mem.asBytes(&self.cover_rev));
    h.update(std.mem.asBytes(&self.lyrics_rev));
    const progress_px: i32 = @intFromFloat(@round(self.progress * 360));
    h.update(std.mem.asBytes(&progress_px));
    h.update(std.mem.asBytes(&self.open));
    h.update(std.mem.asBytes(&self.scroll));
    const cur: i64 = if (self.current) |c| @intCast(c) else -1;
    h.update(std.mem.asBytes(&cur));
    h.update(std.mem.asBytes(&self.overlay.w));
    h.update(std.mem.asBytes(&self.overlay.h));
    const sig = h.final() | 1;
    if (sig == self.painted) return;
    self.painted = sig;
    self.overlay.paint(self, draw);
}

fn draw(self: *CornerWidget, pixels: [*]u32, w: i32, h: i32) void {
    const fonts = self.getFonts() orelse return;
    const canvas = gdip.Canvas.init(pixels, w, h) orelse return;
    defer canvas.deinit();
    const s = self.scale;
    const right: f32 = @floatFromInt(w);

    // Date, letter-spaced, in clay.
    drawSpaced(canvas, fonts.date, clay, self.date[0..self.date_len], right, 0, self.px(DATE_H), 2 * s);

    // The clock.
    canvas.drawText(fonts.time, text_main, self.clock[0..self.clock_len], 0, self.px(TIME_Y), right, self.px(TIME_H), .far);

    // Weather.
    if (self.hasWeather()) {
        const y = self.px(TIME_Y + TIME_H);
        const rest = self.w_rest[0..self.w_rest_len];
        const rest_w = canvas.measure(fonts.body, rest)[0];
        canvas.drawText(fonts.body, text_dim, rest, 0, y, right, self.px(WEATHER_H), .far);
        canvas.drawText(fonts.symbol, amber, self.w_sym[0..self.w_sym_len], 0, y, right - rest_w, self.px(WEATHER_H), .far);
    }

    if (!self.hasSong()) return;

    // Artist and title, left of the record.
    const sy = self.songY();
    const text_right = right - self.px(RECORD + 12);
    const text_w = self.px(SONG_TEXT_W);
    const mid = sy + self.px(RECORD) / 2;
    canvas.drawText(fonts.small, text_dim, self.artist[0..self.artist_len], text_right - text_w, mid - self.px(17), text_w, self.px(16), .far);
    canvas.drawText(fonts.title, text_main, self.title[0..self.title_len], text_right - text_w, mid - self.px(1), text_w, self.px(19), .far);

    self.drawRecord(canvas);
    if (self.open) self.drawSheet(canvas, fonts);
}

/// The cover as a record (round, with a spindle hole) and the song's
/// progress as a clay ring around it, starting at 12 o'clock.
fn drawRecord(self: *CornerWidget, canvas: gdip.Canvas) void {
    const c = self.recordCenter();
    const s = self.scale;
    const ring_r = c[2] - 1.5 * s;
    const cover_r = ring_r - 5 * s;
    canvas.arc(ring_track, 2 * s, c[0], c[1], ring_r, 0, 360, false);
    if (self.progress >= 0) {
        const sweep: f32 = @floatCast(@max(0.5, 360 * self.progress));
        canvas.arc(clay, 2 * s, c[0], c[1], ring_r, -90, sweep, true);
    }
    if (self.cover) |img| {
        canvas.imageInCircle(img, c[0], c[1], cover_r);
    } else {
        canvas.fillCircle(cover_fallback, c[0], c[1], cover_r);
    }
    canvas.fillCircle(gdip.rgb(0x000000), c[0], c[1], 3.5 * s);
}

fn drawSheet(self: *CornerWidget, canvas: gdip.Canvas, fonts: Fonts) void {
    self.layoutLyrics();
    const r = self.sheetRect();
    canvas.fillRoundRect(sheet_bg, r.x, r.y, r.w, r.h, self.px(8), .{});
    canvas.clipRect(r.x, r.y, r.w, r.h);
    defer canvas.resetClip();

    const pad = self.px(LYRIC_PAD_Y);
    const left = r.x + self.px(LYRIC_PAD_L);
    const text_w = r.w - self.px(LYRIC_PAD_L + LYRIC_PAD_R);
    for (self.lines.items, 0..) |line, i| {
        const y = r.y + line.y - self.scroll;
        if (y + line.h < r.y or y > r.y + r.h) continue;
        const past = if (self.current) |c| i < c else false;
        const now = if (self.current) |c| i == c else false;
        const color = if (line.note) text_note else if (now) text_main else if (past) text_past else text_dim;
        const font = if (line.symbol) fonts.lyric_symbol else fonts.lyric;
        canvas.drawWrapped(font, color, self.lineText(line), left, y + pad, text_w, line.h, .far);
        if (now) canvas.fillRect(clay, r.x + r.w - self.px(2), y, self.px(2), line.h);
    }

    // Scroll position.
    const max = self.maxScroll();
    if (max > 0) {
        const thumb_h = @max(self.px(16), r.h * r.h / self.content_h);
        const thumb_y = r.y + (r.h - thumb_h) * (self.scroll / max);
        canvas.fillRect(slider, r.x + r.w - self.px(6), thumb_y, self.px(3), thumb_h);
    }
}

/// Right-aligned text ending at `right`, with extra space between letters
/// (CSS letter-spacing).
fn drawSpaced(canvas: gdip.Canvas, font: gdip.Font, color: u32, str: []const u16, right: f32, y: f32, h: f32, spacing: f32) void {
    var x = right;
    var i = str.len;
    while (i > 0) {
        var start = i - 1;
        // Keep surrogate pairs together.
        if (start > 0 and str[start] >= 0xDC00 and str[start] <= 0xDFFF) start -= 1;
        const ch = str[start..i];
        const cw = canvas.measure(font, ch)[0];
        canvas.drawText(font, color, ch, x - cw - 20, y, cw + 20, h, .far);
        x -= cw + spacing;
        i = start;
    }
}

test "state file parsing" {
    var st: State = .{};
    st.parse("w_sym\r\n☀\r\nw_temp\r\n12\r\ns_title\r\nSong\r\ns_len\r\n200\r\ns_at_ms\r\n1700000000000\r\n");
    try std.testing.expectEqualStrings("☀", st.w_sym);
    try std.testing.expectEqualStrings("12", st.w_temp);
    try std.testing.expectEqualStrings("Song", st.s_title);
    try std.testing.expectEqual(@as(i64, 200), st.s_len);
    try std.testing.expectEqual(@as(i64, 1700000000000), st.s_at_ms);
}
