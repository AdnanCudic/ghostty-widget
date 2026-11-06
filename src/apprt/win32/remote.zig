//! Fork addition: guess from a terminal title whether it belongs to an SSH
//! session, so the surface can show a red strip with the server name, its
//! tab can turn red, and custom shaders get iRemote.
//!
//! Shells set titles like `user@host:~` (bash, zsh, oh-my-posh), and shells
//! that show the running command (the PowerShell integration does) give
//! `ssh root@box` while it runs. On Windows the command may come as
//! `ssh.exe ...`, `C:\Windows\System32\OpenSSH\ssh.exe ...`, or cmd.exe's
//! `C:\WINDOWS\system32\cmd.exe - ssh ...`. A title is "remote" when its
//! command is ssh or mosh, or when its `user@host` names a host other than
//! this computer.
const std = @import("std");
const builtin = @import("builtin");

pub fn isRemoteTitle(title: []const u8) bool {
    return isRemoteTitleFor(title, localHostName());
}

/// The `user@host` (or bare host) to show for a remote title, e.g.
/// "ssh -p 22 root@box" -> "root@box", "root@box: ~" -> "root@box".
/// Returns null when the title isn't remote.
pub fn remoteHost(title: []const u8) ?[]const u8 {
    return remoteHostFor(title, localHostName());
}

pub fn isRemoteTitleFor(title: []const u8, local: []const u8) bool {
    const t = command(title);
    if (sshArgs(t) != null) return true;

    // user@host... with a single-word user part
    const at = std.mem.indexOfScalar(u8, t, '@') orelse return false;
    if (at == 0 or std.mem.indexOfAny(u8, t[0..at], " \t/\\") != null) return false;

    const rest = t[at + 1 ..];
    const host = rest[0 .. std.mem.indexOfAny(u8, rest, ": \t") orelse rest.len];
    if (host.len == 0) return false;
    return !isLocalHost(host, local);
}

pub fn remoteHostFor(title: []const u8, local: []const u8) ?[]const u8 {
    if (!isRemoteTitleFor(title, local)) return null;
    const t = command(title);

    if (sshArgs(t)) |args| {
        // First word with an @, else the first argument that isn't a flag
        // (or a flag's value: -p 22, -i key, -l user, ...).
        var words = std.mem.tokenizeAny(u8, args, " \t");
        var first_arg: ?[]const u8 = null;
        var skip_next = false;
        while (words.next()) |w| {
            if (skip_next) {
                skip_next = false;
                continue;
            }
            if (std.mem.indexOfScalar(u8, w, '@') != null) return w;
            if (w[0] == '-') {
                skip_next = w.len == 2 and std.mem.indexOfScalar(u8, "bcDEeFIiJLlmOopQRSWw", w[1]) != null;
                continue;
            }
            if (first_arg == null) first_arg = w;
        }
        return first_arg;
    }

    const at = std.mem.indexOfScalar(u8, t, '@').?;
    const rest = t[at + 1 ..];
    return t[0 .. at + 1 + (std.mem.indexOfAny(u8, rest, ": \t") orelse rest.len)];
}

/// The interesting part of a title: trimmed, without an "Administrator: "
/// prefix, and for cmd.exe's "C:\...\cmd.exe - command" the command.
fn command(title: []const u8) []const u8 {
    var t = std.mem.trim(u8, title, " \t");
    const admin = "Administrator: ";
    if (std.mem.startsWith(u8, t, admin)) t = t[admin.len..];
    if (std.mem.indexOf(u8, t, " - ")) |dash| {
        const before = t[0..dash];
        if (std.ascii.endsWithIgnoreCase(before, "cmd.exe") or
            std.ascii.endsWithIgnoreCase(before, "cmd"))
        {
            t = std.mem.trim(u8, t[dash + 3 ..], " \t");
        }
    }
    return t;
}

/// When the title runs ssh or mosh (any path, optional .exe), the rest of
/// the command line after the program name.
fn sshArgs(t: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, t, " \t") orelse return null;
    var prog = t[0..end];
    if (std.mem.lastIndexOfAny(u8, prog, "/\\")) |slash| prog = prog[slash + 1 ..];
    if (std.ascii.endsWithIgnoreCase(prog, ".exe")) prog = prog[0 .. prog.len - 4];
    if (!std.ascii.eqlIgnoreCase(prog, "ssh") and !std.ascii.eqlIgnoreCase(prog, "mosh")) return null;
    const args = std.mem.trim(u8, t[end..], " \t");
    if (args.len == 0) return null;
    return args;
}

fn isLocalHost(host: []const u8, local: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (local.len == 0) return false;
    return std.ascii.eqlIgnoreCase(shortName(host), shortName(local));
}

fn shortName(host: []const u8) []const u8 {
    return host[0 .. std.mem.indexOfScalar(u8, host, '.') orelse host.len];
}

var local_buf: [256]u8 = undefined;
var local_len: ?usize = null;

/// This computer's name (cached), in UTF-8.
fn localHostName() []const u8 {
    if (local_len) |n| return local_buf[0..n];
    var n: usize = 0;
    if (comptime builtin.os.tag == .windows) {
        const w32 = @import("win32.zig");
        var wbuf: [64]u16 = undefined;
        var size: u32 = wbuf.len;
        if (w32.GetComputerNameW(&wbuf, &size) != 0) {
            n = std.unicode.utf16LeToUtf8(&local_buf, wbuf[0..size]) catch 0;
        }
    }
    local_len = n;
    return local_buf[0..n];
}

test isRemoteTitleFor {
    const t = std.testing;
    try t.expect(isRemoteTitleFor("ssh root@box", "DESKTOP-1"));
    try t.expect(isRemoteTitleFor("ssh.exe box", "DESKTOP-1"));
    try t.expect(isRemoteTitleFor("C:\\Windows\\System32\\OpenSSH\\ssh.exe -p 2222 me@box", "DESKTOP-1"));
    try t.expect(isRemoteTitleFor("C:\\WINDOWS\\system32\\cmd.exe - ssh box", "DESKTOP-1"));
    try t.expect(isRemoteTitleFor("Administrator: ssh box", "DESKTOP-1"));
    try t.expect(isRemoteTitleFor("mosh box", "DESKTOP-1"));
    try t.expect(isRemoteTitleFor("root@some-server:~", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("adnan@desktop-1: ~", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("adnan@DESKTOP-1.lan:~", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("me@localhost:~", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("vim notes.txt", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("git push origin main", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("ssh", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("sshd_config", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("C:\\Users\\me", "DESKTOP-1"));
    try t.expect(!isRemoteTitleFor("git commit -m \"mail me@x\"", "DESKTOP-1"));
}

test remoteHostFor {
    const t = std.testing;
    try t.expectEqualStrings("root@box", remoteHostFor("ssh -p 22 root@box", "pc").?);
    try t.expectEqualStrings("box", remoteHostFor("ssh box", "pc").?);
    try t.expectEqualStrings("box", remoteHostFor("ssh -i C:\\key -p 22 box", "pc").?);
    try t.expectEqualStrings("box", remoteHostFor("C:\\WINDOWS\\system32\\cmd.exe - ssh box", "pc").?);
    try t.expectEqualStrings("root@box", remoteHostFor("root@box: ~", "pc").?);
    try t.expect(remoteHostFor("vim", "pc") == null);
}
