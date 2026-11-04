//! Fork addition: guess from a terminal title whether it belongs to an SSH
//! session, so the tab pill and the surface border can warn you before
//! typing into a server.
//!
//! Shells set titles like `user@host:~` (zsh/oh-my-zsh, Ubuntu's bash), and
//! oh-my-zsh shows the running command (`ssh root@ucx1`) while it runs. A
//! title is "remote" when it starts with ssh/mosh, or when its `user@host`
//! names a host other than this computer.
const std = @import("std");
const glib = @import("glib");

pub fn isRemoteTitle(title: []const u8) bool {
    const t = std.mem.trim(u8, title, " \t");
    if (std.mem.startsWith(u8, t, "ssh ") or std.mem.startsWith(u8, t, "mosh ")) return true;

    // user@host... with a single-word user part
    const at = std.mem.indexOfScalar(u8, t, '@') orelse return false;
    if (at == 0 or std.mem.indexOfAny(u8, t[0..at], " \t/") != null) return false;

    const rest = t[at + 1 ..];
    const host = rest[0 .. std.mem.indexOfAny(u8, rest, ": \t") orelse rest.len];
    if (host.len == 0) return false;
    return !isLocalHost(host);
}

/// The `user@host` (or bare host) to show for a remote title, e.g.
/// "ssh -p 22 root@ucx1" -> "root@ucx1", "root@ucx1: ~" -> "root@ucx1".
/// Returns null when the title isn't remote.
pub fn remoteHost(title: []const u8) ?[]const u8 {
    if (!isRemoteTitle(title)) return null;
    const t = std.mem.trim(u8, title, " \t");

    if (std.mem.startsWith(u8, t, "ssh ") or std.mem.startsWith(u8, t, "mosh ")) {
        // First word with an @, else the first argument that isn't a flag.
        var words = std.mem.tokenizeAny(u8, t, " \t");
        _ = words.next();
        var first_arg: ?[]const u8 = null;
        while (words.next()) |w| {
            if (std.mem.indexOfScalar(u8, w, '@') != null) return w;
            if (first_arg == null and w[0] != '-') first_arg = w;
        }
        return first_arg;
    }

    const at = std.mem.indexOfScalar(u8, t, '@').?;
    const rest = t[at + 1 ..];
    return t[0 .. at + 1 + (std.mem.indexOfAny(u8, rest, ": \t") orelse rest.len)];
}

fn isLocalHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    const local = std.mem.span(glib.getHostName());
    return std.ascii.eqlIgnoreCase(shortName(host), shortName(local));
}

fn shortName(host: []const u8) []const u8 {
    return host[0 .. std.mem.indexOfScalar(u8, host, '.') orelse host.len];
}

test isRemoteTitle {
    try std.testing.expect(isRemoteTitle("ssh root@ucx1"));
    try std.testing.expect(isRemoteTitle("root@some-server-that-is-not-here:~"));
    try std.testing.expect(!isRemoteTitle("vim notes.txt"));
    try std.testing.expect(!isRemoteTitle("git push origin main"));
    try std.testing.expect(!isRemoteTitle("me@localhost:~"));
}

test remoteHost {
    try std.testing.expectEqualStrings("root@ucx1", remoteHost("ssh -p 22 root@ucx1").?);
    try std.testing.expectEqualStrings("box", remoteHost("ssh box").?);
}
