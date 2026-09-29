//! Browser login: OAuth 2 authorization code with PKCE, the code caught on a
//! loopback port (RFC 8252), and the access token renewed with its refresh
//! token when it is about to expire.
const std = @import("std");
const Io = std.Io;
const Ctx = @import("Ctx.zig");
const api = @import("api.zig");
const config = @import("config.zig");

const Tokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: ?i64 = null,
};

/// Renews the access token of a browser login within a minute of its expiry,
/// saving the new pair. Anything else is returned unchanged.
pub fn refreshIfDue(ctx: *Ctx, host: config.Host) !config.Host {
    const refresh = host.refresh_token orelse return host;
    const expires = host.expires_at orelse return host;
    const client_id = host.oauth_client_id orelse return host;
    if (ctx.now < expires -| 60) return host;

    const tokens = exchange(ctx, host, &.{
        .{ "grant_type", "refresh_token" },
        .{ "client_id", client_id },
        .{ "refresh_token", refresh },
    }) catch |e| switch (e) {
        error.GrantRejected => return ctx.fail("the login to {s} has expired; run `smith auth login --hostname {s}`", .{ host.name, host.name }),
        else => return e,
    };
    var h = host;
    apply(ctx, &h, tokens);
    var cfg = try config.load(ctx);
    try cfg.put(ctx.alloc, h);
    try config.save(ctx, cfg);
    return h;
}

fn apply(ctx: *const Ctx, h: *config.Host, t: Tokens) void {
    h.token = t.access_token;
    if (t.refresh_token) |r| h.refresh_token = r;
    h.expires_at = if (t.expires_in) |s| ctx.now +| s else null;
}

/// Opens the authorization page, waits for the browser to come back with a
/// code, and trades it for tokens. Returns `host` logged in.
pub fn login(ctx: *Ctx, host: config.Host, client_id: []const u8) !config.Host {
    const verifier = try randomString(ctx, 32);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge_buf: [43]u8 = undefined;
    const challenge = std.base64.url_safe_no_pad.Encoder.encode(&challenge_buf, &digest);
    const state = try randomString(ctx, 16);

    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = addr.listen(ctx.io, .{}) catch |e| return ctx.fail("cannot listen on 127.0.0.1 for the login redirect: {t}", .{e});
    defer server.deinit(ctx.io);
    const redirect_uri = try std.fmt.allocPrint(ctx.alloc, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const wait: i64 = if (ctx.getenv("SMITH_LOGIN_TIMEOUT")) |t| std.fmt.parseInt(i64, t, 10) catch 300 else 300;
    var timer = try ctx.io.concurrent(expire, .{ ctx.io, &server, wait });
    defer timer.cancel(ctx.io);

    const url = try std.fmt.allocPrint(ctx.alloc, "{s}/login/oauth/authorize?client_id={s}&redirect_uri={s}&response_type=code&code_challenge={s}&code_challenge_method=S256&state={s}", .{
        try host.webBase(ctx.alloc),
        try api.escape(ctx.alloc, client_id),
        try api.escape(ctx.alloc, redirect_uri),
        challenge,
        state,
    });
    try ctx.err.print("Opening {s} in your browser.\nIf it does not open, visit it yourself; smith waits for the sign-in to finish.\n", .{url});
    try ctx.err.flush();
    if (!try ctx.launchBrowser(url)) try ctx.err.writeAll("! could not start a browser; open the address above yourself\n");

    const code = try waitForCode(ctx, &server, state, host.name);
    const tokens = exchange(ctx, host, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", client_id },
        .{ "code", code },
        .{ "code_verifier", verifier },
        .{ "redirect_uri", redirect_uri },
    }) catch |e| switch (e) {
        error.GrantRejected => return ctx.fail("{s} refused the sign-in code; run the login again", .{host.name}),
        else => return e,
    };
    var h = host;
    apply(ctx, &h, tokens);
    h.oauth_client_id = client_id;
    return h;
}

