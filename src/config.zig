//! Host configuration: one entry per Forgejo instance, stored as ZON at
//! `$SMITH_CONFIG_DIR/hosts.zon` (default `$XDG_CONFIG_HOME/smith`, then
//! `~/.config/smith`), mode 0600 since it holds tokens.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ctx = @import("Ctx.zig");
const keyring = @import("keyring.zig");

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
    /// The account smith uses on this host, when there are several.
    active: bool = true,
    /// The token and refresh token live in the system keyring, not here.
    keyring: bool = false,

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

    /// The active account on the host a hostname (web or SSH) belongs to.
    pub fn find(c: Config, hostname: []const u8) ?Host {
        var first: ?Host = null;
        for (c.hosts) |h| {
            if (!h.matches(hostname)) continue;
            if (h.active) return h;
            if (first == null) first = h;
        }
        return first;
    }

    /// Every account on a host, in file order.
    pub fn accounts(c: Config, alloc: Allocator, hostname: []const u8) ![]const Host {
        var list: std.ArrayList(Host) = .empty;
        for (c.hosts) |h| if (h.matches(hostname)) try list.append(alloc, h);
        return list.toOwnedSlice(alloc);
    }

    /// Name of the host used when no repository says otherwise: `SMITH_HOST`,
    /// then `default_host`, then the only configured host.
    pub fn defaultName(c: Config, ctx: *const Ctx) ?[]const u8 {
        if (ctx.getenv("SMITH_HOST")) |name| return name;
        if (c.default_host) |name| return name;
        if (c.hosts.len == 0) return null;
        for (c.hosts[1..]) |h| if (!std.ascii.eqlIgnoreCase(h.name, c.hosts[0].name)) return null;
        return c.hosts[0].name;
    }

    pub fn defaultHost(c: Config, ctx: *const Ctx) ?Host {
        const name = c.defaultName(ctx) orelse return null;
        return c.find(name) orelse .{ .name = name };
    }

    /// Adds or replaces the account `host.user` on `host.name`. An active
    /// account makes the host's other accounts inactive.
    pub fn put(c: *Config, alloc: Allocator, host: Host) !void {
        var list: std.ArrayList(Host) = .empty;
        var replaced = false;
        for (c.hosts) |h| {
            if (sameAccount(h, host)) {
                try list.append(alloc, host);
                replaced = true;
                continue;
            }
            var other = h;
            if (host.active and std.ascii.eqlIgnoreCase(h.name, host.name)) other.active = false;
            try list.append(alloc, other);
        }
        if (!replaced) try list.append(alloc, host);
        c.hosts = try list.toOwnedSlice(alloc);
    }

    /// Removes an account (the host's active one when `user` is null). Another
    /// account on the host becomes active; the default host is forgotten once
    /// no account is left on it. Returns the removed account.
    pub fn remove(c: *Config, alloc: Allocator, name: []const u8, user: ?[]const u8) !?Host {
        const target = if (user) |u| blk: {
            for (c.hosts) |h| if (std.ascii.eqlIgnoreCase(h.name, name) and h.user != null and std.ascii.eqlIgnoreCase(h.user.?, u)) break :blk h;
            return null;
        } else c.find(name) orelse return null;

        var list: std.ArrayList(Host) = .empty;
        var promoted = false;
        for (c.hosts) |h| {
            if (sameAccount(h, target)) continue;
            var keep = h;
            if (target.active and !promoted and std.ascii.eqlIgnoreCase(h.name, target.name)) {
                keep.active = true;
                promoted = true;
            }
            try list.append(alloc, keep);
        }
        c.hosts = try list.toOwnedSlice(alloc);
        const left = try c.accounts(alloc, target.name);
        if (left.len == 0) if (c.default_host) |d| if (std.ascii.eqlIgnoreCase(d, target.name)) {
            c.default_host = null;
        };
        return target;
    }

    /// Makes `user` the active account on its host.
    pub fn activate(c: *Config, alloc: Allocator, name: []const u8, user: []const u8) !bool {
        for (c.hosts) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name) and h.user != null and std.ascii.eqlIgnoreCase(h.user.?, user)) {
                var a = h;
                a.active = true;
                try c.put(alloc, a);
                return true;
            }
        }
        return false;
    }
};

fn sameAccount(a: Host, b: Host) bool {
    if (!std.ascii.eqlIgnoreCase(a.name, b.name)) return false;
    if (a.user == null or b.user == null) return a.user == null and b.user == null;
    return std.ascii.eqlIgnoreCase(a.user.?, b.user.?);
}

/// `SMITH_TOKEN_<HOST>`, the host name upper-cased with every character that
/// is not a letter or digit turned into `_` (`git.example.com` gives
/// `SMITH_TOKEN_GIT_EXAMPLE_COM`).
pub fn tokenVariable(alloc: Allocator, name: []const u8) ![]const u8 {
    const v = try std.fmt.allocPrint(alloc, "SMITH_TOKEN_{s}", .{name});
    for (v["SMITH_TOKEN_".len..]) |*ch| ch.* = if (std.ascii.isAlphanumeric(ch.*)) std.ascii.toUpper(ch.*) else '_';
    return v;
}

