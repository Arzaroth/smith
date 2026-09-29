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
