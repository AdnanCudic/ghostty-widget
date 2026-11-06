//! Fork addition: a layered popup glued to one terminal surface, for
//! drawing things over the OpenGL output (the corner widget and the SSH
//! badge). Same technique as Scrollbar.zig: SwapBuffers paints over child
//! windows, but DWM composites a WS_EX_LAYERED popup above it.
//!
//! The overlay is owned by the surface's top-level window, positioned in
//! screen coordinates from a rectangle relative to the surface's client
//! area, and shown only while it has something to show and its surface is
//! visible (Surface.syncOverlays is called on WM_WINDOWPOSCHANGED of both
//! the surface and its top-level window, so moves, tab switches, minimize
//! and the quick terminal sliding away all follow).
//!
//! Input: the owner decides per point whether the overlay takes the mouse
//! (hitTest). Everywhere else WM_NCHITTEST answers HTTRANSPARENT, so clicks,
//! selection drags and hovering go straight through to the terminal. The
//! overlay never takes focus (WS_EX_NOACTIVATE / MA_NOACTIVATE).
const Overlay = @This();

const std = @import("std");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_overlay);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyOverlay");

/// Callbacks into the overlay's owner. Coordinates are overlay-client
/// pixels.
pub const Handler = struct {
    ctx: *anyopaque,
    /// Whether the overlay takes the mouse at (x, y). Null: never.
    hitTest: ?*const fn (ctx: *anyopaque, x: i32, y: i32) bool = null,
    /// Mouse messages (WM_LBUTTONDOWN, WM_MOUSEMOVE, WM_MOUSEWHEEL, ...)
    /// for points where hitTest said yes.
    mouse: ?*const fn (ctx: *anyopaque, msg: u32, x: i32, y: i32, wparam: usize) void = null,
    /// WM_TIMER for timers set with setTimer.
    timer: ?*const fn (ctx: *anyopaque, id: usize) void = null,
    /// Whether to show the hand cursor at (x, y); the arrow otherwise.
    handCursor: ?*const fn (ctx: *anyopaque, x: i32, y: i32) bool = null,
};

hwnd: w32.HWND,
/// The terminal surface's child HWND the overlay follows.
surface_hwnd: w32.HWND,
handler: Handler,

/// Position and size relative to the surface's client area.
x: i32 = 0,
y: i32 = 0,
w: i32 = 1,
h: i32 = 1,

/// Whether the owner has something to show.
wanted: bool = false,
/// Whether the popup is currently shown.
shown: bool = false,
/// Keep the popup always on top; set for overlays in the quick terminal,
/// which is a topmost window (not every system reports that in its
/// extended style, so it is not left to detection alone).
topmost: bool = false,

pub fn create(
    alloc: std.mem.Allocator,
    surface_hwnd: w32.HWND,
    hinstance: w32.HINSTANCE,
    handler: Handler,
) !*Overlay {
    try registerClassOnce(hinstance);

    const self = try alloc.create(Overlay);
    errdefer alloc.destroy(self);

    const hwnd = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        1,
        1,
        surface_hwnd, // owner: the system makes the top-level window the owner
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;

    self.* = .{ .hwnd = hwnd, .surface_hwnd = surface_hwnd, .handler = handler };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    return self;
}

/// Moves the popup to a new owner window (the surface's tab was moved to
/// another window).
pub fn setOwner(self: *Overlay, owner: w32.HWND, topmost: bool) void {
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_HWNDPARENT, @bitCast(@intFromPtr(owner)));
    self.topmost = topmost;
    self.sync();
}

pub fn destroy(self: *Overlay, alloc: std.mem.Allocator) void {
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

/// Sets the rectangle (surface-client pixels) and moves the popup there.
pub fn setRect(self: *Overlay, x: i32, y: i32, w: i32, h: i32) void {
    self.x = x;
    self.y = y;
    self.w = @max(w, 1);
    self.h = @max(h, 1);
    self.reposition();
}

/// Follows the surface after it, or its window, moved. Also matches the
/// window's always-on-top state, so the overlay stays above a topmost
/// window such as the quick terminal.
pub fn reposition(self: *Overlay) void {
    var pt: w32.POINT = .{ .x = self.x, .y = self.y };
    _ = w32.ClientToScreen(self.surface_hwnd, &pt);
    const top = w32.GetAncestor(self.surface_hwnd, w32.GA_ROOT);
    const owner_topmost = if (top) |t|
        (@as(u32, @bitCast(w32.GetWindowLongW(t, w32.GWL_EXSTYLE))) & w32.WS_EX_TOPMOST) != 0
    else
        false;
    const self_topmost = (@as(u32, @bitCast(w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE))) & w32.WS_EX_TOPMOST) != 0;
    const z: ?w32.HWND = if (owner_topmost or self.topmost) w32.HWND_TOPMOST else if (self_topmost) w32.HWND_NOTOPMOST else null;
    _ = w32.SetWindowPos(
        self.hwnd,
        z,
        pt.x,
        pt.y,
        self.w,
        self.h,
        w32.SWP_NOACTIVATE | (if (z == null) w32.SWP_NOZORDER else 0),
    );
}

