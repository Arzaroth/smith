const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const Mock = Harness.Mock;
const caps = @import("../caps.zig");
const config = @import("../config.zig");
const fx = @import("fixtures.zig");

const tea_id = caps.builtin_clients[0].id;
const oidc =
    \\{"authorization_endpoint":"x","token_endpoint":"x","grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["plain","S256"]}
;
const known_client = "{\"error\":\"unauthorized_client\",\"error_description\":\"client is not authorized\"}";
const unknown_client = "{\"error\":\"invalid_client\",\"error_description\":\"cannot load client\"}";

fn host(h: *Harness) ![]const u8 {
    return std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{h.mock.port});
}

fn readConfig(h: *Harness) !config.Config {
    const bytes = try h.tmp.dir.readFileAlloc(std.testing.io, "config/hosts.zon", h.arena.allocator(), .limited(64 * 1024));
    return std.zon.parse.fromSliceAlloc(config.Config, h.arena.allocator(), try h.arena.allocator().dupeZ(u8, bytes), null, .{});
}

fn interactive(h: *Harness, input: []const u8) void {
    h.ctx.stdin_tty = true;
    h.ctx.stdout_tty = true;
    h.ctx.stdin_data = input;
}

test "discovery reads the version, page size, OAuth support and the first known built-in client" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/api/v1/settings/api", .body = "{\"max_response_items\":20}" },
        .{ .path = "/.well-known/openid-configuration", .body = oidc },
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = unknown_client, .times = 1 },
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = known_client },
    }, .{});
    defer h.deinit();
    const found = try caps.discover(&h.ctx, .{ .name = try host(&h), .scheme = "http", .token = "secret" });
    try std.testing.expect(found.forgejo);
    try std.testing.expectEqualStrings("16.0.5+gitea-1.22.0", found.version.?);
    try std.testing.expectEqual(@as(?u32, 20), found.page_size);
    try std.testing.expect(found.oauth);
    try std.testing.expectEqualStrings("git-credential-oauth", found.builtin_client.?.name);
    for (h.mock.requests.items) |r| try std.testing.expect(r.authorization == null);
}

test "discovery on a Gitea without OAuth" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/version", .body = "{\"version\":\"1.22.0\"}" }}, .{});
    defer h.deinit();
    const found = try caps.discover(&h.ctx, .{ .name = try host(&h), .scheme = "http" });
    try std.testing.expect(!found.forgejo);
    try std.testing.expect(!found.oauth);
    try std.testing.expect(found.page_size == null);
}

test "password login asks for the 2FA code when needed and stores the token it creates" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 401, .body = "{\"message\":\"Only signed in user is allowed to call APIs.\"}", .times = 1 },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 201, .body = "{\"id\":1,\"name\":\"smith\",\"sha1\":\"minted\"}" },
        .{ .path = "/api/v1/user", .body = fx.user },
    }, .{ .config = false });
    defer h.deinit();
    interactive(&h, "me\nhunter2\n123456\n");

    try h.expectRun(0, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--password" });
    try h.expectErr("Two-factor code:");
    try h.expectErr("created an access token for smith");

    const posts = blk: {
        var list: std.ArrayList(Mock.Request) = .empty;
        for (h.mock.requests.items) |r| if (r.method == .POST) try list.append(h.arena.allocator(), r);
        break :blk list.items;
    };
    try std.testing.expectEqual(@as(usize, 2), posts.len);
    try std.testing.expectEqualStrings("Basic bWU6aHVudGVyMg==", posts[0].authorization.?);
    try std.testing.expect(posts[0].header("X-Forgejo-OTP") == null);
    try std.testing.expectEqualStrings("123456", posts[1].header("X-Forgejo-OTP").?);
    try std.testing.expect(std.mem.indexOf(u8, posts[1].body, "\"scopes\":[\"write:repository\",\"write:issue\",\"read:user\",\"read:organization\"]") != null);

    const cfg = try readConfig(&h);
    try std.testing.expectEqualStrings("minted", cfg.hosts[0].token.?);
    try std.testing.expectEqualStrings("me", cfg.hosts[0].user.?);
    for (h.mock.requests.items) |r| if (std.mem.eql(u8, r.target, "/api/v1/user")) try std.testing.expectEqualStrings("token minted", r.authorization.?);
}

