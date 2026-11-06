//! Fork addition: while a terminal is in an SSH session, a red strip along
//! its top edge with the server name hanging from it in a small tab (the
//! Win32 version of the GTK fork's `.remote-strip` / `.remote-host`).
//! Purely visual: every click goes through to the terminal.
const RemoteBadge = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const gdip = @import("gdip.zig");
const Overlay = @import("Overlay.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const red = gdip.rgb(0xE24B4A);
const white = gdip.rgb(0xFFFFFF);

const font_names = [_][:0]const u16{
    L("Space Grotesk Medium"),
    L("Space Grotesk"),
    L("Segoe UI Semibold"),
    L("Segoe UI"),
};

overlay: *Overlay,
/// The server name, UTF-16.
host: [128]u16 = undefined,
host_len: usize = 0,
remote: bool = false,
scale: f32 = 1,
/// Surface client width, pixels.
width: i32 = 1,

pub fn create(alloc: std.mem.Allocator, surface_hwnd: w32.HWND, hinstance: w32.HINSTANCE) !*RemoteBadge {
    const self = try alloc.create(RemoteBadge);
    errdefer alloc.destroy(self);
    self.* = .{ .overlay = undefined };
    self.overlay = try Overlay.create(alloc, surface_hwnd, hinstance, .{ .ctx = self });
    return self;
}

pub fn destroy(self: *RemoteBadge, alloc: std.mem.Allocator) void {
    self.overlay.destroy(alloc);
    alloc.destroy(self);
}

/// Called when the surface title changes. `host` is null when not remote.
pub fn setHost(self: *RemoteBadge, host: ?[]const u8) void {
    const new_remote = host != null;
    var buf: [128]u16 = undefined;
    const h16 = gdip.utf16(&buf, host orelse "");
    if (new_remote == self.remote and std.mem.eql(u16, h16, self.host[0..self.host_len])) return;
    @memcpy(self.host[0..h16.len], h16);
    self.host_len = h16.len;
    self.remote = new_remote;
    if (self.remote) self.layout();
    self.overlay.setWanted(self.remote);
}

/// Called when the surface is resized or its DPI changes.
pub fn resize(self: *RemoteBadge, width: i32, scale: f32) void {
    self.width = width;
    self.scale = scale;
    if (self.remote) self.layout();
}

fn layout(self: *RemoteBadge) void {
    const height: i32 = @intFromFloat(@ceil(22.0 * self.scale));
    self.overlay.setRect(0, 0, self.width, height);
    self.overlay.paint(self, draw);
}

fn draw(self: *RemoteBadge, pixels: [*]u32, w: i32, h: i32) void {
    if (!gdip.startup()) return;
    const canvas = gdip.Canvas.init(pixels, w, h) orelse return;
    defer canvas.deinit();

    const s = self.scale;
    const fw: f32 = @floatFromInt(w);
    const strip = @max(2.0, @round(3.0 * s));
    canvas.fillRect(red, 0, 0, fw, strip);

    if (self.host_len == 0) return;
    const font = gdip.Font.init(&font_names, 11.0 * s, .regular) orelse return;
    defer font.deinit();
    const text = self.host[0..self.host_len];
    const size = canvas.measure(font, text);
    const pad_x = 12.0 * s;
    const label_w = @min(size[0] + 2 * pad_x, fw);
    const label_h = size[1] + 4.0 * s;
    const x = @round((fw - label_w) / 2);
    canvas.fillRoundRect(red, x, strip - 1, label_w, label_h + 1, 7.0 * s, .{ .tl = false, .tr = false });
    canvas.drawText(font, white, text, x, strip, label_w, label_h - 1.0 * s, .center);
}
