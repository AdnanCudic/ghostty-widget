const std = @import("std");
const adw = @import("adw");
const cairo = @import("cairo");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_corner_widget);

/// Fork addition: a small widget pinned to the top-right corner of every
/// terminal showing the date, a big clock, the weather and the song playing
/// in the room (artist, title and the album cover drawn as a record, with
/// the song's progress as a ring around it).
///
/// Clicking the record shows the song's lyrics in a scrollable sheet below
/// it, which follows the song when the lyrics are timed.
///
/// It only displays data. The ghostty-widget service (contrib/corner-widget)
/// fetches weather, recognises music, downloads covers and lyrics, and
/// writes key/value line pairs to $XDG_RUNTIME_DIR/ghostty-widget/state
/// (lyrics in .../lyrics), which we re-read every second. Apart from the
/// record and the open lyrics sheet it takes no input, so clicks and
/// selection go straight through to the terminal.
pub const CornerWidget = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCornerWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    /// Design colours ("Clay").
    const clay = rgb(0xD9, 0x77, 0x57);
    const ring_track = rgb(0x2A, 0x1A, 0x14);
    const cover_fallback = rgb(0x4A, 0x2A, 0x20);

    const Private = struct {
        date_label: *gtk.Label,
        time_label: *gtk.Label,
        weather_label: *gtk.Label,
        song_box: *gtk.Box,
        artist_label: *gtk.Label,
        song_label: *gtk.Label,
        vinyl: *gtk.DrawingArea,
        lyrics_revealer: *gtk.Revealer,
        lyrics_scroll: *gtk.ScrolledWindow,
        lyrics_box: *gtk.Box,

        /// Refreshes everything once a second.
        tick_timer: ?c_uint = null,

        /// The album cover, loaded from the PNG the service writes.
        cover: ?*cairo.Surface = null,

        /// Which cover we have loaded (the service bumps this per song).
        cover_rev: i64 = 0,

        /// Song progress 0..1, or below 0 when the length is unknown.
        progress: f64 = -1,

        /// Song position: `pos_ms` into the song at unix time `at_ms`.
        pos_ms: i64 = 0,
        at_ms: i64 = 0,

        /// Which lyrics we have loaded (the service bumps this per song).
        lyrics_rev: i64 = -1,

        /// One label per lyric line, and its start time when timed.
        lyric_labels: std.ArrayListUnmanaged(*gtk.Label) = .empty,
        lyric_times: std.ArrayListUnmanaged(i64) = .empty,
        synced: bool = false,

        /// The highlighted line.
        current: ?usize = null,

        /// When the user last scrolled the lyrics (monotonic µs), and
        /// whether we still owe them a snap back to the current line.
        user_scroll_at: i64 = 0,
        user_scrolled: bool = false,

        /// Scroll to the current line on the next tick (sheet just opened).
        need_scroll: bool = false,

        /// Updates the lyrics highlight 5 times a second while open.
        lyrics_timer: ?c_uint = null,

        /// Smooth scrolling of the lyrics.
        scroll_anim: ?*adw.TimedAnimation = null,

        pub var offset: c_int = 0;
    };

    /// Parsed contents of the state file. Slices point into `buf`.
    const State = struct {
        buf: [4096]u8 = undefined,
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

        fn load(self: *State) void {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(
                &path_buf,
                "{s}/ghostty-widget/state",
                .{std.mem.span(glib.getUserRuntimeDir())},
            ) catch return;
            const data = std.fs.cwd().readFile(path, &self.buf) catch return;

            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |key| {
                const value = lines.next() orelse break;
                if (std.mem.eql(u8, key, "w_sym")) self.w_sym = value;
                if (std.mem.eql(u8, key, "w_temp")) self.w_temp = value;
                if (std.mem.eql(u8, key, "w_wind")) self.w_wind = value;
                if (std.mem.eql(u8, key, "s_title")) self.s_title = value;
                if (std.mem.eql(u8, key, "s_artist")) self.s_artist = value;
                if (std.mem.eql(u8, key, "s_cover")) self.s_cover = value;
                if (std.mem.eql(u8, key, "s_cover_rev")) self.s_cover_rev = parse(value);
                if (std.mem.eql(u8, key, "s_pos0")) self.s_pos0 = parse(value);
                if (std.mem.eql(u8, key, "s_at")) self.s_at = parse(value);
                if (std.mem.eql(u8, key, "s_len")) self.s_len = parse(value);
                if (std.mem.eql(u8, key, "s_pos_ms")) self.s_pos_ms = parse(value);
                if (std.mem.eql(u8, key, "s_at_ms")) self.s_at_ms = parse(value);
                if (std.mem.eql(u8, key, "s_lyrics_rev")) self.s_lyrics_rev = parse(value);
            }
        }

        fn parse(value: []const u8) i64 {
            return std.fmt.parseInt(i64, value, 10) catch 0;
        }
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();
        priv.vinyl.setDrawFunc(drawVinyl, self, null);
        priv.vinyl.as(gtk.Widget).setCursorFromName("pointer");

        const adj = priv.lyrics_scroll.getVadjustment();
        const target = adw.PropertyAnimationTarget.new(adj.as(gobject.Object), "value");
        priv.scroll_anim = adw.TimedAnimation.new(
            priv.lyrics_scroll.as(gtk.Widget),
            0,
            0,
            450,
            target.as(adw.AnimationTarget),
        );
        self.refresh();
        priv.tick_timer = glib.timeoutAdd(1000, onTick, self);
    }

    fn refresh(self: *Self) void {
        const priv = self.private();

        const now_dt = glib.DateTime.newNowLocal() orelse return;
        defer now_dt.unref();
        const now = now_dt.toUnix();

        // FRI · 23 OCT
        if (now_dt.format("%a · %d %b")) |s| {
            defer glib.free(@ptrCast(s));
            const text = std.mem.span(s);
            _ = std.ascii.upperString(text, text);
            priv.date_label.setLabel(s);
        }
        if (now_dt.format("%H:%M")) |s| {
            defer glib.free(@ptrCast(s));
            priv.time_label.setLabel(s);
        }

        var st: State = .{};
        st.load();

        // Weather, with the symbol in amber.
        var buf: [512]u8 = undefined;
        const weather: [:0]const u8 = if (st.w_temp.len > 0)
            std.fmt.bufPrintZ(
                &buf,
                "<span foreground=\"#EF9F27\">{s}</span> {s}° · wind {s} km/h",
                .{ st.w_sym, st.w_temp, st.w_wind },
            ) catch ""
        else
            "";
        priv.weather_label.setMarkup(weather);
        priv.weather_label.as(gtk.Widget).setVisible(@intFromBool(weather.len > 0));

        if (st.s_title.len == 0) {
            priv.song_box.as(gtk.Widget).setVisible(0);
            priv.lyrics_revealer.as(gtk.Widget).setVisible(0);
            return;
        }
        priv.lyrics_revealer.as(gtk.Widget).setVisible(1);

        var artist_buf: [256]u8 = undefined;
        var title_buf: [256]u8 = undefined;
        priv.artist_label.setLabel(std.fmt.bufPrintZ(&artist_buf, "{s}", .{st.s_artist}) catch "");
        priv.song_label.setLabel(std.fmt.bufPrintZ(&title_buf, "{s}", .{st.s_title}) catch "");
        priv.song_box.as(gtk.Widget).setVisible(1);

        if (st.s_cover_rev != priv.cover_rev) {
            priv.cover_rev = st.s_cover_rev;
            self.loadCover(st.s_cover);
        }

        // Song position: where Shazam placed the clip, plus time since then.
        const pos = st.s_pos0 + (now - st.s_at);
        priv.progress = if (st.s_len > 0 and pos >= 0 and pos <= st.s_len)
            @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(st.s_len))
        else
            -1;
        priv.vinyl.as(gtk.Widget).queueDraw();

        if (st.s_at_ms > 0) {
            priv.pos_ms = st.s_pos_ms;
            priv.at_ms = st.s_at_ms;
        } else {
            priv.pos_ms = st.s_pos0 * 1000;
            priv.at_ms = st.s_at * 1000;
        }
        if (st.s_lyrics_rev != priv.lyrics_rev) {
            priv.lyrics_rev = st.s_lyrics_rev;
            self.loadLyrics(st.s_lyrics_rev != 0);
        }
        self.updateLyrics();
    }

    /// Rebuilds the lyrics sheet from the file the service writes: a first
    /// line saying synced/plain/instrumental/none, then one line per lyric
    /// ("milliseconds<TAB>text" when synced). `ready` is false while the
    /// service is still looking.
    fn loadLyrics(self: *Self, ready: bool) void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;

        const box = priv.lyrics_box.as(gtk.Widget);
        while (box.getFirstChild()) |child| priv.lyrics_box.remove(child);
        priv.lyric_labels.clearRetainingCapacity();
        priv.lyric_times.clearRetainingCapacity();
        priv.synced = false;
        priv.current = null;
        priv.need_scroll = true;
        priv.lyrics_scroll.getVadjustment().setValue(0);

        if (!ready) return self.addLyricNote("Looking for lyrics…");

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "{s}/ghostty-widget/lyrics",
            .{std.mem.span(glib.getUserRuntimeDir())},
        ) catch return;
        const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch
            return self.addLyricNote("No lyrics found");
        defer alloc.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        const kind = lines.next() orelse "";
        if (std.mem.eql(u8, kind, "instrumental")) return self.addLyricNote("Instrumental");
        if (!std.mem.eql(u8, kind, "synced") and !std.mem.eql(u8, kind, "plain"))
            return self.addLyricNote("No lyrics found");
        priv.synced = std.mem.eql(u8, kind, "synced");

        while (lines.next()) |line| {
            var text = line;
            if (priv.synced) {
                const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                const ms = std.fmt.parseInt(i64, line[0..tab], 10) catch continue;
                priv.lyric_times.append(alloc, ms) catch return;
                text = line[tab + 1 ..];
            } else if (lines.peek() == null and line.len == 0) break;

            // Timed lyrics mark instrumental breaks with an empty line.
            const label = newLyricLabel(if (text.len == 0) "♪" else text) orelse return;
            priv.lyric_labels.append(alloc, label) catch return;
            priv.lyrics_box.append(label.as(gtk.Widget));
        }
        if (priv.lyric_labels.items.len == 0) self.addLyricNote("No lyrics found");
    }

    fn addLyricNote(self: *Self, text: []const u8) void {
        const label = newLyricLabel(text) orelse return;
        label.as(gtk.Widget).addCssClass("lyric-note");
        self.private().lyrics_box.append(label.as(gtk.Widget));
    }

    fn newLyricLabel(text: []const u8) ?*gtk.Label {
        const alloc = std.heap.c_allocator;
        const text_z = alloc.dupeZ(u8, text) catch return null;
        defer alloc.free(text_z);
        const label = gtk.Label.new(text_z);
        label.setWrap(1);
        label.setWrapMode(.word_char);
        label.setXalign(1);
        label.setJustify(.right);
        label.as(gtk.Widget).addCssClass("lyric");
        label.as(gtk.Widget).setCanTarget(0);
        return label;
    }

    /// Highlights the line being sung and keeps it in view.
    fn updateLyrics(self: *Self) void {
        const priv = self.private();
        if (!priv.synced or priv.lyric_times.items.len == 0) return;

        // A little early, so the line is lit as it starts.
        const now_ms = @divTrunc(glib.getRealTime(), 1000);
        const pos = priv.pos_ms + (now_ms - priv.at_ms) + 200;
        var current: ?usize = null;
        for (priv.lyric_times.items, 0..) |t, i| {
            if (t > pos) break;
            current = i;
        }

        const changed = current != priv.current;
        if (changed) {
            priv.current = current;
            for (priv.lyric_labels.items, 0..) |label, i| {
                const w = label.as(gtk.Widget);
                const past = if (current) |c| i < c else false;
                const now = if (current) |c| i == c else false;
                if (past) w.addCssClass("lyric-past") else w.removeCssClass("lyric-past");
                if (now) w.addCssClass("lyric-current") else w.removeCssClass("lyric-current");
            }
        }

        if (priv.lyrics_revealer.getRevealChild() == 0) return;
        const held = glib.getMonotonicTime() - priv.user_scroll_at < 4 * std.time.us_per_s;
        if (held) return;
        if (changed or priv.need_scroll or priv.user_scrolled) {
            if (self.scrollToCurrent()) {
                priv.need_scroll = false;
                priv.user_scrolled = false;
            }
        }
    }

    /// Smoothly scrolls the current line to the middle of the sheet.
    /// Returns false when the sheet isn't laid out yet.
    fn scrollToCurrent(self: *Self) bool {
        const priv = self.private();
        const adj = priv.lyrics_scroll.getVadjustment();
        const page = adj.getPageSize();
        if (page <= 0) return false;

        var target: f64 = 0;
        if (priv.current) |c| {
            const label = priv.lyric_labels.items[c].as(gtk.Widget);
            var y: f64 = 0;
            if (label.translateCoordinates(priv.lyrics_box.as(gtk.Widget), 0, 0, null, &y) == 0)
                return false;
            const h: f64 = @floatFromInt(label.getHeight());
            if (h <= 0) return false;
            target = y + h / 2 - page / 2;
        }
        target = std.math.clamp(target, adj.getLower(), @max(adj.getLower(), adj.getUpper() - page));

        const anim = priv.scroll_anim orelse {
            adj.setValue(target);
            return true;
        };
        anim.setValueFrom(adj.getValue());
        anim.setValueTo(target);
        anim.as(adw.Animation).play();
        return true;
    }

    fn vinylClicked(
        _: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const open = priv.lyrics_revealer.getRevealChild() == 0;
        priv.lyrics_revealer.setRevealChild(@intFromBool(open));
        if (open) {
            priv.need_scroll = true;
            priv.user_scroll_at = 0;
            if (priv.lyrics_timer == null)
                priv.lyrics_timer = glib.timeoutAdd(200, onLyricsTick, self);
        } else if (priv.lyrics_timer) |v| {
            _ = glib.Source.remove(v);
            priv.lyrics_timer = null;
        }
    }

    fn lyricsScrolled(
        _: *gtk.EventControllerScroll,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        priv.user_scroll_at = glib.getMonotonicTime();
        priv.user_scrolled = true;
        if (priv.scroll_anim) |anim| anim.as(adw.Animation).pause();
        return 0; // let the sheet scroll
    }

    fn onLyricsTick(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.updateLyrics();
        return 1;
    }

    /// Clicks on the widget's empty space go through to the terminal.
    fn contains(_: *Self, _: f64, _: f64) callconv(.c) c_int {
        return 0;
    }

    fn loadCover(self: *Self, path: []const u8) void {
        const priv = self.private();
        if (priv.cover) |s| s.destroy();
        priv.cover = null;
        if (path.len == 0) return;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
        const surface = cairo.Surface.imageCreateFromPng(path_z);
        if (surface.status() != .success) {
            log.warn("unable to load album cover path={s}", .{path});
            surface.destroy();
            return;
        }
        priv.cover = surface;
    }

    /// Draws the cover as a record (round, with a spindle hole) and the
    /// song's progress as a clay ring around it, starting at 12 o'clock.
    fn drawVinyl(
        _: *gtk.DrawingArea,
        cr: *cairo.Context,
        width: c_int,
        height: c_int,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        const priv = self.private();

        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const cx = w / 2;
        const cy = h / 2;
        const ring_r = @min(w, h) / 2 - 1.5;
        const cover_r = ring_r - 5;
        const top = -std.math.pi / 2.0;

        // Ring track and progress.
        cr.setLineWidth(2);
        setColor(cr, ring_track);
        cr.newPath();
        cr.arc(cx, cy, ring_r, 0, 2 * std.math.pi);
        cr.stroke();
        if (priv.progress >= 0) {
            setColor(cr, clay);
            cr.setLineCap(.round);
            cr.newPath();
            cr.arc(cx, cy, ring_r, top, top + 2 * std.math.pi * priv.progress);
            cr.stroke();
        }

        // Cover, clipped to a circle.
        cr.save();
        cr.newPath();
        cr.arc(cx, cy, cover_r, 0, 2 * std.math.pi);
        cr.clip();
        if (priv.cover) |surface| {
            const iw: f64 = @floatFromInt(surface.imageGetWidth());
            const ih: f64 = @floatFromInt(surface.imageGetHeight());
            cr.translate(cx - cover_r, cy - cover_r);
            cr.scale(2 * cover_r / iw, 2 * cover_r / ih);
            cr.setSourceSurface(surface, 0, 0);
            cr.paint();
        } else {
            setColor(cr, cover_fallback);
            cr.paint();
        }
        cr.restore();

        // Spindle hole.
        cr.setSourceRgb(0, 0, 0);
        cr.newPath();
        cr.arc(cx, cy, 3.5, 0, 2 * std.math.pi);
        cr.fill();
    }

    const Rgb = struct { r: f64, g: f64, b: f64 };

    fn rgb(r: u8, g: u8, b: u8) Rgb {
        return .{
            .r = @as(f64, @floatFromInt(r)) / 255,
            .g = @as(f64, @floatFromInt(g)) / 255,
            .b = @as(f64, @floatFromInt(b)) / 255,
        };
    }

    fn setColor(cr: *cairo.Context, c: Rgb) void {
        cr.setSourceRgb(c.r, c.g, c.b);
    }

    fn onTick(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.refresh();
        return 1;
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tick_timer) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove corner widget timer", .{});
            }
            priv.tick_timer = null;
        }
        if (priv.lyrics_timer) |v| {
            _ = glib.Source.remove(v);
            priv.lyrics_timer = null;
        }
        if (priv.scroll_anim) |anim| {
            anim.as(gobject.Object).unref();
            priv.scroll_anim = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.cover) |s| {
            s.destroy();
            priv.cover = null;
        }
        priv.lyric_labels.deinit(std.heap.c_allocator);
        priv.lyric_times.deinit(std.heap.c_allocator);

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(PassBox);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "corner-widget",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("date_label", .{});
            class.bindTemplateChildPrivate("time_label", .{});
            class.bindTemplateChildPrivate("weather_label", .{});
            class.bindTemplateChildPrivate("song_box", .{});
            class.bindTemplateChildPrivate("artist_label", .{});
            class.bindTemplateChildPrivate("song_label", .{});
            class.bindTemplateChildPrivate("vinyl", .{});
            class.bindTemplateChildPrivate("lyrics_revealer", .{});
            class.bindTemplateChildPrivate("lyrics_scroll", .{});
            class.bindTemplateChildPrivate("lyrics_box", .{});

            // Signal handlers
            class.bindTemplateCallback("vinyl_clicked", &vinylClicked);
            class.bindTemplateCallback("lyrics_scrolled", &lyricsScrolled);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gtk.Widget.virtual_methods.contains.implement(class, &contains);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// A Box that doesn't claim its own empty space, so a click there goes to
/// whatever is underneath (the terminal) instead of stopping at the box.
/// Its children still get their clicks.
pub const PassBox = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyPassBox",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    fn contains(_: *Self, _: f64, _: f64) callconv(.c) c_int {
        return 0;
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.contains.implement(class, &contains);
        }
    };
};
