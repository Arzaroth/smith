const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const Mock = Harness.Mock;
const fx = @import("fixtures.zig");

const minted = "{\"id\":1,\"name\":\"smith\",\"sha1\":\"minted\"}";
const ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOp7Yp2Kq0a0y0Hq7mQw2nq3m5mD1vXfV0r8f1sX2c3d me@laptop\n";
const rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 me@server\n";

fn host(h: *Harness) ![]const u8 {
    return std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{h.mock.port});
}

fn interactive(h: *Harness, input: []const u8) void {
    h.ctx.stdin_tty = true;
    h.ctx.stdout_tty = true;
    h.ctx.stdin_data = input;
}

/// Every value of a key in the temporary HOME's global git config.
fn gitConfig(h: *Harness, key: []const u8) ![]const u8 {
    const r = try std.process.run(h.arena.allocator(), std.testing.io, .{
        .argv = &.{ "git", "config", "--global", "--get-all", key },
        .environ_map = &h.env,
    });
    return r.stdout;
}

fn helperKey(h: *Harness) ![]const u8 {
    return std.fmt.allocPrint(h.arena.allocator(), "credential.http://127.0.0.1:{d}.helper", .{h.mock.port});
}

fn writeKey(h: *Harness, name: []const u8, text: []const u8) !void {
    try h.tmp.dir.createDirPath(std.testing.io, ".ssh");
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(h.arena.allocator(), &.{ ".ssh", name }), .data = text });
}

fn passwordLogin(h: *Harness, input: []const u8, extra: []const []const u8) !u8 {
    interactive(h, input);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(h.arena.allocator(), &.{ "auth", "login", "--hostname", try host(h), "--scheme", "http", "--password" });
    try argv.appendSlice(h.arena.allocator(), extra);
    return h.run(argv.items);
}

test "setup-git points git's helper for the host at smith, and running it again changes nothing" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();

    for (0..2) |_| {
        try h.expectRun(0, &.{ "auth", "setup-git" });
        try h.expectErr("✓ git uses smith's login for http://127.0.0.1:");
        const values = try gitConfig(&h, try helperKey(&h));
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, values, "\n"), '\n');
        try std.testing.expectEqualStrings("", lines.next().?);
        const helper = lines.next().?;
        try std.testing.expect(std.mem.startsWith(u8, helper, "!/") or std.mem.startsWith(u8, helper, "!'/"));
        try std.testing.expect(std.mem.endsWith(u8, helper, " auth git-credential"));
        try std.testing.expect(lines.next() == null);
    }

    try h.expectRun(1, &.{ "auth", "setup-git", "--hostname", "elsewhere.example.com" });
    try h.expectErr("not logged in to elsewhere.example.com");
}

test "git-credential gives the token only for the exact scheme, host and account it was asked about" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const name = try host(&h);
    const a = h.arena.allocator();

    h.ctx.stdin_data = try std.fmt.allocPrint(a, "protocol=http\nhost={s}\npath=me/repo.git\n\n", .{name});
    try h.expectRun(0, &.{ "auth", "git-credential", "get" });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "protocol=http\nhost={s}\nusername=me\npassword=t0ken\n", .{name}), h.stdout());

    h.ctx.stdin_data = try std.fmt.allocPrint(a, "protocol=http\nhost={s}\nusername=me\n", .{name});
    try h.expectRun(0, &.{ "auth", "git-credential", "get" });
    try h.expectOut("password=t0ken\n");

    const refused = [_][]const u8{
        try std.fmt.allocPrint(a, "protocol=https\nhost={s}\n\n", .{name}),
        "protocol=http\nhost=127.0.0.1\n\n",
        "protocol=http\nhost=evil.example.com\n\n",
        try std.fmt.allocPrint(a, "protocol=http\nhost={s}\nusername=someone-else\n\n", .{name}),
        try std.fmt.allocPrint(a, "host={s}\n\n", .{name}),
    };
    for (refused) |input| {
        h.ctx.stdin_data = input;
        try h.expectRun(0, &.{ "auth", "git-credential", "get" });
        try std.testing.expectEqualStrings("", h.stdout());
    }

    for ([_][]const u8{ "store", "erase" }) |op| {
        h.ctx.stdin_data = try std.fmt.allocPrint(a, "protocol=http\nhost={s}\nusername=me\npassword=t0ken\n\n", .{name});
        try h.expectRun(0, &.{ "auth", "git-credential", op });
        try std.testing.expectEqualStrings("", h.stdout());
    }
}

test "an HTTPS login offers to set up git, and says how when it cannot ask" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 201, .body = minted },
        .{ .path = "/api/v1/user", .body = fx.user },
    }, .{ .config = false });
    defer h.deinit();

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\nn\n", &.{ "-p", "https" }));
    try h.expectErr("Make git use this login over HTTPS? [Y/n]");
    try std.testing.expectEqualStrings("", try gitConfig(&h, try helperKey(&h)));
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, "/api/v1/users/me/tokens").?, "write:user") == null);

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\n\n", &.{ "-p", "https" }));
    try h.expectErr("- git uses this login over HTTPS\n");
    try std.testing.expect(std.mem.endsWith(u8, try gitConfig(&h, try helperKey(&h)), " auth git-credential\n"));

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\n", &.{ "-p", "https" }));
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "[Y/n]") == null);
    try h.expectErr("- git uses this login over HTTPS\n");

    h.ctx.stdin_tty = false;
    h.ctx.stdout_tty = false;
    try h.git(&.{ "config", "--global", "--unset-all", try helperKey(&h) });
    h.ctx.stdin_data = "t0ken\n";
    try h.expectRun(0, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--with-token", "-p", "https" });
    try h.expectErr("- run `smith auth setup-git` so git uses this login over HTTPS\n");
}