test "password login reports a wrong password without asking for a code" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 401, .body = "{\"message\":\"user's password is invalid [uid: 1, name: me]\"}" },
    }, .{ .config = false });
    defer h.deinit();
    interactive(&h, "me\nwrong\n");
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--password" });
    try h.expectErr("wrong username or password");
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "Two-factor") == null);
}

/// A "browser" that follows the authorize redirect back to smith's loopback
/// port, as a user clicking through the consent page would.
fn curlBrowser(h: *Harness) !bool {
    const probe = std.process.run(h.arena.allocator(), std.testing.io, .{ .argv = &.{ "curl", "--version" }, .environ_map = &h.env }) catch return false;
    if (probe.term != .exited or probe.term.exited != 0) return false;
    try h.tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "browser",
        .data = "#!/bin/sh\nexec curl -sfL -o /dev/null \"$1\"\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    try h.env.put("SMITH_BROWSER", try h.path("browser"));
    return true;
}

test "web login goes through the browser with PKCE and keeps the refresh token" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/.well-known/openid-configuration", .body = oidc },
        .{ .method = .POST, .path = "/login/oauth/access_token", .query = null, .status = 400, .body = known_client, .times = 1 },
        .{ .path = "/login/oauth/authorize", .authorize_code = "the-code" },
        .{ .method = .POST, .path = "/login/oauth/access_token", .body = "{\"access_token\":\"at-1\",\"token_type\":\"bearer\",\"expires_in\":3600,\"refresh_token\":\"rt-1\"}" },
        .{ .path = "/api/v1/user", .body = fx.user },
    }, .{ .config = false });
    defer h.deinit();
    if (!try curlBrowser(&h)) return error.SkipZigTest;
    interactive(&h, "");

    try h.expectRun(0, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http" });
    try h.expectErr("signed in through the browser");

    var authorize: ?Mock.Request = null;
    for (h.mock.requests.items) |r| if (std.mem.startsWith(u8, r.target, "/login/oauth/authorize")) {
        authorize = r;
    };
    const target = authorize.?.target;
    for ([_][]const u8{ "client_id=" ++ tea_id, "code_challenge_method=S256", "response_type=code", "redirect_uri=http%3A%2F%2F127.0.0.1%3A" }) |want| {
        if (std.mem.indexOf(u8, target, want) == null) {
            std.debug.print("{s} lacks {s}\n", .{ target, want });
            return error.TestExpectedEqual;
        }
    }
    const exchange = h.mock.lastBody(.POST, "/login/oauth/access_token").?;
    try std.testing.expect(std.mem.indexOf(u8, exchange, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, exchange, "code=the-code") != null);
    try std.testing.expect(std.mem.indexOf(u8, exchange, "code_verifier=") != null);

    const cfg = try readConfig(&h);
    const saved = cfg.hosts[0];
    try std.testing.expectEqualStrings("at-1", saved.token.?);
    try std.testing.expectEqualStrings("rt-1", saved.refresh_token.?);
    try std.testing.expectEqualStrings(tea_id, saved.oauth_client_id.?);
    try std.testing.expectEqual(@as(?i64, Harness.now + 3600), saved.expires_at);
}

test "web login without a built-in client explains how to register one" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/.well-known/openid-configuration", .body = oidc },
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = unknown_client },
    }, .{ .config = false });
    defer h.deinit();
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--web" });
    try h.expectErr("has no built-in OAuth client");
    try h.expectErr("redirect URI http://127.0.0.1/");
    try h.expectErr("Pass it as --client-id.");
}

fn oauthConfig(h: *Harness, expires_at: i64) !void {
    const zon = try std.fmt.allocPrint(h.arena.allocator(),
        \\.{{ .hosts = .{{ .{{ .name = "127.0.0.1:{d}", .scheme = "http", .token = "old", .refresh_token = "rt-old", .expires_at = {d}, .oauth_client_id = "cid" }} }} }}
        \\
    , .{ h.mock.port, expires_at });
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/hosts.zon", .data = zon });
}

