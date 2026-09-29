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

/// Parses `OWNER/REPO`, `HOST/OWNER/REPO`, `HOST:OWNER/REPO` (git's scp-like
/// form without a user) or a clone URL. `HOST:PORT/OWNER/REPO` keeps the port.
pub fn parseSpec(s: []const u8) ?Spec {
    if (std.mem.indexOf(u8, s, "://") != null or std.mem.indexOfScalar(u8, s, '@') != null) {
        const u = git.parseRemoteUrl(s) orelse return null;
        return .{ .host = u.host, .owner = u.owner, .name = u.repo };
    }
    var rest = std.mem.trim(u8, s, "/");
    var host: ?[]const u8 = null;
    const first = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    if (std.mem.indexOfScalar(u8, first, ':')) |c| {
        const after = first[c + 1 ..];
        const is_port = after.len > 0 and for (after) |ch| {
            if (!std.ascii.isDigit(ch)) break false;
        } else true;
        if (!is_port) {
            if (c == 0) return null;
            host = first[0..c];
            rest = rest[c + 1 ..];
        }
    }

    var parts = std.mem.splitScalar(u8, rest, '/');
    var segs: [3][]const u8 = undefined;
    var n: usize = 0;
    while (parts.next()) |p| {
        if (n == 3 or p.len == 0) return null;
        segs[n] = p;
        n += 1;
    }
    if (n == 0) return null;
    var name = segs[n - 1];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    if (host != null) return if (n == 2) .{ .host = host, .owner = segs[0], .name = name } else null;
    return switch (n) {
        2 => .{ .owner = segs[0], .name = name },
        3 => .{ .host = segs[0], .owner = segs[1], .name = name },
        else => null,
    };
}

pub fn hostFor(ctx: *Ctx, cfg: config.Config, name: ?[]const u8) !config.Host {
    if (name) |n| return config.withEnv(ctx, cfg, cfg.find(n) orelse .{ .name = n });
    const h = cfg.defaultHost(ctx) orelse
        return ctx.fail("no Forgejo host configured; run `smith auth login --hostname <host>`", .{});
    return config.withEnv(ctx, cfg, h);
}

pub fn resolve(ctx: *Ctx, args: *const cli.Args) !Repo {
    const cfg = try config.load(ctx);
    if (args.get("repo")) |r| {
        const spec = parseSpec(r) orelse return ctx.fail("expected [HOST/]OWNER/REPO, got \"{s}\"", .{r});
        return .{ .host = try hostFor(ctx, cfg, spec.host), .owner = spec.owner, .name = spec.name };
    }
    const rs = try git.remotes(ctx);
    if (rs.len == 0) return ctx.fail("not in a git repository with remotes; pass -R OWNER/REPO", .{});

    var unknown: std.ArrayList(Repo) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    const chosen = try defaultRemote(ctx);
    const order = [_]?[]const u8{ chosen orelse "upstream", "upstream", "origin", null };
    for (order, 0..) |preferred, i| {
        if (i == 1 and chosen == null) continue;
        for (rs) |r| {
            if (preferred) |p| {
                if (!std.mem.eql(u8, r.name, p)) continue;
            } else if (std.mem.eql(u8, r.name, "upstream") or std.mem.eql(u8, r.name, "origin") or
                (chosen != null and std.mem.eql(u8, r.name, chosen.?))) continue;
            const u = r.parse() orelse continue;
            if (cfg.find(u.host)) |h| return .{ .host = try config.withEnv(ctx, cfg, h), .owner = u.owner, .name = u.repo, .remote = r.name };
            if (u.ssh) {
                try skipped.append(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "{s} (SSH host not configured)", .{u.host}));
                continue;
            }
            try unknown.append(ctx.alloc, .{
                .host = try config.withEnv(ctx, cfg, .{ .name = u.host, .scheme = u.scheme }),
                .owner = u.owner,
                .name = u.repo,
                .remote = r.name,
            });
        }
    }
    for (unknown.items) |candidate| {
        if (try isForgejo(ctx, candidate.host)) return candidate;
        try skipped.append(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "{s} (not a Forgejo instance)", .{candidate.host.name}));
    }
    const checked = try std.mem.join(ctx.alloc, ", ", skipped.items);
    return ctx.fail("no git remote points at a Forgejo host{s}{s}{s}; run `smith auth login --hostname <host>` or pass -R", .{
        if (checked.len > 0) " (checked: " else "",
        checked,
        if (checked.len > 0) ")" else "",
    });
}

/// Whether an unconfigured host answers Forgejo's (or Gitea's) version
/// endpoint. Asked anonymously, and quietly: a host that is not one is
/// simply skipped.
fn isForgejo(ctx: *Ctx, host: config.Host) !bool {
    var h = host;
    h.token = null;
    var client: api.Client = .{ .ctx = ctx, .host = h, .base = try h.apiBase(ctx.alloc) };
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const saved = ctx.err;
    ctx.err = &discard.writer;
    defer ctx.err = saved;
    const r = client.raw(.GET, "/version", .{}) catch return false;
    if (!r.ok()) return false;
    const Version = struct { version: []const u8 };
    _ = std.json.parseFromSliceLeaky(Version, ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch return false;
    return true;
}

/// The remote whose URL points at `owner/name` on `host`, if any.
pub fn remoteFor(ctx: *Ctx, host: config.Host, owner: []const u8, name: []const u8) !?[]const u8 {
    for (try git.remotes(ctx)) |r| {
        const u = r.parse() orelse continue;
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

    const scp = parseSpec("git.example.com:owner/repo.git").?;
    try testing.expectEqualStrings("git.example.com", scp.host.?);
    try testing.expectEqualStrings("owner", scp.owner);
    try testing.expectEqualStrings("repo", scp.name);
    const port = parseSpec("127.0.0.1:3000/owner/repo").?;
    try testing.expectEqualStrings("127.0.0.1:3000", port.host.?);
    try testing.expectEqualStrings("owner", port.owner);
    try testing.expect(parseSpec("host:owner") == null);
    try testing.expect(parseSpec("host:a/b/c") == null);
    try testing.expect(parseSpec(":owner/repo") == null);
}

/// The remote `repo set-default` chose, recorded as
/// `remote.<name>.smith-resolved = base` like gh's `gh-resolved`.
pub fn defaultRemote(ctx: *Ctx) !?[]const u8 {
    const out = try git.capture(ctx, &.{ "config", "--get-regexp", "^remote\\..+\\.smith-resolved$" }) orelse return null;
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[space + 1 ..], " "), "base")) continue;
        const key = line[0..space];
        return key["remote.".len .. key.len - ".smith-resolved".len];
    }
    return null;
}
