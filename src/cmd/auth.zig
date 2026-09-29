const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const config = @import("../config.zig");
const api = @import("../api.zig");
const caps = @import("../caps.zig");
const git = @import("../git.zig");
const oauth = @import("../oauth.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");

const hostname_flag: cli.Flag = .{ .long = "hostname", .value = "string", .help = "The Forgejo host, e.g. git.example.com" };

/// Scopes of the token the password login creates.
const token_scopes = [_][]const u8{ "write:repository", "write:issue", "read:user", "read:organization" };

pub const command: cli.Command = .{
    .name = "auth",
    .summary = "Authenticate smith with a Forgejo host.",
    .subs = &.{
        .{
            .name = "login",
            .summary = "Log in to a Forgejo host: in the browser, with your password, or with a token.",
            .flags = &.{
                hostname_flag,
                .{ .long = "web", .short = 'w', .help = "Log in in the browser (the default when one can be opened)" },
                .{ .long = "password", .help = "Log in with your username, password and 2FA code" },
                .{ .long = "user", .short = 'u', .value = "login", .help = "Username for --password" },
                .{ .long = "with-token", .help = "Read an access token from standard input" },
                .{ .long = "client-id", .value = "string", .help = "OAuth client for --web, when the instance has no built-in one" },
                .{ .long = "git-protocol", .short = 'p', .value = "ssh|https", .help = "Protocol for git operations (default ssh)" },
                .{ .long = "ssh-host", .value = "string", .help = "Hostname git uses over SSH, when it is not the web one" },
                .{ .long = "scheme", .value = "https|http", .help = "Scheme of the web address (default https)" },
            },
            .run = login,
        },
        .{
            .name = "status",
            .summary = "Show the hosts smith is logged in to.",
            .flags = &.{ hostname_flag, .{ .long = "show-token", .short = 't', .help = "Show the full token" } },
            .run = status,
        },
        .{
            .name = "logout",
            .summary = "Forget the token of a Forgejo host.",
            .flags = &.{hostname_flag},
            .run = logout,
        },
        .{
            .name = "token",
            .summary = "Print the token smith uses for a host.",
            .flags = &.{hostname_flag},
            .run = token,
        },
    },
};

const Route = enum { web, password, token };

fn login(ctx: *Ctx, args: *const cli.Args) !u8 {
    var cfg = try config.load(ctx);
    const name = args.get("hostname") orelse ctx.getenv("SMITH_HOST") orelse
        if (ctx.interactive()) try ctx.prompt("Forgejo hostname:") else return ctx.fail("--hostname is required when not running interactively", .{});
    if (name.len == 0) return ctx.fail("a hostname is required", .{});

    const known = cfg.find(name);
    var host: config.Host = known orelse .{ .name = name };
    host.name = name;
    host.token = null;
    host.refresh_token = null;
    host.expires_at = null;
    if (args.get("scheme")) |s| {
        if (!std.mem.eql(u8, s, "https") and !std.mem.eql(u8, s, "http")) return ctx.fail("--scheme must be https or http", .{});
        host.scheme = s;
    }
    if (args.get("git-protocol")) |p| host.git_protocol = std.meta.stringToEnum(config.Protocol, p) orelse
        return ctx.fail("--git-protocol must be ssh or https", .{});
    if (args.get("ssh-host")) |s| host.ssh_host = s;

    if (!args.has("with-token") and !args.has("password") and !args.has("web") and !ctx.interactive())
        return ctx.fail("--with-token is required when not running interactively (or pass --web)", .{});
    const found = try caps.discover(ctx, host);
    host.page_size = found.page_size;

    const route: Route = if (args.has("with-token"))
        .token
    else if (args.has("password"))
        .password
    else if (args.has("web"))
        .web
    else if (found.oauth and ctx.canOpenBrowser())
        .web
    else
        .password;

    switch (route) {
        .token => {
            host.token = std.mem.trim(u8, try ctx.readStdin(), " \r\n\t");
            if (host.token.?.len == 0) return ctx.fail("no token given", .{});
            host.oauth_client_id = null;
        },
        .password => {
            host = try loginWithPassword(ctx, host, args);
            host.oauth_client_id = null;
        },
        .web => {
            if (!found.oauth) return ctx.fail("{s} does not offer OAuth sign-in with PKCE; use --password or --with-token", .{host.name});
            const client_id = args.get("client-id") orelse (if (known) |k| k.oauth_client_id else null) orelse
                (if (found.builtin_client) |b| b.id else null) orelse
                try askForClient(ctx, host);
            host = try oauth.login(ctx, host, client_id);
        },
    }

    var client = try api.Client.init(ctx, host);
    const who = try client.raw(.GET, "/user", .{});
    switch (who.status) {
        200 => host.user = (try api.decode(types.User, ctx, try client.parseValue(who.body))).login,
        401 => return ctx.fail("{s} rejected the token", .{host.name}),
        403 => try ctx.err.print("! the token cannot read the user (no read:user scope); continuing without a username\n", .{}),
        else => return client.failStatus(.GET, "/user", who),
    }

    if (host.ssh_host == null) host.ssh_host = try discoverSshHost(ctx, &client, host);

    try cfg.put(ctx.alloc, host);
    if (cfg.default_host == null) cfg.default_host = host.name;
    try config.save(ctx, cfg);

    try ctx.err.print("✓ Logged in to {s} ({s} {s})", .{ host.name, if (found.forgejo) "Forgejo" else "Gitea", found.version orelse "?" });
    if (host.user) |u| try ctx.err.print(" as {s}", .{u});
    try ctx.err.writeByte('\n');
    switch (route) {
        .web => try ctx.err.writeAll("- signed in through the browser; the token renews itself\n"),
        .password => try ctx.err.writeAll("- created an access token for smith; revoke it under Settings > Applications\n"),
        .token => {},
    }
    try ctx.err.print("- git operations use {t}", .{host.git_protocol});
    if (host.ssh_host) |s| try ctx.err.print(" (SSH host {s})", .{s});
    try ctx.err.writeByte('\n');
    return 0;
}

