const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const search =
    \\{"ok":true,"data":[{"id":1,"name":"r","full_name":"o/r","html_url":"x","ssh_url":"ssh://git@ssh.forge.test:2222/o/r.git"}]}
;

fn host(h: *Harness) ![]const u8 {
    return std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{h.mock.port});
}

fn readConfig(h: *Harness) ![]const u8 {
    return h.tmp.dir.readFileAlloc(std.testing.io, "config/hosts.zon", h.arena.allocator(), .limited(64 * 1024));
}

test "login stores the token, user and discovered ssh host with mode 0600" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/version", .body = fx.version },
        .{ .path = "/api/v1/user", .body = fx.user },
        .{ .path = "/api/v1/repos/search", .body = search },
    }, .{ .config = false });
    defer h.deinit();
    h.ctx.stdin_data = "s3cret\n";

    try h.expectRun(0, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--with-token" });
    try h.expectErr("Logged in to");
    try h.expectErr("as me");
    try h.expectErr("SSH host ssh.forge.test");

    const cfg = try readConfig(&h);
    try std.testing.expect(std.mem.indexOf(u8, cfg, ".token = \"s3cret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, ".ssh_host = \"ssh.forge.test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, ".default_host") != null);
    const stat = try h.tmp.dir.statFile(std.testing.io, "config/hosts.zon", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(stat.permissions))) & 0o777);

    for (h.mock.requests.items) |r| {
        if (std.mem.eql(u8, r.target, "/api/v1/user")) try std.testing.expectEqualStrings("token s3cret", r.authorization.?);
    }
}

test "login rejects a bad token and writes nothing" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/version", .body = fx.version },
        .{ .path = "/api/v1/user", .status = 401, .body = "{\"message\":\"invalid token\"}" },
    }, .{ .config = false });
    defer h.deinit();
    h.ctx.stdin_data = "nope";
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--with-token" });
    try h.expectErr("rejected the token");
    try std.testing.expectError(error.FileNotFound, readConfig(&h));
}

test "login without a token and without a terminal asks for --with-token" {
    var h: Harness = undefined;
    try h.init(&.{}, .{ .config = false });
    defer h.deinit();
    try h.expectRun(1, &.{ "auth", "login", "--hostname", "forge.test" });
    try h.expectErr("--with-token is required");
}

test "status reports a working and a rejected token" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/user", .body = fx.user, .times = 1 },
        .{ .path = "/api/v1/user", .status = 401, .body = "{\"message\":\"token is expired\"}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "auth", "status" });
    try h.expectOut("Logged in to");
    try h.expectOut("as me");
    try h.expectOut("t0ke************");

    try h.expectRun(1, &.{ "auth", "status", "--show-token" });
    try h.expectOut("Token: t0ken");
    try h.expectOut("is invalid or expired");
}

test "status with no hosts says how to log in" {
    var h: Harness = undefined;
    try h.init(&.{}, .{ .config = false });
    defer h.deinit();
    try h.expectRun(1, &.{ "auth", "status" });
    try h.expectErr("smith auth login");
}

test "token prints the stored token, SMITH_TOKEN overrides it, logout forgets it" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "auth", "token" });
    try std.testing.expectEqualStrings("t0ken\n", h.stdout());

    try h.env.put("SMITH_TOKEN", "from-env");
    try h.expectRun(0, &.{ "auth", "token" });
    try std.testing.expectEqualStrings("from-env\n", h.stdout());
    _ = h.env.swapRemove("SMITH_TOKEN");

    try h.expectRun(0, &.{ "auth", "logout" });
    try h.expectErr("Logged out of");
    try h.expectRun(1, &.{ "auth", "token" });
}

test "an API call sends the token and a 401 points at auth login" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo/issues", .status = 401, .body = "{\"message\":\"token expired\"}" }}, .{});
    defer h.deinit();
    try h.expectRun(4, &.{ "issue", "list", "-R", "owner/repo" });
    try h.expectErr("authentication failed");
    try h.expectErr("token expired");
    try h.expectErr("smith auth login --hostname");
}

fn writeHosts(h: *Harness, zon: []const u8) !void {
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/hosts.zon", .data = zon });
}

