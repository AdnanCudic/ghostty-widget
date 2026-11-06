//! Fork addition: a small slice of the GDI+ flat API, enough to paint the
//! corner widget and the SSH badge into the per-pixel-alpha bitmaps that
//! layered windows (UpdateLayeredWindow) take.
//!
//! GDI+ is used instead of plain GDI because GDI text and shapes do not
//! write alpha: drawn into a 32-bit DIB they come out fully transparent.
//! GDI+ drawing into a PARGB bitmap gives antialiased text, ellipses, arcs
//! and image scaling with correct premultiplied alpha.
const std = @import("std");

const log = std.log.scoped(.win32_gdip);

pub const Status = c_int;
pub const Ok: Status = 0;

pub const GpGraphics = opaque {};
pub const GpImage = opaque {};
pub const GpBitmap = opaque {};
pub const GpBrush = opaque {};
pub const GpSolidFill = opaque {};
pub const GpPen = opaque {};
pub const GpFont = opaque {};
pub const GpFontFamily = opaque {};
pub const GpFontCollection = opaque {};
pub const GpStringFormat = opaque {};
pub const GpPath = opaque {};
pub const IStream = opaque {};

pub const RectF = extern struct { x: f32, y: f32, w: f32, h: f32 };

const StartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*anyopaque = null,
    SuppressBackgroundThread: i32 = 0,
    SuppressExternalCodecs: i32 = 0,
};

pub const PixelFormat32bppPARGB: i32 = 0x000E200B;
const SmoothingModeAntiAlias: c_int = 4;
const TextRenderingHintAntiAliasGridFit: c_int = 3;
const InterpolationModeHighQualityBicubic: c_int = 7;
const PixelOffsetModeHalf: c_int = 4;
const UnitPixel: c_int = 2;
const CombineModeReplace: c_int = 0;
const FillModeAlternate: c_int = 0;
const LineCapRound: c_int = 2;
const StringFormatFlagsNoWrap: c_int = 0x00001000;
const StringFormatFlagsNoClip: c_int = 0x00004000;
const StringTrimmingEllipsisCharacter: c_int = 3;

pub const FontStyle = enum(c_int) { regular = 0, bold = 1 };
pub const Align = enum(c_int) { near = 0, center = 1, far = 2 };

extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const StartupInput, output: ?*anyopaque) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateBitmapFromScan0(w: c_int, h: c_int, stride: c_int, format: i32, scan0: ?[*]u8, bitmap: *?*GpBitmap) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateBitmapFromStream(stream: *IStream, bitmap: *?*GpBitmap) callconv(.winapi) Status;
extern "gdiplus" fn GdipGetImageGraphicsContext(image: *GpImage, graphics: *?*GpGraphics) callconv(.winapi) Status;
extern "gdiplus" fn GdipDisposeImage(image: *GpImage) callconv(.winapi) Status;
extern "gdiplus" fn GdipGetImageWidth(image: *GpImage, w: *c_uint) callconv(.winapi) Status;
extern "gdiplus" fn GdipGetImageHeight(image: *GpImage, h: *c_uint) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeleteGraphics(g: *GpGraphics) callconv(.winapi) Status;
extern "gdiplus" fn GdipGraphicsClear(g: *GpGraphics, argb: u32) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetSmoothingMode(g: *GpGraphics, mode: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetTextRenderingHint(g: *GpGraphics, hint: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetInterpolationMode(g: *GpGraphics, mode: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetPixelOffsetMode(g: *GpGraphics, mode: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetClipRect(g: *GpGraphics, x: f32, y: f32, w: f32, h: f32, mode: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetClipPath(g: *GpGraphics, path: *GpPath, mode: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipResetClip(g: *GpGraphics) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateSolidFill(argb: u32, brush: *?*GpSolidFill) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeleteBrush(brush: *GpBrush) callconv(.winapi) Status;
extern "gdiplus" fn GdipFillRectangle(g: *GpGraphics, brush: *GpBrush, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipFillEllipse(g: *GpGraphics, brush: *GpBrush, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipFillPath(g: *GpGraphics, brush: *GpBrush, path: *GpPath) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreatePen1(argb: u32, width: f32, unit: c_int, pen: *?*GpPen) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeletePen(pen: *GpPen) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetPenStartCap(pen: *GpPen, cap: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetPenEndCap(pen: *GpPen, cap: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipDrawArc(g: *GpGraphics, pen: *GpPen, x: f32, y: f32, w: f32, h: f32, start: f32, sweep: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipDrawEllipse(g: *GpGraphics, pen: *GpPen, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipDrawImageRect(g: *GpGraphics, image: *GpImage, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreatePath(mode: c_int, path: *?*GpPath) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeletePath(path: *GpPath) callconv(.winapi) Status;
extern "gdiplus" fn GdipAddPathEllipse(path: *GpPath, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipAddPathArc(path: *GpPath, x: f32, y: f32, w: f32, h: f32, start: f32, sweep: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipAddPathLine(path: *GpPath, x1: f32, y1: f32, x2: f32, y2: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipClosePathFigure(path: *GpPath) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateFontFamilyFromName(name: [*:0]const u16, collection: ?*GpFontCollection, family: *?*GpFontFamily) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeleteFontFamily(family: *GpFontFamily) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateFont(family: *GpFontFamily, size: f32, style: c_int, unit: c_int, font: *?*GpFont) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeleteFont(font: *GpFont) callconv(.winapi) Status;
extern "gdiplus" fn GdipStringFormatGetGenericTypographic(format: *?*GpStringFormat) callconv(.winapi) Status;
extern "gdiplus" fn GdipCloneStringFormat(format: *GpStringFormat, clone: *?*GpStringFormat) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeleteStringFormat(format: *GpStringFormat) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetStringFormatAlign(format: *GpStringFormat, a: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetStringFormatLineAlign(format: *GpStringFormat, a: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetStringFormatFlags(format: *GpStringFormat, flags: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetStringFormatTrimming(format: *GpStringFormat, trimming: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipDrawString(g: *GpGraphics, str: [*]const u16, len: c_int, font: *GpFont, rect: *const RectF, format: ?*GpStringFormat, brush: *GpBrush) callconv(.winapi) Status;
extern "gdiplus" fn GdipMeasureString(g: *GpGraphics, str: [*]const u16, len: c_int, font: *GpFont, rect: *const RectF, format: ?*GpStringFormat, bounds: *RectF, fitted: ?*c_int, lines: ?*c_int) callconv(.winapi) Status;

extern "shlwapi" fn SHCreateMemStream(data: [*]const u8, len: c_uint) callconv(.winapi) ?*IStream;

var started: bool = false;
var token: usize = 0;

/// Start GDI+ once per process. Returns false (and logs) when unavailable.
pub fn startup() bool {
    if (started) return true;
    const input: StartupInput = .{};
    if (GdiplusStartup(&token, &input, null) != Ok) {
        log.warn("GdiplusStartup failed", .{});
        return false;
    }
    started = true;
    return true;
}

/// 0xAARRGGBB, not premultiplied (GDI+ premultiplies when drawing).
pub fn argb(a: u8, r: u8, g: u8, b: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

pub fn rgb(hex: u24) u32 {
    return 0xFF000000 | @as(u32, hex);
}

pub fn withAlpha(color: u32, a: u8) u32 {
    return (color & 0x00FFFFFF) | (@as(u32, a) << 24);
}

/// A font with its family; deinit frees both.
pub const Font = struct {
    family: *GpFontFamily,
    font: *GpFont,
    px: f32,

    /// The first family in `names` that is installed, at `px` pixels.
    pub fn init(names: []const [:0]const u16, px: f32, style: FontStyle) ?Font {
        for (names) |name| {
            var family: ?*GpFontFamily = null;
            if (GdipCreateFontFamilyFromName(name.ptr, null, &family) != Ok) continue;
            const fam = family orelse continue;
            var font: ?*GpFont = null;
            if (GdipCreateFont(fam, px, @backingInt(style), UnitPixel, &font) != Ok) {
                _ = GdipDeleteFontFamily(fam);
                continue;
            }
            return .{ .family = fam, .font = font.?, .px = px };
        }
        return null;
    }

    pub fn deinit(self: Font) void {
        _ = GdipDeleteFont(self.font);
        _ = GdipDeleteFontFamily(self.family);
    }
};

/// A decoded image (album cover). Owns its memory stream, which GDI+ needs
/// for as long as the bitmap lives.
pub const Image = struct {
    bitmap: *GpBitmap,
    stream: *IStream,

    pub fn fromBytes(data: []const u8) ?Image {
        const stream = SHCreateMemStream(data.ptr, @intCast(data.len)) orelse return null;
        var bitmap: ?*GpBitmap = null;
        if (GdipCreateBitmapFromStream(stream, &bitmap) != Ok or bitmap == null) {
            releaseStream(stream);
            return null;
        }
        return .{ .bitmap = bitmap.?, .stream = stream };
    }

    pub fn deinit(self: Image) void {
        _ = GdipDisposeImage(@ptrCast(self.bitmap));
        releaseStream(self.stream);
    }

    fn releaseStream(stream: *IStream) void {
        // IUnknown::Release is the third vtable slot.
        const Vtbl = extern struct {
            QueryInterface: *const anyopaque,
            AddRef: *const anyopaque,
            Release: *const fn (*IStream) callconv(.winapi) u32,
        };
        const obj: *const *const Vtbl = @ptrCast(@alignCast(stream));
        _ = obj.*.Release(stream);
    }
};

/// Draws into caller-owned premultiplied BGRA pixels (top-down rows), the
/// layout a layered window's DIB section uses.
pub const Canvas = struct {
    bitmap: *GpBitmap,
    g: *GpGraphics,
    format: *GpStringFormat,

    pub fn init(pixels: [*]u32, w: i32, h: i32) ?Canvas {
        var bitmap: ?*GpBitmap = null;
        if (GdipCreateBitmapFromScan0(w, h, w * 4, PixelFormat32bppPARGB, @ptrCast(pixels), &bitmap) != Ok) return null;
        const bmp = bitmap orelse return null;
        var g: ?*GpGraphics = null;
        if (GdipGetImageGraphicsContext(@ptrCast(bmp), &g) != Ok or g == null) {
            _ = GdipDisposeImage(@ptrCast(bmp));
            return null;
        }
        var generic: ?*GpStringFormat = null;
        var format: ?*GpStringFormat = null;
        if (GdipStringFormatGetGenericTypographic(&generic) != Ok or
            GdipCloneStringFormat(generic.?, &format) != Ok)
        {
            _ = GdipDeleteGraphics(g.?);
            _ = GdipDisposeImage(@ptrCast(bmp));
            return null;
        }
        _ = GdipSetStringFormatFlags(format.?, StringFormatFlagsNoWrap | StringFormatFlagsNoClip);
        _ = GdipSetStringFormatTrimming(format.?, StringTrimmingEllipsisCharacter);
        _ = GdipSetSmoothingMode(g.?, SmoothingModeAntiAlias);
        _ = GdipSetTextRenderingHint(g.?, TextRenderingHintAntiAliasGridFit);
        _ = GdipSetInterpolationMode(g.?, InterpolationModeHighQualityBicubic);
        _ = GdipSetPixelOffsetMode(g.?, PixelOffsetModeHalf);
        _ = GdipGraphicsClear(g.?, 0);
        return .{ .bitmap = bmp, .g = g.?, .format = format.? };
    }

    /// Flushes drawing into the caller's pixels.
    pub fn deinit(self: Canvas) void {
        _ = GdipDeleteStringFormat(self.format);
        _ = GdipDeleteGraphics(self.g);
        _ = GdipDisposeImage(@ptrCast(self.bitmap));
    }

    pub fn fillRect(self: Canvas, color: u32, x: f32, y: f32, w: f32, h: f32) void {
        const brush = solid(color) orelse return;
        defer _ = GdipDeleteBrush(@ptrCast(brush));
        _ = GdipFillRectangle(self.g, @ptrCast(brush), x, y, w, h);
    }

    pub fn fillCircle(self: Canvas, color: u32, cx: f32, cy: f32, r: f32) void {
        const brush = solid(color) orelse return;
        defer _ = GdipDeleteBrush(@ptrCast(brush));
        _ = GdipFillEllipse(self.g, @ptrCast(brush), cx - r, cy - r, 2 * r, 2 * r);
    }

    /// A rectangle with the given corners rounded (radius r).
    pub fn fillRoundRect(
        self: Canvas,
        color: u32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        r: f32,
        corners: struct { tl: bool = true, tr: bool = true, br: bool = true, bl: bool = true },
    ) void {
        var path_opt: ?*GpPath = null;
        if (GdipCreatePath(FillModeAlternate, &path_opt) != Ok) return;
        const path = path_opt orelse return;
        defer _ = GdipDeletePath(path);
        const d = 2 * r;
        if (corners.tl) _ = GdipAddPathArc(path, x, y, d, d, 180, 90) else _ = GdipAddPathLine(path, x, y, x, y);
        if (corners.tr) _ = GdipAddPathArc(path, x + w - d, y, d, d, 270, 90) else _ = GdipAddPathLine(path, x + w, y, x + w, y);
        if (corners.br) _ = GdipAddPathArc(path, x + w - d, y + h - d, d, d, 0, 90) else _ = GdipAddPathLine(path, x + w, y + h, x + w, y + h);
        if (corners.bl) _ = GdipAddPathArc(path, x, y + h - d, d, d, 90, 90) else _ = GdipAddPathLine(path, x, y + h, x, y + h);
        _ = GdipClosePathFigure(path);
        const brush = solid(color) orelse return;
        defer _ = GdipDeleteBrush(@ptrCast(brush));
        _ = GdipFillPath(self.g, @ptrCast(brush), path);
    }

    /// An arc of a circle; angles in degrees, 0 = 3 o'clock, clockwise.
    pub fn arc(self: Canvas, color: u32, width: f32, cx: f32, cy: f32, r: f32, start: f32, sweep: f32, round_caps: bool) void {
        var pen: ?*GpPen = null;
        if (GdipCreatePen1(color, width, UnitPixel, &pen) != Ok) return;
        defer _ = GdipDeletePen(pen.?);
        if (round_caps) {
            _ = GdipSetPenStartCap(pen.?, LineCapRound);
            _ = GdipSetPenEndCap(pen.?, LineCapRound);
        }
        if (sweep >= 360) {
            _ = GdipDrawEllipse(self.g, pen.?, cx - r, cy - r, 2 * r, 2 * r);
        } else {
            _ = GdipDrawArc(self.g, pen.?, cx - r, cy - r, 2 * r, 2 * r, start, sweep);
        }
    }

    /// Draws `image` scaled into the circle (cx, cy, r).
    pub fn imageInCircle(self: Canvas, image: Image, cx: f32, cy: f32, r: f32) void {
        var path_opt: ?*GpPath = null;
        if (GdipCreatePath(FillModeAlternate, &path_opt) != Ok) return;
        const path = path_opt orelse return;
        defer _ = GdipDeletePath(path);
        _ = GdipAddPathEllipse(path, cx - r, cy - r, 2 * r, 2 * r);
        _ = GdipSetClipPath(self.g, path, CombineModeReplace);
        defer _ = GdipResetClip(self.g);
        _ = GdipDrawImageRect(self.g, @ptrCast(image.bitmap), cx - r, cy - r, 2 * r, 2 * r);
    }

    pub fn clipRect(self: Canvas, x: f32, y: f32, w: f32, h: f32) void {
        _ = GdipSetClipRect(self.g, x, y, w, h, CombineModeReplace);
    }

    pub fn resetClip(self: Canvas) void {
        _ = GdipResetClip(self.g);
    }

    /// Width and height of `text` on one line.
    pub fn measure(self: Canvas, font: Font, str: []const u16) [2]f32 {
        if (str.len == 0) return .{ 0, font.px * 1.2 };
        const layout: RectF = .{ .x = 0, .y = 0, .w = 100000, .h = 100000 };
        var bounds: RectF = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        _ = GdipSetStringFormatAlign(self.format, @backingInt(Align.near));
        _ = GdipMeasureString(self.g, str.ptr, @intCast(str.len), font.font, &layout, self.format, &bounds, null, null);
        return .{ bounds.w, bounds.h };
    }

    /// Draws `text` on one line inside (x, y, w, h), aligned horizontally
    /// as asked and vertically centred; ellipsized when too wide.
    pub fn drawText(self: Canvas, font: Font, color: u32, str: []const u16, x: f32, y: f32, w: f32, h: f32, al: Align) void {
        if (str.len == 0) return;
        const brush = solid(color) orelse return;
        defer _ = GdipDeleteBrush(@ptrCast(brush));
        _ = GdipSetStringFormatAlign(self.format, @backingInt(al));
        _ = GdipSetStringFormatLineAlign(self.format, @backingInt(Align.center));
        const rect: RectF = .{ .x = x, .y = y, .w = w, .h = h };
        _ = GdipDrawString(self.g, str.ptr, @intCast(str.len), font.font, &rect, self.format, @ptrCast(brush));
    }

    fn solid(color: u32) ?*GpSolidFill {
        var brush: ?*GpSolidFill = null;
        if (GdipCreateSolidFill(color, &brush) != Ok) return null;
        return brush;
    }
};

/// UTF-8 to UTF-16 into `buf` (truncating), with U+FFFD for invalid
/// bytes; returns the filled slice.
pub fn utf16(buf: []u16, s: []const u8) []const u16 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n + 2 <= buf.len) {
        var cp: u21 = 0xFFFD;
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |l| {
            if (i + l <= s.len) {
                if (std.unicode.utf8Decode(s[i .. i + l])) |c| {
                    cp = c;
                    len = l;
                } else |_| {}
            }
        } else |_| {}
        i += len;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (v >> 10));
            buf[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        } else {
            buf[n] = @intCast(cp);
            n += 1;
        }
    }
    return buf[0..n];
}

test utf16 {
    var buf: [16]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0x00B7, 'b' }, utf16(&buf, "a\xc2\xb7b"));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b' }, utf16(&buf, "a\xffb"));
    try std.testing.expectEqualSlices(u16, &.{ 0xD83C, 0xDFB5 }, utf16(&buf, "\xf0\x9f\x8e\xb5"));
    try std.testing.expectEqual(@as(usize, 2), utf16(buf[0..3], "abcdef").len);
}
