//! Which repository a command acts on: `-R [HOST/]OWNER/REPO`, else the git
//! remotes of the current clone (`upstream`, then `origin`, then the rest).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ctx = @import("Ctx.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const git = @import("git.zig");
const api = @import("api.zig");

pub const Repo = struct {
    host: config.Host,
    owner: []const u8,
    name: []const u8,
    /// The git remote that points at this repository, when resolved from one.
    remote: ?[]const u8 = null,

    pub fn fullName(r: Repo, alloc: Allocator) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ r.owner, r.name });
    }

    /// `/repos/OWNER/REPO` followed by `suffix`.
    pub fn path(r: Repo, alloc: Allocator, comptime suffix: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(alloc, "/repos/{s}/{s}" ++ suffix, .{ r.owner, r.name } ++ args);
    }

    pub fn webUrl(r: Repo, alloc: Allocator, comptime suffix: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}/{s}" ++ suffix, .{ try r.host.webBase(alloc), r.owner, r.name } ++ args);
    }

    pub fn client(r: Repo, ctx: *Ctx) !api.Client {
        return api.Client.init(ctx, r.host);
    }
};

pub const Spec = struct {
    host: ?[]const u8 = null,
    owner: []const u8,
    name: []const u8,
};

/// Parses `[HOST/]OWNER/REPO` or a clone URL.
pub fn parseSpec(s: []const u8) ?Spec {
    if (git.parseRemoteUrl(s)) |u| if (std.mem.indexOf(u8, s, "://") != null or std.mem.indexOfScalar(u8, s, '@') != null)
        return .{ .host = u.host, .owner = u.owner, .name = u.repo };
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, s, "/"), '/');
    var segs: [3][]const u8 = undefined;
    var n: usize = 0;
    while (parts.next()) |p| {
        if (n == 3 or p.len == 0) return null;
        segs[n] = p;
        n += 1;
    }
    var name = segs[n - 1];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    return switch (n) {
        2 => .{ .owner = segs[0], .name = name },
        3 => .{ .host = segs[0], .owner = segs[1], .name = name },
        else => null,
    };
}

pub fn hostFor(ctx: *Ctx, cfg: config.Config, name: ?[]const u8) !config.Host {
    if (name) |n| return config.withEnv(ctx, cfg.find(n) orelse .{ .name = n });
    const h = cfg.defaultHost(ctx) orelse
        return ctx.fail("no Forgejo host configured; run `smith auth login --hostname <host>`", .{});
    return config.withEnv(ctx, h);
}

pub fn resolve(ctx: *Ctx, args: *const cli.Args) !Repo {
    const cfg = try config.load(ctx);
    if (args.get("repo")) |r| {
        const spec = parseSpec(r) orelse return ctx.fail("expected [HOST/]OWNER/REPO, got \"{s}\"", .{r});
        return .{ .host = try hostFor(ctx, cfg, spec.host), .owner = spec.owner, .name = spec.name };
    }
    const rs = try git.remotes(ctx);
    if (rs.len == 0) return ctx.fail("not in a git repository with remotes; pass -R OWNER/REPO", .{});

    var fallback: ?Repo = null;
    for ([_]?[]const u8{ "upstream", "origin", null }) |preferred| {
        for (rs) |r| {
            if (preferred) |p| {
                if (!std.mem.eql(u8, r.name, p)) continue;
            }
            const u = git.parseRemoteUrl(r.url) orelse continue;
            if (cfg.find(u.host)) |h| return .{ .host = config.withEnv(ctx, h), .owner = u.owner, .name = u.repo, .remote = r.name };
            if (fallback == null and !u.ssh)
                fallback = .{ .host = config.withEnv(ctx, .{ .name = u.host }), .owner = u.owner, .name = u.repo, .remote = r.name };
        }
    }
    return fallback orelse ctx.fail("no git remote points at a known Forgejo host; run `smith auth login` or pass -R", .{});
}

/// The remote whose URL points at `owner/name` on `host`, if any.
pub fn remoteFor(ctx: *Ctx, host: config.Host, owner: []const u8, name: []const u8) !?[]const u8 {
    for (try git.remotes(ctx)) |r| {
        const u = git.parseRemoteUrl(r.url) orelse continue;
        if (host.matches(u.host) and std.ascii.eqlIgnoreCase(u.owner, owner) and std.ascii.eqlIgnoreCase(u.repo, name))
            return r.name;
    }
    return null;
}

const testing = std.testing;

test parseSpec {
    const a = parseSpec("owner/repo").?;
    try testing.expect(a.host == null);
    try testing.expectEqualStrings("repo", a.name);
    const b = parseSpec("git.example.com/owner/repo.git").?;
    try testing.expectEqualStrings("git.example.com", b.host.?);
    const c = parseSpec("git@box.example.com:o/r.git").?;
    try testing.expectEqualStrings("box.example.com", c.host.?);
    const d = parseSpec("https://git.example.com/o/r").?;
    try testing.expectEqualStrings("o", d.owner);
    try testing.expect(parseSpec("justone") == null);
    try testing.expect(parseSpec("a/b/c/d") == null);
    try testing.expect(parseSpec("a//b") == null);
}