test "an expiring browser login is renewed before the call and saved" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .POST, .path = "/login/oauth/access_token", .body = "{\"access_token\":\"new\",\"expires_in\":3600,\"refresh_token\":\"rt-new\"}" },
        .{ .path = "/api/v1/repos/owner/repo/issues", .body = "[]" },
    }, .{});
    defer h.deinit();
    try oauthConfig(&h, Harness.now + 30);

    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    const form = h.mock.lastBody(.POST, "/login/oauth/access_token").?;
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=cid&refresh_token=rt-old", form);
    try std.testing.expectEqualStrings("token new", h.mock.requests.items[1].authorization.?);
    const saved = (try readConfig(&h)).hosts[0];
    try std.testing.expectEqualStrings("new", saved.token.?);
    try std.testing.expectEqualStrings("rt-new", saved.refresh_token.?);
}

test "a token with time left is used as is; a rejected refresh asks to log in again" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = "{\"error\":\"invalid_grant\"}" },
        .{ .path = "/api/v1/repos/owner/repo/issues", .body = "[]" },
    }, .{});
    defer h.deinit();
    try oauthConfig(&h, Harness.now + 600);
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.POST, "/login/oauth/access_token"));

    try oauthConfig(&h, Harness.now - 5);
    try h.expectRun(1, &.{ "issue", "list", "-R", "owner/repo" });
    try h.expectErr("has expired; run `smith auth login --hostname");
}

test "SMITH_TOKEN bypasses the refresh" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo/issues", .body = "[]" }}, .{});
    defer h.deinit();
    try oauthConfig(&h, Harness.now - 5);
    try h.env.put("SMITH_TOKEN", "from-env");
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("token from-env", h.mock.requests.items[0].authorization.?);
}

test "the browser login gives up when no sign-in comes back" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/.well-known/openid-configuration", .body = oidc },
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = known_client },
    }, .{ .config = false });
    defer h.deinit();
    try h.env.put("SMITH_LOGIN_TIMEOUT", "1");
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--web" });
    try h.expectErr("no sign-in came back from the browser in time");
}

/// A "browser" that skips the consent page and calls smith's loopback port
/// itself: first with no query, then with an unrelated one, then with the
/// query in `<tmp>/callback`, where STATE stands for the request's state.
fn callbackBrowser(h: *Harness, callback: []const u8) !bool {
    if (!try curlBrowser(h)) return false;
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "callback", .data = callback });
    try h.tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "browser",
        .data =
        \\#!/bin/sh
        \\port=$(printf '%s' "$1" | sed -n 's/.*redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A\([0-9]*\).*/\1/p')
        \\state=$(printf '%s' "$1" | sed -n 's/.*[?&]state=\([^&]*\).*/\1/p')
        \\query=$(sed "s/STATE/$state/" "$(dirname "$0")/callback")
        \\[ -n "$port" ] || exit 1
        \\curl -s -m 10 -o /dev/null "http://127.0.0.1:$port/"
        \\curl -s -m 10 -o /dev/null "http://127.0.0.1:$port/?unrelated=1"
        \\exec curl -s -m 10 -o /dev/null "http://127.0.0.1:$port/?$query"
        \\
        ,
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    return true;
}

fn initWeb(h: *Harness, comptime token_route: Mock.Route) !void {
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/.well-known/openid-configuration", .body = oidc },
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = known_client, .times = 1 },
        token_route,
        .{ .path = "/api/v1/user", .body = fx.user },
    }, .{ .config = false });
    try h.env.put("SMITH_LOGIN_TIMEOUT", "20");
}

fn webLogin(h: *Harness, callback: []const u8) !?u8 {
    if (!try callbackBrowser(h, callback)) return null;
    return h.run(&.{ "auth", "login", "--hostname", try host(h), "--scheme", "http", "--web" });
}

const good_token: Mock.Route = .{ .method = .POST, .path = "/login/oauth/access_token", .body = "{\"access_token\":\"at\"}" };

test "a cancelled browser sign-in gives the reason, decoded" {
    var h: Harness = undefined;
    try initWeb(&h, good_token);
    defer h.deinit();
    const code = try webLogin(&h, "error=access_denied&error_description=Not+today%2C+thanks%zz.&state=STATE") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 1), code);
    try h.expectErr("refused the login: Not today, thanks%zz.");
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.POST, "/login/oauth/access_token"));
}

test "a cancelled browser sign-in without a description gives the error code" {
    var h: Harness = undefined;
    try initWeb(&h, good_token);
    defer h.deinit();
    const code = try webLogin(&h, "error=access_denied&state=STATE") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 1), code);
    try h.expectErr("refused the login: access_denied");
}