pub fn setWanted(self: *Overlay, wanted: bool) void {
    self.wanted = wanted;
    self.sync();
}

/// Shows the popup when wanted and the surface is visible on screen.
pub fn sync(self: *Overlay) void {
    const top = w32.GetAncestor(self.surface_hwnd, w32.GA_ROOT);
    const visible = self.wanted and
        w32.IsWindowVisible_(self.surface_hwnd) != 0 and
        (top == null or w32.IsIconic(top.?) == 0);
    if (visible) self.reposition();
    if (visible == self.shown) return;
    self.shown = visible;
    _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNOACTIVATE else w32.SW_HIDE);
}

pub fn setTimer(self: *Overlay, id: usize, ms: u32) void {
    _ = w32.SetTimer(self.hwnd, id, ms, null);
}

pub fn killTimer(self: *Overlay, id: usize) void {
    _ = w32.KillTimer(self.hwnd, id);
}

/// Paints the whole overlay: `draw` fills premultiplied BGRA pixels (top-down
/// rows, w*h, cleared to transparent), which then replace the popup's image.
pub fn paint(
    self: *Overlay,
    ctx: anytype,
    comptime draw: fn (@TypeOf(ctx), pixels: [*]u32, w: i32, h: i32) void,
) void {
    const w = self.w;
    const h = self.h;
    if (w <= 0 or h <= 0) return;

    const screen_dc = w32.GetDC(null) orelse return;
    defer _ = w32.ReleaseDC(null, screen_dc);
    const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);

    var bits: ?*anyopaque = null;
    const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
    const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = w32.DeleteObject(bitmap);
    const old = w32.SelectObject(mem_dc, bitmap);
    defer _ = w32.SelectObject(mem_dc, old.?);

    const pixels: [*]u32 = @ptrCast(@alignCast(bits orelse return));
    @memset(pixels[0..@intCast(w * h)], 0);
    draw(ctx, pixels, w, h);

    var pt: w32.POINT = .{ .x = self.x, .y = self.y };
    _ = w32.ClientToScreen(self.surface_hwnd, &pt);
    const size = w32.SIZE{ .cx = w, .cy = h };
    const src = w32.POINT{ .x = 0, .y = 0 };
    const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };
    if (w32.UpdateLayeredWindow(self.hwnd, screen_dc, &pt, &size, mem_dc, &src, 0, &blend, w32.ULW_ALPHA) == 0) {
        log.debug("UpdateLayeredWindow failed", .{});
    }
}

/// The popup's top-left corner on screen.
pub fn screenPos(self: *const Overlay) w32.POINT {
    var pt: w32.POINT = .{ .x = self.x, .y = self.y };
    _ = w32.ClientToScreen(self.surface_hwnd, &pt);
    return pt;
}

fn takesMouse(self: *Overlay, x: i32, y: i32) bool {
    const f = self.handler.hitTest orelse return false;
    return f(self.handler.ctx, x, y);
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn lowWord(v: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(v)) & 0xFFFF))));
}

fn highWord(v: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(v)) >> 16) & 0xFFFF))));
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (ud == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Overlay = @ptrFromInt(@as(usize, @bitCast(ud)));

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_NCHITTEST => {
            var pt: w32.POINT = .{ .x = lowWord(lparam), .y = highWord(lparam) };
            _ = w32.ScreenToClient(hwnd, &pt);
            return if (self.takesMouse(pt.x, pt.y)) w32.HTCLIENT_RESULT else w32.HTTRANSPARENT;
        },

        w32.WM_SETCURSOR => {
            if (self.handler.handCursor) |f| {
                var pt: w32.POINT = undefined;
                if (w32.GetCursorPos_(&pt) != 0) {
                    _ = w32.ScreenToClient(hwnd, &pt);
                    if (f(self.handler.ctx, pt.x, pt.y)) {
                        _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_HAND));
                        return 1;
                    }
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_TIMER => {
            if (self.handler.timer) |f| f(self.handler.ctx, wparam);
            return 0;
        },

        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_MOUSEMOVE,
        => {
            if (self.handler.mouse) |f| f(self.handler.ctx, msg, lowWord(lparam), highWord(lparam), wparam);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            // Wheel coordinates are in screen pixels.
            var pt: w32.POINT = .{ .x = lowWord(lparam), .y = highWord(lparam) };
            _ = w32.ScreenToClient(hwnd, &pt);
            if (self.handler.mouse) |f| f(self.handler.ctx, msg, pt.x, pt.y, wparam);
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
