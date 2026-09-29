//! Host configuration: one entry per Forgejo instance, stored as ZON at
//! `$SMITH_CONFIG_DIR/hosts.zon` (default `$XDG_CONFIG_HOME/smith`, then
//! `~/.config/smith`), mode 0600 since it holds tokens.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ctx = @import("Ctx.zig");

pub const Protocol = enum { ssh, https };

pub const Host = struct {
    /// Hostname the web UI and API answer on, optionally with a port.
    name: []const u8,
    token: ?[]const u8 = null,
    user: ?[]const u8 = null,
    git_protocol: Protocol = .ssh,
    /// Hostname git uses over SSH, when it differs from `name`.
    ssh_host: ?[]const u8 = null,
    /// "https", or "http" for a LAN instance.
    scheme: []const u8 = "https",
    /// Largest page the API serves (`max_response_items`), read at login.
    page_size: ?u32 = null,
    /// OAuth client the token was issued to; set for browser logins, which
    /// also keep a refresh token and the access token's expiry (Unix seconds).
    oauth_client_id: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    expires_at: ?i64 = null,

    pub fn apiBase(h: Host, alloc: Allocator) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}://{s}/api/v1", .{ h.scheme, h.name });
    }

    pub fn webBase(h: Host, alloc: Allocator) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}://{s}", .{ h.scheme, h.name });
    }

    /// Whether a hostname seen in a git remote belongs to this host.
    pub fn matches(h: Host, hostname: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(h.name, hostname)) return true;
        if (h.ssh_host) |s| if (std.ascii.eqlIgnoreCase(s, hostname)) return true;
        const bare = if (std.mem.indexOfScalar(u8, h.name, ':')) |i| h.name[0..i] else h.name;
        return std.ascii.eqlIgnoreCase(bare, hostname);
    }
};

pub const Config = struct {
    default_host: ?[]const u8 = null,
    hosts: []const Host = &.{},

    pub fn find(c: Config, hostname: []const u8) ?Host {
        for (c.hosts) |h| if (h.matches(hostname)) return h;
        return null;
    }

    /// Host used when no repository says otherwise: `SMITH_HOST`, then
    /// `default_host`, then the only configured host.
    pub fn defaultHost(c: Config, ctx: *const Ctx) ?Host {
        if (ctx.getenv("SMITH_HOST")) |name| return c.find(name) orelse .{ .name = name };
        if (c.default_host) |name| if (c.find(name)) |h| return h;
        if (c.hosts.len == 1) return c.hosts[0];
        return null;
    }

    pub fn put(c: *Config, alloc: Allocator, host: Host) !void {
        var list: std.ArrayList(Host) = .empty;
        var replaced = false;
        for (c.hosts) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, host.name)) {
                try list.append(alloc, host);
                replaced = true;
            } else try list.append(alloc, h);
        }
        if (!replaced) try list.append(alloc, host);
        c.hosts = try list.toOwnedSlice(alloc);
    }

    pub fn remove(c: *Config, alloc: Allocator, name: []const u8) !bool {
        var list: std.ArrayList(Host) = .empty;
        var found = false;
        for (c.hosts) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) found = true else try list.append(alloc, h);
        }
        c.hosts = try list.toOwnedSlice(alloc);
        if (c.default_host) |d| if (std.ascii.eqlIgnoreCase(d, name)) {
            c.default_host = null;
        };
        return found;
    }
};

/// Applies `SMITH_TOKEN` over whatever the file says for a host.
pub fn withEnv(ctx: *const Ctx, host: Host) Host {
    var h = host;
    if (ctx.getenv("SMITH_TOKEN")) |t| {
        h.token = t;
        h.refresh_token = null;
        h.expires_at = null;
    }
    return h;
}

pub fn dir(ctx: *const Ctx) ![]const u8 {
    if (ctx.getenv("SMITH_CONFIG_DIR")) |d| return d;
    if (ctx.getenv("XDG_CONFIG_HOME")) |x| return std.fs.path.join(ctx.alloc, &.{ x, "smith" });
    const home = ctx.getenv("HOME") orelse return ctx.fail("cannot find the config directory: HOME is not set", .{});
    return std.fs.path.join(ctx.alloc, &.{ home, ".config", "smith" });
}

pub fn load(ctx: *Ctx) !Config {
    const path = try std.fs.path.join(ctx.alloc, &.{ try dir(ctx), "hosts.zon" });
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return ctx.fail("cannot read {s}: {t}", .{ path, e }),
    };
    const source = try ctx.alloc.dupeZ(u8, bytes);
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(Config, ctx.alloc, source, &diag, .{ .ignore_unknown_fields = true }) catch
        return ctx.fail("{s} is not valid: {f}", .{ path, diag });
}

pub fn save(ctx: *Ctx, config: Config) !void {
    const d = try dir(ctx);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(ctx.io, d) catch |e| return ctx.fail("cannot create {s}: {t}", .{ d, e });

    var aw: Io.Writer.Allocating = .init(ctx.alloc);
    try std.zon.stringify.serialize(config, .{ .emit_default_optional_fields = false }, &aw.writer);
    try aw.writer.writeByte('\n');

    const path = try std.fs.path.join(ctx.alloc, &.{ d, "hosts.zon" });
    const tmp = try std.fmt.allocPrint(ctx.alloc, "{s}.tmp", .{path});
    cwd.writeFile(ctx.io, .{ .sub_path = tmp, .data = aw.written(), .flags = .{ .permissions = .fromMode(0o600) } }) catch |e|
        return ctx.fail("cannot write {s}: {t}", .{ tmp, e });
    cwd.rename(tmp, cwd, path, ctx.io) catch |e| return ctx.fail("cannot write {s}: {t}", .{ path, e });
}

const testing = std.testing;

test "host matching covers the ssh host and a port-qualified name" {
    const h: Host = .{ .name = "git.example.com", .ssh_host = "box.example.com" };
    try testing.expect(h.matches("GIT.example.com"));
    try testing.expect(h.matches("box.example.com"));
    try testing.expect(!h.matches("example.com"));
    const local: Host = .{ .name = "127.0.0.1:3000", .scheme = "http" };
    try testing.expect(local.matches("127.0.0.1"));
}

test "put replaces by name, remove drops and clears the default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Config = .{ .default_host = "a" };
    try c.put(a, .{ .name = "a", .token = "1" });
    try c.put(a, .{ .name = "b" });
    try c.put(a, .{ .name = "a", .token = "2" });
    try testing.expectEqual(@as(usize, 2), c.hosts.len);
    try testing.expectEqualStrings("2", c.find("a").?.token.?);
    try testing.expect(try c.remove(a, "a"));
    try testing.expect(c.default_host == null);
    try testing.expect(!try c.remove(a, "a"));
}