test "a redirect with another state is refused" {
    var h: Harness = undefined;
    try initWeb(&h, good_token);
    defer h.deinit();
    const code = try webLogin(&h, "code=stolen&state=forged") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 1), code);
    try h.expectErr("carried the wrong state");
    try std.testing.expectError(error.FileNotFound, readConfig(&h));
}

test "a sign-in code the token endpoint refuses asks to log in again" {
    var h: Harness = undefined;
    try initWeb(&h, .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = "{\"error\":\"invalid_grant\"}" });
    defer h.deinit();
    const code = try webLogin(&h, "code=c&state=STATE") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 1), code);
    try h.expectErr("refused the sign-in code; run the login again");
}

test "a token endpoint answering with something other than tokens is reported" {
    var h: Harness = undefined;
    try initWeb(&h, .{ .method = .POST, .path = "/login/oauth/access_token", .body = "<html>maintenance</html>", .content_type = "text/html" });
    defer h.deinit();
    const code = try webLogin(&h, "code=c&state=STATE") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 1), code);
    try h.expectErr("answered the token request with something unexpected");
}

test "web login asks for a client ID when the instance has no built-in one, and remembers it" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/.well-known/openid-configuration", .body = oidc },
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 400, .body = unknown_client, .times = 2 * caps.builtin_clients.len },
        good_token,
        .{ .path = "/api/v1/user", .body = fx.user },
    }, .{ .config = false });
    defer h.deinit();
    interactive(&h, "\n");
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--web" });
    try h.expectErr("Client ID:");
    try h.expectErr("no client ID given");

    if (!try callbackBrowser(&h, "code=c&state=STATE")) return error.SkipZigTest;
    interactive(&h, "my-client\n");
    try h.expectRun(0, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--web" });
    try h.expectErr("has no built-in OAuth client");
    try h.expectErr("signed in through the browser");
    try std.testing.expectEqualStrings("my-client", (try readConfig(&h)).hosts[0].oauth_client_id.?);
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, "/login/oauth/access_token").?, "client_id=my-client") != null);
}

test "an instance without S256 PKCE gets no browser login" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .path = "/.well-known/openid-configuration", .body = "{\"grant_types_supported\":[\"authorization_code\"],\"code_challenge_methods_supported\":[\"plain\"]}" },
    }, .{ .config = false });
    defer h.deinit();
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--web" });
    try h.expectErr("does not offer OAuth sign-in with PKCE");
}

test "password login stops at an empty or refused two-factor code" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/forgejo/v1/version", .body = fx.version },
        .{ .method = .POST, .path = "/api/v1/users/me/tokens", .status = 401, .body = "{\"message\":\"Only signed in user is allowed to call APIs.\\ntrace: x\"}" },
    }, .{ .config = false });
    defer h.deinit();
    interactive(&h, "me\nhunter2\n\n");
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--password" });
    try h.expectErr("refused the login: Only signed in user is allowed to call APIs.\n");
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.POST, "/api/v1/users/me/tokens"));

    interactive(&h, "me\nhunter2\n000000\n");
    try h.expectRun(1, &.{ "auth", "login", "--hostname", try host(&h), "--scheme", "http", "--password" });
    try h.expectErr("refused the two-factor code: Only signed in user is allowed to call APIs.\n");
    try std.testing.expectEqual(@as(usize, 3), h.mock.count(.POST, "/api/v1/users/me/tokens"));
    const retry = h.mock.requests.items[h.mock.requests.items.len - 1];
    try std.testing.expectEqualStrings("000000", retry.header("X-Forgejo-OTP").?);
    try std.testing.expectEqualStrings("000000", retry.header("X-Gitea-OTP").?);
}

test "a refresh the token endpoint fails for another reason is reported as such" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .POST, .path = "/login/oauth/access_token", .status = 500, .body = "{\"error\":\"server_error\",\"error_description\":\"database is down\"}" },
    }, .{});
    defer h.deinit();
    try oauthConfig(&h, Harness.now - 5);
    try h.expectRun(1, &.{ "issue", "list", "-R", "owner/repo" });
    try h.expectErr("did not issue a token: database is down");
}
