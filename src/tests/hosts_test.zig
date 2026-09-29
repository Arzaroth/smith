const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const Mock = Harness.Mock;
const fx = @import("fixtures.zig");

const issues = "/api/v1/repos/o/r/issues";

/// A second Forgejo, for tests that need two hosts.
fn second(m: *Mock, routes: []const Mock.Route) !void {
    try m.start(std.testing.io, routes);
}

fn writeConfig(h: *Harness, comptime fmt: []const u8, args: anytype) !void {
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/hosts.zon", .data = try std.fmt.allocPrint(h.arena.allocator(), fmt, args) });
}

test "SMITH_TOKEN reaches only the default host; SMITH_TOKEN_<HOST> targets one" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = issues, .body = "[]" }}, .{});
    defer h.deinit();
    var other: Mock = undefined;
    try second(&other, &.{.{ .path = issues, .body = "[]" }});
    defer other.stop();
    try writeConfig(&h,
        \\.{{ .default_host = "127.0.0.1:{d}", .hosts = .{{
        \\  .{{ .name = "127.0.0.1:{d}", .scheme = "http", .token = "stored-a" }},
        \\  .{{ .name = "127.0.0.1:{d}", .scheme = "http", .token = "stored-b" }},
        \\}} }}
    , .{ h.mock.port, h.mock.port, other.port });
    const b = try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}/o/r", .{other.port});
    try h.env.put("SMITH_TOKEN", "from-env");

    try h.expectRun(0, &.{ "issue", "list", "-R", "o/r" });
    try std.testing.expectEqualStrings("token from-env", h.mock.requests.items[0].authorization.?);
    try h.expectRun(0, &.{ "issue", "list", "-R", b });
    try std.testing.expectEqualStrings("token stored-b", other.requests.items[0].authorization.?);

    const variable = try std.fmt.allocPrint(h.arena.allocator(), "SMITH_TOKEN_127_0_0_1_{d}", .{other.port});
    try h.env.put(variable, "just-b");
    try h.expectRun(0, &.{ "issue", "list", "-R", b });
    try std.testing.expectEqualStrings("token just-b", other.requests.items[1].authorization.?);

    try h.env.put("SMITH_HOST", b[0 .. b.len - "/o/r".len]);
    _ = h.env.swapRemove(variable);
    try h.expectRun(0, &.{ "issue", "list", "-R", b });
    try std.testing.expectEqualStrings("token from-env", other.requests.items[2].authorization.?);
}

test "a 401 on a host SMITH_TOKEN was kept from says how to aim it" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var other: Mock = undefined;
    try second(&other, &.{.{ .path = issues, .status = 401, .body = "{\"message\":\"token is required\"}" }});
    defer other.stop();
    try h.env.put("SMITH_TOKEN", "from-env");
    const b = try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{other.port});
    try writeConfig(&h, ".{{ .default_host = \"127.0.0.1:{d}\", .hosts = .{{ .{{ .name = \"{s}\", .scheme = \"http\" }} }} }}\n", .{ h.mock.port, b });
    try h.expectRun(1, &.{ "issue", "list", "-R", try std.fmt.allocPrint(h.arena.allocator(), "{s}/o/r", .{b}) });
    try h.expectErr("SMITH_TOKEN only applies to the host SMITH_HOST names");
    try h.expectErr(try std.fmt.allocPrint(h.arena.allocator(), "SMITH_TOKEN_127_0_0_1_{d}", .{other.port}));
    try std.testing.expect(other.requests.items[0].authorization == null);
}

