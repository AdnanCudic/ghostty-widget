const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_corner_widget);

/// Fork addition: a small widget pinned to the top-right corner of every
/// terminal showing the date, a big clock, the weather and the song playing
/// in the room.
///
/// It only displays data. The ghostty-widget service (contrib/corner-widget)
/// fetches weather and recognises music, and writes key/value line pairs to
/// $XDG_RUNTIME_DIR/ghostty-widget/state, which we re-read every second.
/// The widget never takes input, so clicks and selection go straight
/// through to the terminal.
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

    const Private = struct {
        date_label: *gtk.Label,
        time_label: *gtk.Label,
        weather_label: *gtk.Label,
        song_box: *gtk.Box,
        song_label: *gtk.Label,
        song_progress: *gtk.ProgressBar,
        eq1: *gtk.Box,
        eq2: *gtk.Box,
        eq3: *gtk.Box,
        eq4: *gtk.Box,

        /// Refreshes text once a second.
        tick_timer: ?c_uint = null,

        /// Animates the equaliser bars while a song is shown.
        eq_timer: ?c_uint = null,

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
        s_pos0: i64 = 0,
        s_at: i64 = 0,
        s_len: i64 = 0,

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
                if (std.mem.eql(u8, key, "s_pos0")) self.s_pos0 = std.fmt.parseInt(i64, value, 10) catch 0;
                if (std.mem.eql(u8, key, "s_at")) self.s_at = std.fmt.parseInt(i64, value, 10) catch 0;
                if (std.mem.eql(u8, key, "s_len")) self.s_len = std.fmt.parseInt(i64, value, 10) catch 0;
            }
        }
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();
        self.refresh();
        priv.tick_timer = glib.timeoutAdd(1000, onTick, self);
        priv.eq_timer = glib.timeoutAdd(140, onEq, self);
    }

    fn refresh(self: *Self) void {
        const priv = self.private();

        const now_dt = glib.DateTime.newNowLocal() orelse return;
        defer now_dt.unref();
        const now = now_dt.toUnix();

        // THU · 23 · OCT
        if (now_dt.format("%a · %d · %b")) |s| {
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

        var buf: [512]u8 = undefined;
        const weather: [:0]const u8 = if (st.w_temp.len > 0)
            std.fmt.bufPrintZ(&buf, "{s} {s}° · wind {s} km/h", .{
                st.w_sym, st.w_temp, st.w_wind,
            }) catch ""
        else
            "";
        priv.weather_label.setLabel(weather);
        priv.weather_label.as(gtk.Widget).setVisible(@intFromBool(weather.len > 0));

        if (st.s_title.len == 0) {
            priv.song_box.as(gtk.Widget).setVisible(0);
            return;
        }

        var song_buf: [512]u8 = undefined;
        const song = std.fmt.bufPrintZ(&song_buf, "{s} — {s}", .{
            st.s_title, st.s_artist,
        }) catch "";
        priv.song_label.setLabel(song);
        priv.song_box.as(gtk.Widget).setVisible(1);

        // Song position: where Shazam placed the clip, plus time since then.
        const pos = st.s_pos0 + (now - st.s_at);
        const show_progress = st.s_len > 0 and pos >= 0 and pos <= st.s_len;
        priv.song_progress.as(gtk.Widget).setVisible(@intFromBool(show_progress));
        if (show_progress) priv.song_progress.setFraction(
            @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(st.s_len)),
        );
    }

    fn onTick(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.refresh();
        return 1;
    }

    fn onEq(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        if (priv.song_box.as(gtk.Widget).getVisible() == 0) return 1;
        const bars = [_]*gtk.Box{ priv.eq1, priv.eq2, priv.eq3, priv.eq4 };
        for (bars) |bar| {
            const h = std.crypto.random.intRangeAtMost(c_int, 3, 12);
            bar.as(gtk.Widget).setSizeRequest(3, h);
        }
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
        if (priv.eq_timer) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove corner widget eq timer", .{});
            }
            priv.eq_timer = null;
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
            class.bindTemplateChildPrivate("song_label", .{});
            class.bindTemplateChildPrivate("song_progress", .{});
            class.bindTemplateChildPrivate("eq1", .{});
            class.bindTemplateChildPrivate("eq2", .{});
            class.bindTemplateChildPrivate("eq3", .{});
            class.bindTemplateChildPrivate("eq4", .{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