fn waitForCode(ctx: *Ctx, server: *Io.net.Server, state: []const u8, host_name: []const u8) ![]const u8 {
    while (true) {
        const stream = server.accept(ctx.io) catch |e| switch (e) {
            error.SocketNotListening => return ctx.fail("no sign-in came back from the browser in time; try again, or use --password", .{}),
            else => return ctx.fail("waiting for the login redirect failed: {t}", .{e}),
        };
        defer stream.close(ctx.io);
        var read_buf: [16 * 1024]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = stream.reader(ctx.io, &read_buf);
        var writer = stream.writer(ctx.io, &write_buf);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var req = http.receiveHead() catch continue;

        const target = req.head.target;
        const q = std.mem.indexOfScalar(u8, target, '?') orelse {
            req.respond("", .{ .status = .not_found, .keep_alive = false }) catch {};
            continue;
        };
        const query = target[q + 1 ..];
        const got_state = try param(ctx, query, "state");
        const code = try param(ctx, query, "code");
        const err = try param(ctx, query, "error");
        if (code == null and err == null) {
            req.respond("", .{ .status = .not_found, .keep_alive = false }) catch {};
            continue;
        }
        if (got_state == null or !std.mem.eql(u8, got_state.?, state)) {
            req.respond(page("This sign-in did not come from smith's request; nothing was saved."), html(.bad_request)) catch {};
            return ctx.fail("the login redirect carried the wrong state; nothing was saved", .{});
        }
        if (err) |e| {
            req.respond(page("Sign-in was cancelled. You can close this tab."), html(.ok)) catch {};
            const why = try param(ctx, query, "error_description") orelse e;
            return ctx.fail("{s} refused the login: {s}", .{ host_name, why });
        }
        req.respond(page("Signed in. You can close this tab and return to the terminal."), html(.ok)) catch {};
        return code.?;
    }
}

fn html(status: std.http.Status) std.http.Server.Request.RespondOptions {
    return .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} };
}

fn page(comptime message: []const u8) []const u8 {
    return "<!doctype html><meta charset=utf-8><title>smith</title><body style=\"font-family:sans-serif;margin:3em\"><p>" ++ message ++ "</p>";
}

/// POSTs a form to the token endpoint, with no token of our own attached.
/// A refused grant (an expired or revoked refresh token, a used code) is
/// `error.GrantRejected`, left to the caller to explain; anything else is
/// reported here.
fn exchange(ctx: *Ctx, host: config.Host, fields: []const [2][]const u8) !Tokens {
    var form: std.ArrayList(u8) = .empty;
    for (fields, 0..) |f, i| {
        try form.print(ctx.alloc, "{s}{s}={s}", .{ if (i == 0) "" else "&", f[0], try api.escape(ctx.alloc, f[1]) });
    }
    var h = host;
    h.token = null;
    var c: api.Client = .{ .ctx = ctx, .host = h, .base = try h.apiBase(ctx.alloc) };
    const r = try c.raw(.POST, try std.fmt.allocPrint(ctx.alloc, "{s}/login/oauth/access_token", .{try host.webBase(ctx.alloc)}), .{
        .body = form.items,
        .content_type = "application/x-www-form-urlencoded",
    });
    if (!r.ok()) {
        const Err = struct { @"error": ?[]const u8 = null, error_description: ?[]const u8 = null };
        const e = std.json.parseFromSliceLeaky(Err, ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch Err{};
        if (e.@"error") |code| if (std.mem.eql(u8, code, "invalid_grant")) return error.GrantRejected;
        return ctx.fail("{s} did not issue a token: {s}", .{ host.name, e.error_description orelse e.@"error" orelse "unknown error" });
    }
    return std.json.parseFromSliceLeaky(Tokens, ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch
        ctx.fail("{s} answered the token request with something unexpected", .{host.name});
}

fn randomString(ctx: *Ctx, comptime n: usize) ![]const u8 {
    var bytes: [n]u8 = undefined;
    ctx.io.randomSecure(&bytes) catch ctx.io.random(&bytes);
    const out = try ctx.alloc.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(n));
    return std.base64.url_safe_no_pad.Encoder.encode(out, &bytes);
}

/// A decoded query parameter, or null when absent.
pub fn param(ctx: *Ctx, query: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const raw = pair[eq + 1 ..];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '+') {
                try out.append(ctx.alloc, ' ');
            } else if (raw[i] == '%' and i + 2 < raw.len) {
                const b = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch {
                    try out.append(ctx.alloc, raw[i]);
                    continue;
                };
                try out.append(ctx.alloc, b);
                i += 2;
            } else {
                try out.append(ctx.alloc, raw[i]);
            }
        }
        return try out.toOwnedSlice(ctx.alloc);
    }
    return null;
}

/// Stops the wait for the redirect after `seconds`, by shutting the listening
/// socket, which is how std lets another task end a blocking accept.
fn expire(io: Io, server: *Io.net.Server, seconds: i64) void {
    io.sleep(.fromSeconds(seconds), .awake) catch return;
    const s: Io.net.Stream = .{ .socket = server.socket };
    s.shutdown(io, .both) catch {};
}