/// Trades a username, password and, if the account has one, a TOTP code for
/// an access token scoped to what smith needs.
fn loginWithPassword(ctx: *Ctx, host: config.Host, args: *const cli.Args) !config.Host {
    const user = args.get("user") orelse try ctx.prompt("Username:");
    if (user.len == 0) return ctx.fail("a username is required", .{});
    const password = try ctx.promptSecret("Password:");
    const credentials = try std.fmt.allocPrint(ctx.alloc, "{s}:{s}", .{ user, password });
    const encoded = try ctx.alloc.alloc(u8, std.base64.standard.Encoder.calcSize(credentials.len));
    const basic = try std.fmt.allocPrint(ctx.alloc, "Basic {s}", .{std.base64.standard.Encoder.encode(encoded, credentials)});

    const machine = std.posix.uname();
    const token_name = try std.fmt.allocPrint(ctx.alloc, "smith on {s} ({d})", .{ std.mem.sliceTo(&machine.nodename, 0), ctx.now });
    const body = try std.json.Stringify.valueAlloc(ctx.alloc, .{ .name = token_name, .scopes = token_scopes }, .{});
    const path = try std.fmt.allocPrint(ctx.alloc, "/users/{s}/tokens", .{try api.escape(ctx.alloc, user)});

    var client: api.Client = .{ .ctx = ctx, .host = host, .base = try host.apiBase(ctx.alloc) };
    var otp: ?[]const u8 = null;
    while (true) {
        const headers: []const std.http.Header = if (otp) |code| &.{
            .{ .name = "X-Forgejo-OTP", .value = code },
            .{ .name = "X-Gitea-OTP", .value = code },
        } else &.{};
        const r = try client.raw(.POST, path, .{ .body = body, .authorization = basic, .extra_headers = headers });
        if (r.ok()) {
            const Created = struct { sha1: []const u8 };
            const created = std.json.parseFromSliceLeaky(Created, ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch
                return ctx.fail("{s} created a token but did not return it", .{host.name});
            var h = host;
            h.token = created.sha1;
            h.user = user;
            return h;
        }
        if (r.status != 401 and r.status != 403) return client.failStatus(.POST, path, r);
        const message = api.errorMessage(ctx.alloc, r.body) orelse "";
        if (std.mem.indexOf(u8, message, "password is invalid") != null or std.mem.indexOf(u8, message, "user does not exist") != null)
            return ctx.fail("wrong username or password", .{});
        if (otp != null) return ctx.fail("{s} refused the two-factor code: {s}", .{ host.name, firstLine(message) });
        otp = try ctx.prompt("Two-factor code:");
        if (otp.?.len == 0) return ctx.fail("{s} refused the login: {s}", .{ host.name, firstLine(message) });
    }
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

/// The OAuth client for an instance without a built-in one: the user
/// registers smith once and gives its client ID, which is then remembered.
fn askForClient(ctx: *Ctx, host: config.Host) ![]const u8 {
    const settings = try std.fmt.allocPrint(ctx.alloc, "{s}/user/settings/applications", .{try host.webBase(ctx.alloc)});
    const how =
        \\{s} has no built-in OAuth client smith can use. Register smith once at
        \\  {s}
        \\under "Manage OAuth2 applications": name smith, redirect URI http://127.0.0.1/,
        \\and leave "Confidential client" unticked. Then give its client ID.
        \\
    ;
    if (!ctx.interactive()) return ctx.fail(how ++ "Pass it as --client-id.", .{ host.name, settings });
    try ctx.err.print(how, .{ host.name, settings });
    const id = try ctx.prompt("Client ID:");
    if (id.len == 0) return ctx.fail("no client ID given", .{});
    return id;
}

/// The SSH hostname the instance advertises in its clone URLs, when it
/// differs from the web one.
fn discoverSshHost(ctx: *Ctx, client: *api.Client, host: config.Host) !?[]const u8 {
    const r = client.raw(.GET, "/repos/search?limit=1", .{}) catch return null;
    if (!r.ok()) return null;
    const Search = struct { data: ?[]const types.Repository = null };
    const v = client.parseValue(r.body) catch return null;
    const s = api.decode(Search, ctx, v) catch return null;
    const repos = s.data orelse return null;
    if (repos.len == 0) return null;
    const url = repos[0].ssh_url orelse return null;
    const u = git.parseRemoteUrl(url) orelse return null;
    if (host.matches(u.host)) return null;
    return u.host;
}

fn status(ctx: *Ctx, args: *const cli.Args) !u8 {
    const cfg = try config.load(ctx);
    const path = try std.fs.path.join(ctx.alloc, &.{ try config.dir(ctx), "hosts.zon" });
    if (cfg.hosts.len == 0 and ctx.getenv("SMITH_TOKEN") == null) {
        return ctx.fail("You are not logged in to any Forgejo host. Run `smith auth login` to authenticate.", .{});
    }
    var failed = false;
    const only = args.get("hostname");
    for (cfg.hosts) |stored| {
        if (only) |o| if (!stored.matches(o)) continue;
        const h = config.withEnv(ctx, stored);
        try term.paint(ctx, ctx.out, .bold, h.name);
        try ctx.out.writeByte('\n');
        const t = h.token orelse {
            try ctx.out.writeAll("  X no token stored\n");
            failed = true;
            continue;
        };
        var client = try api.Client.init(ctx, h);
        const r = client.raw(.GET, "/user", .{}) catch |e| {
            if (e != error.Reported) return e;
            failed = true;
            continue;
        };
        switch (r.status) {
            200 => {
                const u = try api.decode(types.User, ctx, try client.parseValue(r.body));
                try ctx.out.print("  ✓ Logged in to {s} as {s} ({s})\n", .{ h.name, u.login, path });
            },
            403 => try ctx.out.print("  ✓ Logged in to {s} ({s}); the token cannot read the user\n", .{ h.name, path }),
            401 => {
                try ctx.out.print("  X the token for {s} is invalid or expired\n", .{h.name});
                failed = true;
            },
            else => {
                try ctx.out.print("  X {s} answered HTTP {d}\n", .{ h.name, r.status });
                failed = true;
            },
        }
        if (h.refresh_token != null) {
            try ctx.out.writeAll("  - Login: browser; the access token renews itself\n");
        }
        try ctx.out.print("  - Git operations protocol: {t}\n", .{h.git_protocol});
        if (h.ssh_host) |s| try ctx.out.print("  - SSH host: {s}\n", .{s});
        if (args.has("show-token")) {
            try ctx.out.print("  - Token: {s}\n", .{t});
        } else {
            try ctx.out.print("  - Token: {s}{s}\n", .{ t[0..@min(4, t.len)], "*" ** 12 });
        }
    }
    return if (failed) 1 else 0;
}

fn logout(ctx: *Ctx, args: *const cli.Args) !u8 {
    var cfg = try config.load(ctx);
    const name = args.get("hostname") orelse
        (if (cfg.hosts.len == 1) cfg.hosts[0].name else return ctx.fail("--hostname is required when several hosts are configured", .{}));
    if (!try cfg.remove(ctx.alloc, name)) return ctx.fail("not logged in to {s}", .{name});
    try config.save(ctx, cfg);
    try ctx.err.print("✓ Logged out of {s}\n", .{name});
    return 0;
}

fn token(ctx: *Ctx, args: *const cli.Args) !u8 {
    const cfg = try config.load(ctx);
    const h = if (args.get("hostname")) |n|
        config.withEnv(ctx, cfg.find(n) orelse .{ .name = n })
    else
        config.withEnv(ctx, cfg.defaultHost(ctx) orelse return ctx.fail("not logged in to any Forgejo host", .{}));
    const t = h.token orelse return ctx.fail("no token for {s}", .{h.name});
    try ctx.out.print("{s}\n", .{t});
    return 0;
}