/// Applies a token from the environment: `SMITH_TOKEN_<HOST>` for this host,
/// else `SMITH_TOKEN` when this is the host `SMITH_HOST` names or, without
/// it, the default host. A token meant for one host never reaches another:
/// the name must match exactly, port included; the host must be configured
/// or be the default one (so a lookalike whose variable name collides gets
/// nothing); and it goes over plain http only to a host configured that way.
pub fn withEnv(ctx: *Ctx, cfg: Config, host: Host) !Host {
    const configured: ?Host = for (cfg.hosts) |c| {
        if (std.ascii.eqlIgnoreCase(c.name, host.name)) break c;
    } else null;
    const default = cfg.defaultName(ctx);
    const is_default = default != null and std.ascii.eqlIgnoreCase(default.?, host.name);
    const scheme_ok = std.mem.eql(u8, host.scheme, "https") or
        (configured != null and std.mem.eql(u8, configured.?.scheme, host.scheme));
    var token: ?[]const u8 = null;
    if (scheme_ok and (configured != null or is_default)) {
        token = ctx.getenv(try tokenVariable(ctx.alloc, host.name));
        if (token == null and is_default) token = ctx.getenv("SMITH_TOKEN");
    }
    var h = host;
    if (token) |t| {
        h.token = t;
        h.refresh_token = null;
        h.expires_at = null;
    }
    return withSecrets(ctx, h);
}

/// Fills in an account's token and refresh token from the keyring, when
/// that is where they live and nothing else supplied them.
pub fn withSecrets(ctx: *Ctx, host: Host) !Host {
    if (!host.keyring or host.token != null) return host;
    var h = host;
    h.token = try keyring.lookup(ctx, h.name, h.user, .token);
    if (h.token == null) try ctx.err.print("! no token for {s} in the system keyring; run `smith auth login --hostname {s}`\n", .{ h.name, h.name });
    if (h.refresh_token == null and h.oauth_client_id != null) h.refresh_token = try keyring.lookup(ctx, h.name, h.user, .refresh);
    return h;
}

/// Removes an account's secrets from the keyring.
pub fn forgetSecrets(ctx: *Ctx, host: Host) !void {
    if (!host.keyring) return;
    try keyring.remove(ctx, host.name, host.user, .token);
    try keyring.remove(ctx, host.name, host.user, .refresh);
}
/// Whether `SMITH_TOKEN` is set but was kept from `host` by `withEnv`.
pub fn tokenWithheld(ctx: *const Ctx, host: Host) bool {
    const t = ctx.getenv("SMITH_TOKEN") orelse return false;
    return host.token == null or !std.mem.eql(u8, host.token.?, t);
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

/// The config as written: secrets of keyring accounts go to the keyring and
/// out of the file. An account the keyring refuses keeps them in the file.
fn moveSecrets(ctx: *Ctx, config: Config) !Config {
    const hosts = try ctx.alloc.dupe(Host, config.hosts);
    for (hosts) |*h| {
        if (!h.keyring) continue;
        var ok = true;
        if (h.token) |t| ok = try keyring.store(ctx, h.name, h.user, .token, t);
        if (ok) if (h.refresh_token) |t| {
            ok = try keyring.store(ctx, h.name, h.user, .refresh, t);
        };
        if (ok) {
            h.token = null;
            h.refresh_token = null;
        } else {
            try keyring.remove(ctx, h.name, h.user, .token);
            h.keyring = false;
            try ctx.err.print("! the system keyring did not take the token for {s}; it is kept in hosts.zon\n", .{h.name});
        }
    }
    var out = config;
    out.hosts = hosts;
    return out;
}
pub fn save(ctx: *Ctx, config_in: Config) !void {
    const config = try moveSecrets(ctx, config_in);
    const d = try dir(ctx);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(ctx.io, d) catch |e| return ctx.fail("cannot create {s}: {t}", .{ d, e });

    var aw: Io.Writer.Allocating = .init(ctx.alloc);
    try std.zon.stringify.serialize(config, .{ .emit_default_optional_fields = false }, &aw.writer);
    try aw.writer.writeByte('\n');

    const path = try std.fs.path.join(ctx.alloc, &.{ d, "hosts.zon" });
    const tmp = try std.fmt.allocPrint(ctx.alloc, "{s}.{s}.tmp", .{ path, try ctx.nonce() });
    cwd.writeFile(ctx.io, .{ .sub_path = tmp, .data = aw.written(), .flags = .{ .permissions = .fromMode(0o600), .exclusive = true } }) catch |e|
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

test "put replaces an account, remove drops it and clears the default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Config = .{ .default_host = "a" };
    try c.put(a, .{ .name = "a", .token = "1" });
    try c.put(a, .{ .name = "b" });
    try c.put(a, .{ .name = "a", .token = "2" });
    try testing.expectEqual(@as(usize, 2), c.hosts.len);
    try testing.expectEqualStrings("2", c.find("a").?.token.?);
    try testing.expect(try c.remove(a, "a", null) != null);
    try testing.expect(c.default_host == null);
    try testing.expect(try c.remove(a, "a", null) == null);
}

test "several accounts on a host: one active, switching and removing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Config = .{ .default_host = "h" };
    try c.put(a, .{ .name = "h", .user = "work", .token = "w" });
    try c.put(a, .{ .name = "h", .user = "me", .token = "m" });
    try testing.expectEqual(@as(usize, 2), (try c.accounts(a, "h")).len);
    try testing.expectEqualStrings("me", c.find("h").?.user.?);

    try testing.expect(try c.activate(a, "h", "WORK"));
    try testing.expectEqualStrings("w", c.find("h").?.token.?);
    try testing.expect(!try c.activate(a, "h", "nobody"));

    const gone = (try c.remove(a, "h", null)).?;
    try testing.expectEqualStrings("work", gone.user.?);
    try testing.expectEqualStrings("me", c.find("h").?.user.?);
    try testing.expect(c.find("h").?.active);
    try testing.expectEqualStrings("h", c.default_host.?);
}

test tokenVariable {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("SMITH_TOKEN_GIT_EXAMPLE_COM", try tokenVariable(arena.allocator(), "git.example.com"));
    try testing.expectEqualStrings("SMITH_TOKEN_127_0_0_1_3000", try tokenVariable(arena.allocator(), "127.0.0.1:3000"));
}