test "status: a token without read:user, an HTTP error, no token, an unreachable host, an expired login" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/user", .status = 403, .body = "{\"message\":\"forbidden\"}", .times = 1 },
        .{ .path = "/api/v1/user", .status = 500, .body = "{\"message\":\"boom\"}" },
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = "{\"error\":\"invalid_grant\"}" },
    }, .{});
    defer h.deinit();
    const name = try host(&h);
    const closed = blk: {
        var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(std.testing.io, .{});
        defer server.deinit(std.testing.io);
        break :blk try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{server.socket.address.getPort()});
    };
    try writeHosts(&h, try std.fmt.allocPrint(h.arena.allocator(),
        \\.{{ .default_host = "{s}", .hosts = .{{
        \\  .{{ .name = "{s}", .scheme = "http", .user = "me", .token = "t0ken" }},
        \\  .{{ .name = "{s}", .scheme = "http", .user = "old", .active = false, .token = "stale", .refresh_token = "rt", .expires_at = {d}, .oauth_client_id = "cid" }},
        \\  .{{ .name = "nothing.test", .user = "ghost" }},
        \\  .{{ .name = "{s}", .scheme = "http", .user = "far", .token = "far-away" }},
        \\}} }}
        \\
    , .{ name, name, name, Harness.now - 5, closed }));

    try h.expectRun(1, &.{ "auth", "status" });
    try h.expectOut("the token cannot read the user");
    try h.expectOut("Active account: yes");
    try h.expectOut("X no token stored for ghost");
    try h.expectErr("has expired");
    try h.expectErr(try std.fmt.allocPrint(h.arena.allocator(), "cannot reach {s}", .{closed}));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.stdout(), try std.fmt.allocPrint(h.arena.allocator(), "{s} (default)", .{name})));

    try h.expectRun(1, &.{ "auth", "status", "--hostname", name });
    try h.expectOut("answered HTTP 500");
    try std.testing.expect(std.mem.indexOf(u8, h.stdout(), "nothing.test") == null);
}

test "login refuses an unknown --git-protocol, and a token that cannot read the user is kept without a username" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/version", .body = fx.version },
        .{ .path = "/api/v1/user", .status = 403, .body = "{\"message\":\"token does not have the read:user scope\"}", .times = 1 },
        .{ .path = "/api/v1/user", .status = 502, .body = "{\"message\":\"bad gateway\"}" },
    }, .{ .config = false });
    defer h.deinit();
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--git-protocol", "ftp", "--with-token" });
    try h.expectErr("--git-protocol must be ssh or https");

    h.ctx.stdin_data = "scoped";
    try h.expectRun(0, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--with-token" });
    try h.expectErr("continuing without a username");
    const cfg = try readConfig(&h);
    try std.testing.expect(std.mem.indexOf(u8, cfg, ".token = \"scoped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, ".user") == null);

    h.ctx.stdin_data = "other";
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--with-token" });
    try h.expectErr("502");
    try std.testing.expect(std.mem.indexOf(u8, try readConfig(&h), "other") == null);
}

test "with several hosts and no default, account commands ask for --hostname; --user must name an account" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try writeHosts(&h,
        \\.{ .hosts = .{
        \\  .{ .name = "one.test", .user = "me", .token = "t1" },
        \\  .{ .name = "one.test", .user = "work", .active = false, .token = "t2" },
        \\  .{ .name = "two.test", .user = "me", .token = "t3" },
        \\} }
        \\
    );
    try h.expectRun(1, &.{ "auth", "token" });
    try h.expectErr("pass --hostname; smith is logged in to several hosts");
    try h.expectRun(1, &.{ "auth", "token", "--hostname", "one.test", "--user", "nobody" });
    try h.expectErr("no account nobody on one.test");
    try h.expectRun(1, &.{ "auth", "logout", "--hostname", "one.test", "--user", "nobody" });
    try h.expectErr("no account nobody on one.test");
    try h.expectRun(0, &.{ "auth", "logout", "--hostname", "one.test", "--user", "work" });
    try h.expectErr("Logged out of one.test as work");
    const cfg = try readConfig(&h);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "work") == null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "t1") != null);
}