test "an SSH login adds the machine's key when the account lacks it" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 201, .body = minted },
        .{ .path = "/api/v1/user", .body = fx.user },
        .{ .path = "/api/v1/user/keys", .body = "[]" },
        .{ .method = .POST, .path = "/api/v1/user/keys", .status = 201, .body = "{\"id\":7,\"title\":\"x\"}" },
    }, .{ .config = false });
    defer h.deinit();
    try writeKey(&h, "id_ed25519.pub", ed25519);
    try writeKey(&h, "notes.txt", "not a key");

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\n\n", &.{}));
    try h.expectErr("Add your SSH key ");
    try h.expectErr("✓ Added SSH key ");
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, "/api/v1/users/me/tokens").?, "\"write:user\"") != null);
    const added = try std.json.parseFromSliceLeaky(struct { key: []const u8, title: []const u8 }, h.arena.allocator(), h.mock.lastBody(.POST, "/api/v1/user/keys").?, .{});
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, ed25519, "\n"), added.key);
    try std.testing.expect(added.title.len > 0);
    for (h.mock.requests.items) |r| if (std.mem.startsWith(u8, r.target, "/api/v1/user/keys")) try std.testing.expectEqualStrings("token minted", r.authorization.?);

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\nn\n", &.{}));
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.POST, "/api/v1/user/keys"));

    try writeKey(&h, "id_rsa.pub", rsa);
    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\n2\n", &.{}));
    try h.expectErr("  1. ");
    try h.expectErr("  2. ");
    try std.testing.expectEqual(@as(usize, 2), h.mock.count(.POST, "/api/v1/user/keys"));
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, "/api/v1/user/keys").?, "ssh-rsa") != null);
}

test "an SSH login asks nothing when a key is already on the account, or off a terminal" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 201, .body = minted },
        .{ .path = "/api/v1/user", .body = fx.user },
        .{ .path = "/api/v1/user/keys", .body = "[{\"id\":1,\"key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOp7Yp2Kq0a0y0Hq7mQw2nq3m5mD1vXfV0r8f1sX2c3d\",\"title\":\"laptop\"}]" },
    }, .{ .config = false });
    defer h.deinit();
    try writeKey(&h, "id_ed25519.pub", ed25519);
    try writeKey(&h, "id_rsa.pub", rsa);

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\n", &.{}));
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "SSH key") == null);
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.POST, "/api/v1/user/keys"));

    h.ctx.stdin_tty = false;
    h.ctx.stdout_tty = false;
    h.ctx.stdin_data = "t0ken\n";
    const before = h.mock.count(.GET, "/api/v1/user/keys");
    try h.expectRun(0, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--with-token" });
    try std.testing.expectEqual(before, h.mock.count(.GET, "/api/v1/user/keys"));
}

test "an SSH login reports a key the server refuses, with the way to add it by hand" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 201, .body = minted },
        .{ .path = "/api/v1/user", .body = fx.user },
        .{ .path = "/api/v1/user/keys", .body = "[]" },
        .{ .method = .POST, .path = "/api/v1/user/keys", .status = 403, .body = "{\"message\":\"token does not have at least one of required scope(s): [write:user]\"}" },
    }, .{ .config = false });
    defer h.deinit();
    try writeKey(&h, "id_ed25519.pub", ed25519);

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\ny\n", &.{}));
    try h.expectErr("did not take the SSH key (token does not have at least one of required scope(s): [write:user]); add it with `smith ssh-key add ");
}

test "an SSH login with no key generates one and adds it" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 201, .body = minted },
        .{ .path = "/api/v1/user", .body = fx.user },
        .{ .path = "/api/v1/user/keys", .body = "[]" },
        .{ .method = .POST, .path = "/api/v1/user/keys", .status = 201, .body = "{\"id\":7,\"title\":\"x\"}" },
    }, .{ .config = false });
    defer h.deinit();
    const probe = std.process.run(h.arena.allocator(), std.testing.io, .{ .argv = &.{ "ssh-keygen", "-?" }, .environ_map = &h.env }) catch return error.SkipZigTest;
    _ = probe;

    try std.testing.expectEqual(@as(u8, 0), try passwordLogin(&h, "me\nhunter2\n\n\n", &.{}));
    try h.expectErr("Generate an SSH key (");
    try h.expectErr("✓ Added SSH key ");
    const public = try h.tmp.dir.readFileAlloc(std.testing.io, ".ssh/id_ed25519.pub", h.arena.allocator(), .limited(4096));
    try std.testing.expect(std.mem.startsWith(u8, public, "ssh-ed25519 "));
    const sent = try std.json.parseFromSliceLeaky(struct { key: []const u8, title: []const u8 }, h.arena.allocator(), h.mock.lastBody(.POST, "/api/v1/user/keys").?, .{});
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, public, "\n"), sent.key);
    const stat = try h.tmp.dir.statFile(std.testing.io, ".ssh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), @as(std.posix.mode_t, @intCast(stat.permissions.toMode() & 0o777)));
}