test "an unconfigured https remote is used only if it answers as a Forgejo" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var forge: Mock = undefined;
    try second(&forge, &.{
        .{ .path = "/api/v1/version", .body = fx.version },
        .{ .path = issues, .body = fx.issue_list },
    });
    defer forge.stop();
    var github: Mock = undefined;
    try second(&github, &.{});
    defer github.stop();

    try h.git(&.{ "init", "-q", "work" });
    const gh_url = try std.fmt.allocPrint(h.arena.allocator(), "http://127.0.0.1:{d}/o/r.git", .{github.port});
    try h.git(&.{ "-C", "work", "remote", "add", "origin", gh_url });
    h.ctx.cwd = try h.path("work");
    try h.expectRun(1, &.{ "issue", "list" });
    try h.expectErr(try std.fmt.allocPrint(h.arena.allocator(), "checked: 127.0.0.1:{d} (not a Forgejo instance)", .{github.port}));
    try std.testing.expectEqual(@as(usize, 0), github.count(.GET, issues));

    const forge_url = try std.fmt.allocPrint(h.arena.allocator(), "http://127.0.0.1:{d}/o/r.git", .{forge.port});
    try h.git(&.{ "-C", "work", "remote", "add", "upstream", forge_url });
    try h.expectRun(0, &.{ "issue", "list" });
    try h.expectOut("#7\tCrash on start");
    try std.testing.expect(forge.requests.items[1].authorization == null);
}

test "two accounts on one host: login adds, switch flips, logout falls back" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/api/v1/user", .body = "{\"login\":\"work\"}", .times = 1 },
        .{ .path = "/api/v1/user", .body = "{\"login\":\"me\"}", .times = 2 },
        .{ .path = "/api/v1/user", .body = "{\"login\":\"someone\"}" },
    }, .{ .config = false });
    defer h.deinit();
    const host = try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{h.mock.port});

    h.ctx.stdin_data = "tok-work";
    try h.expectRun(0, &.{ "auth", "login", "--hostname", host, "--scheme", "http", "--with-token" });
    h.ctx.stdin_data = "tok-me";
    try h.expectRun(0, &.{ "auth", "login", "--hostname", host, "--scheme", "http", "--with-token" });
    try h.expectRun(0, &.{ "auth", "token" });
    try std.testing.expectEqualStrings("tok-me\n", h.stdout());
    try h.expectRun(0, &.{ "auth", "token", "--user", "work" });
    try std.testing.expectEqualStrings("tok-work\n", h.stdout());

    try h.expectRun(0, &.{ "auth", "switch" });
    try h.expectErr("Switched to work on");
    try h.expectRun(0, &.{ "auth", "token" });
    try std.testing.expectEqualStrings("tok-work\n", h.stdout());
    try h.expectRun(0, &.{ "auth", "switch", "--user", "me" });
    try h.expectRun(1, &.{ "auth", "switch", "--user", "nobody" });
    try h.expectErr("no account nobody on");

    try h.expectRun(0, &.{ "auth", "logout" });
    try h.expectErr("Logged out of");
    try h.expectErr(" as me");
    try h.expectErr("Switched to work on");
    try h.expectRun(0, &.{ "auth", "token" });
    try std.testing.expectEqualStrings("tok-work\n", h.stdout());
}

test "status groups accounts under their host and marks the default" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/user", .body = fx.user }}, .{});
    defer h.deinit();
    try writeConfig(&h,
        \\.{{ .default_host = "127.0.0.1:{d}", .hosts = .{{
        \\  .{{ .name = "127.0.0.1:{d}", .scheme = "http", .user = "work", .token = "w", .active = false }},
        \\  .{{ .name = "127.0.0.1:{d}", .scheme = "http", .user = "me", .token = "m" }},
        \\}} }}
    , .{ h.mock.port, h.mock.port, h.mock.port });
    try h.expectRun(0, &.{ "auth", "status" });
    try h.expectOut(" (default)\n");
    try h.expectOut("  - Active account: no\n");
    try h.expectOut("  - Active account: yes\n");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.stdout(), try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d} (default)", .{h.mock.port})));
}

test "switch --hostname changes the default host" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try writeConfig(&h,
        \\.{{ .default_host = "a.test", .hosts = .{{ .{{ .name = "a.test", .token = "a" }}, .{{ .name = "b.test", .token = "b" }} }} }}
    , .{});
    try h.expectRun(0, &.{ "auth", "switch", "--hostname", "b.test" });
    try h.expectErr("b.test is now the default host");
    try h.expectRun(0, &.{ "auth", "token" });
    try std.testing.expectEqualStrings("b\n", h.stdout());
    try h.expectRun(1, &.{ "auth", "switch" });
    try h.expectErr("already the default host and has a single account");
}
