const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const config = @import("../config.zig");
const fx = @import("fixtures.zig");

/// A secret-tool stand-in keeping each secret in a file named after its
/// attributes; a `refuse` file makes `store` fail.
const fake_tool =
    \\#!/bin/sh
    \\dir="$(dirname "$0")/keyring"; mkdir -p "$dir"
    \\cmd=$1; shift
    \\if [ "$cmd" = store ]; then shift 2; fi
    \\key=$(printf '%s=' "$@" | tr -c 'A-Za-z0-9=\n' '_')
    \\case $cmd in
    \\  store) [ -f "$dir/refuse" ] && exit 1; cat > "$dir/$key" ;;
    \\  lookup) cat "$dir/$key" 2>/dev/null || exit 1 ;;
    \\  clear) rm -f "$dir/$key" ;;
    \\esac
    \\
;

fn useFakeKeyring(h: *Harness) !void {
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret-tool", .data = fake_tool, .flags = .{ .permissions = .fromMode(0o755) } });
    try h.env.put("SMITH_KEYRING", try h.path("secret-tool"));
}

fn readConfig(h: *Harness) ![]const u8 {
    return h.tmp.dir.readFileAlloc(std.testing.io, "config/hosts.zon", h.arena.allocator(), .limited(64 * 1024));
}

fn login(h: *Harness, token: []const u8, extra: []const []const u8) !void {
    h.ctx.stdin_data = token;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(h.arena.allocator(), &.{ "auth", "login", "--hostname", try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{h.mock.port}), "--scheme", "http", "--with-token" });
    try argv.appendSlice(h.arena.allocator(), extra);
    try h.expectRun(0, argv.items);
}

const routes = [_]Harness.Mock.Route{
    .{ .path = "/api/forgejo/v1/version", .body = fx.version },
    .{ .path = "/api/v1/user", .body = fx.user },
    .{ .path = "/api/v1/repos/owner/repo/issues", .body = "[]" },
};

test "login puts the token in the keyring, not the file; commands read it back; logout clears it" {
    var h: Harness = undefined;
    try h.init(&routes, .{ .config = false });
    defer h.deinit();
    try useFakeKeyring(&h);
    try login(&h, "kept-secret", &.{});
    try h.expectErr("the token is in the system keyring");
    const file = try readConfig(&h);
    try std.testing.expect(std.mem.indexOf(u8, file, "kept-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, file, ".keyring = true") != null);

    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    var last: ?[]const u8 = null;
    for (h.mock.requests.items) |r| if (std.mem.startsWith(u8, r.target, "/api/v1/repos/owner/repo/issues")) {
        last = r.authorization;
    };
    try std.testing.expectEqualStrings("token kept-secret", last.?);
    try h.expectRun(0, &.{ "auth", "token" });
    try std.testing.expectEqualStrings("kept-secret\n", h.stdout());

    try h.expectRun(0, &.{ "auth", "logout" });
    var dir = try h.tmp.dir.openDir(std.testing.io, "keyring", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    try std.testing.expect(try it.next(std.testing.io) == null);
}

test "a keyring that refuses leaves the token in the file, with a warning" {
    var h: Harness = undefined;
    try h.init(&routes, .{ .config = false });
    defer h.deinit();
    try useFakeKeyring(&h);
    try h.tmp.dir.createDirPath(std.testing.io, "keyring");
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keyring/refuse", .data = "" });
    try login(&h, "fallback", &.{});
    try h.expectErr("the system keyring did not take the token");
    try h.expectErr("the token is in hosts.zon");
    try std.testing.expect(std.mem.indexOf(u8, try readConfig(&h), ".token = \"fallback\"") != null);
}

test "--insecure-storage skips the keyring" {
    var h: Harness = undefined;
    try h.init(&routes, .{ .config = false });
    defer h.deinit();
    try useFakeKeyring(&h);
    try login(&h, "plain", &.{"--insecure-storage"});
    try std.testing.expect(std.mem.indexOf(u8, try readConfig(&h), ".token = \"plain\"") != null);
    try std.testing.expectError(error.FileNotFound, h.tmp.dir.access(std.testing.io, "keyring", .{}));
}

test "a renewed browser login goes back to the keyring" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .POST, .path = "/login/oauth/access_token", .body = "{\"access_token\":\"fresh\",\"expires_in\":3600,\"refresh_token\":\"rt-2\"}" },
        .{ .path = "/api/v1/repos/owner/repo/issues", .body = "[]" },
    }, .{});
    defer h.deinit();
    try useFakeKeyring(&h);
    const host = try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{h.mock.port});
    var cfg: config.Config = .{ .default_host = host, .hosts = &.{.{
        .name = host,
        .scheme = "http",
        .user = "me",
        .token = "stale",
        .refresh_token = "rt-1",
        .expires_at = Harness.now + 10,
        .oauth_client_id = "cid",
        .keyring = true,
    }} };
    try config.save(&h.ctx, cfg);
    try std.testing.expect(std.mem.indexOf(u8, try readConfig(&h), "stale") == null);

    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=cid&refresh_token=rt-1", h.mock.lastBody(.POST, "/login/oauth/access_token").?);
    try std.testing.expect(std.mem.indexOf(u8, try readConfig(&h), "fresh") == null);
    cfg = try config.load(&h.ctx);
    const back = try config.withSecrets(&h.ctx, cfg.hosts[0]);
    try std.testing.expectEqualStrings("fresh", back.token.?);
    try std.testing.expectEqualStrings("rt-2", back.refresh_token.?);
}

test "a token missing from the keyring is reported, not silently dropped" {
    var h: Harness = undefined;
    try h.init(&routes, .{ .config = false });
    defer h.deinit();
    try useFakeKeyring(&h);
    try login(&h, "gone-soon", &.{});
    try h.tmp.dir.deleteTree(std.testing.io, "keyring");
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    try h.expectErr("no token for 127.0.0.1");
    try h.expectErr("in the system keyring");
}

test "SMITH_KEYRING picks the backend; unset, the platform's own" {
    const keyring = @import("../keyring.zig");
    const builtin = @import("builtin");
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.env.put("SMITH_KEYRING", "file");
    try std.testing.expect(keyring.backend(&h.ctx) == .none);
    try h.env.put("SMITH_KEYRING", "kwallet");
    try std.testing.expect(keyring.backend(&h.ctx) == .none);
    try h.env.put("SMITH_KEYRING", "security");
    try std.testing.expect(keyring.backend(&h.ctx) == .security);
    try h.env.put("SMITH_KEYRING", "secret-tool");
    try std.testing.expectEqualStrings("secret-tool", keyring.backend(&h.ctx).secret_tool);
    _ = h.env.swapRemove("SMITH_KEYRING");
    const want: std.meta.Tag(keyring.Backend) = switch (builtin.os.tag) {
        .macos => .security,
        .linux, .freebsd, .openbsd, .netbsd => .secret_tool,
        else => .none,
    };
    try std.testing.expectEqual(want, std.meta.activeTag(keyring.backend(&h.ctx)));
}
