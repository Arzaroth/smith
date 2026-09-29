//! Runs the user's git, always with an argument vector, never a shell.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ctx = @import("Ctx.zig");

fn argv(ctx: *const Ctx, args: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(ctx.alloc, "git");
    if (ctx.cwd) |d| try list.appendSlice(ctx.alloc, &.{ "-C", d });
    try list.appendSlice(ctx.alloc, args);
    return list.toOwnedSlice(ctx.alloc);
}

/// Runs git and returns its trimmed stdout, or null when it exits non-zero.
pub fn capture(ctx: *Ctx, args: []const []const u8) !?[]const u8 {
    const result = std.process.run(ctx.alloc, ctx.io, .{ .argv = try argv(ctx, args), .environ_map = ctx.env }) catch |e|
        return ctx.fail("cannot run git: {t}", .{e});
    if (result.term != .exited or result.term.exited != 0) return null;
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

/// Runs git with its output on stderr, keeping smith's stdout for smith's own
/// output; a failure is reported.
pub fn run(ctx: *Ctx, args: []const []const u8) !void {
    try ctx.out.flush();
    try ctx.err.flush();
    var child = std.process.spawn(ctx.io, .{
        .argv = try argv(ctx, args),
        .stdin = .ignore,
        .stdout = .{ .file = .stderr() },
        .environ_map = ctx.env,
    }) catch |e|
        return ctx.fail("cannot run git: {t}", .{e});
    const term = try child.wait(ctx.io);
    if (term != .exited or term.exited != 0) {
        const joined = try std.mem.join(ctx.alloc, " ", args);
        return ctx.fail("git {s} failed", .{joined});
    }
}

pub const Remote = struct {
    name: []const u8,
    /// The URL git fetches from, after `insteadOf` rewriting.
    url: []const u8,
    /// The URL as configured, when it differs from `url`.
    configured: ?[]const u8 = null,

    /// Parses the effective URL, else the configured one: an `insteadOf`
    /// alias can hide the host either way round.
    pub fn parse(r: Remote) ?RemoteUrl {
        if (parseRemoteUrl(r.url)) |u| return u;
        return parseRemoteUrl(r.configured orelse return null);
    }
};

pub fn remotes(ctx: *Ctx) ![]const Remote {
    const out = try capture(ctx, &.{ "remote", "-v" }) orelse return &.{};
    const list = try parseRemotes(ctx.alloc, out);
    const raw = try capture(ctx, &.{ "config", "--get-regexp", "^remote\\..+\\.url$" }) orelse return list;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const name = key["remote.".len .. key.len - ".url".len];
        const url = line[space + 1 ..];
        for (list) |*r| if (std.mem.eql(u8, r.name, name) and !std.mem.eql(u8, r.url, url)) {
            r.configured = url;
        };
    }
    return list;
}

pub fn parseRemotes(alloc: Allocator, out: []const u8) ![]Remote {
    var list: std.ArrayList(Remote) = .empty;
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, "(fetch)")) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const url = fields.next() orelse continue;
        try list.append(alloc, .{ .name = name, .url = url });
    }
    return list.toOwnedSlice(alloc);
}

pub fn currentBranch(ctx: *Ctx) !?[]const u8 {
    return capture(ctx, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" });
}

pub const RemoteUrl = struct {
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
    ssh: bool,
    /// "https", "http" or "ssh".
    scheme: []const u8 = "ssh",
};

/// Understands `git@host:owner/repo.git`, `ssh://git@host:22/owner/repo.git`
/// and `https://host[:port]/owner/repo(.git)`. An http(s) host keeps its port,
/// since it is part of the web address; an ssh one drops it.
pub fn parseRemoteUrl(url: []const u8) ?RemoteUrl {
    var host: []const u8 = undefined;
    var path: []const u8 = undefined;
    var ssh = false;
    var url_scheme: []const u8 = "ssh";
    if (std.mem.indexOf(u8, url, "://")) |i| {
        const scheme = url[0..i];
        const rest = url[i + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        var authority = rest[0..slash];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        ssh = std.mem.eql(u8, scheme, "ssh") or std.mem.eql(u8, scheme, "git+ssh");
        if (!ssh) url_scheme = scheme;
        if (!ssh and !std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "http")) return null;
        host = if (ssh) (if (std.mem.indexOfScalar(u8, authority, ':')) |c| authority[0..c] else authority) else authority;
        path = rest[slash + 1 ..];
    } else {
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
        host = url[0..colon];
        if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
        path = url[colon + 1 ..];
        ssh = true;
    }
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    const last = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const repo = path[last + 1 ..];
    const before = path[0..last];
    const owner = if (std.mem.lastIndexOfScalar(u8, before, '/')) |s| before[s + 1 ..] else before;
    if (host.len == 0 or owner.len == 0 or repo.len == 0) return null;
    return .{ .host = host, .owner = owner, .repo = repo, .ssh = ssh, .scheme = url_scheme };
}

const testing = std.testing;

fn expectUrl(url: []const u8, host: []const u8, owner: []const u8, repo: []const u8) !void {
    const r = parseRemoteUrl(url) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(host, r.host);
    try testing.expectEqualStrings(owner, r.owner);
    try testing.expectEqualStrings(repo, r.repo);
}

test parseRemoteUrl {
    try expectUrl("git@box.example.com:Arzaroth/smith.git", "box.example.com", "Arzaroth", "smith");
    try expectUrl("ssh://git@box.example.com/Arzaroth/smith.git", "box.example.com", "Arzaroth", "smith");
    try expectUrl("ssh://git@box.example.com:2222/Arzaroth/smith", "box.example.com", "Arzaroth", "smith");
    try expectUrl("https://git.example.com/Arzaroth/smith.git", "git.example.com", "Arzaroth", "smith");
    try expectUrl("http://127.0.0.1:3000/o/r/", "127.0.0.1:3000", "o", "r");
    try expectUrl("https://user:pw@git.example.com/sub/o/r.git", "git.example.com", "o", "r");
    try testing.expect(parseRemoteUrl("/local/path/repo.git") == null);
    try testing.expect(parseRemoteUrl("file:///srv/o/r.git") == null);
    try testing.expect(parseRemoteUrl("https://git.example.com/onlyone") == null);
}

test parseRemotes {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rs = try parseRemotes(arena.allocator(), "origin\tgit@h:o/r.git (fetch)\norigin\tgit@h:o/r.git (push)\n" ++
        "upstream\thttps://h/u/r (fetch)\nupstream\thttps://h/u/r (push)\n");
    try testing.expectEqual(@as(usize, 2), rs.len);
    try testing.expectEqualStrings("upstream", rs[1].name);
    try testing.expectEqualStrings("https://h/u/r", rs[1].url);
}
