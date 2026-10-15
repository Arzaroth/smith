const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const config = @import("../config.zig");
const api = @import("../api.zig");
const caps = @import("../caps.zig");
const git = @import("../git.zig");
const oauth = @import("../oauth.zig");
const keyring = @import("../keyring.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");
const platform = @import("../platform.zig");

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
                .{ .long = "insecure-storage", .help = "Keep the token in hosts.zon instead of the system keyring" },
                .{ .long = "skip-ssh-key", .help = "Do not offer to add or generate an SSH key" },
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
            .name = "switch",
            .summary = "Change the default host, or the active account on a host.",
            .flags = &.{ hostname_flag, user_flag },
            .run = switchAccount,
        },
        .{
            .name = "logout",
            .summary = "Forget an account (the active one on the default host unless told otherwise).",
            .flags = &.{ hostname_flag, user_flag },
            .run = logout,
        },
        .{
            .name = "token",
            .summary = "Print the token smith uses for a host.",
            .flags = &.{ hostname_flag, user_flag },
            .run = token,
        },
        .{
            .name = "setup-git",
            .summary = "Make git use smith's login for HTTPS clones, fetches and pushes.",
            .flags = &.{hostname_flag},
            .run = setupGit,
        },
        .{
            .name = "git-credential",
            .summary = "The git credential helper `auth setup-git` installs.",
            .usage = "<get|store|erase>",
            .min_args = 1,
            .max_args = 1,
            .run = gitCredential,
        },
    },
};

const user_flag: cli.Flag = .{ .long = "user", .short = 'u', .value = "login", .help = "The account, when the host has several" };

const Route = enum { web, password, token };

fn login(ctx: *Ctx, args: *const cli.Args) !u8 {
    var cfg = try config.load(ctx);
    const name = args.get("hostname") orelse ctx.getenv("SMITH_HOST") orelse
        if (ctx.interactive()) try ctx.prompt("Forgejo hostname:") else return ctx.fail("--hostname is required when not running interactively", .{});
    if (name.len == 0) return ctx.fail("a hostname is required", .{});

    const known = cfg.find(name);
    var host: config.Host = known orelse .{ .name = name };
    host.name = name;
    host.user = null;
    host.active = true;
    host.token = null;
    host.refresh_token = null;
    host.expires_at = null;
    if (args.get("scheme")) |s| {
        if (!std.mem.eql(u8, s, "https") and !std.mem.eql(u8, s, "http")) return ctx.fail("--scheme must be https or http", .{});
        host.scheme = s;
    }
    if (args.get("git-protocol")) |p| {
        host.git_protocol = std.meta.stringToEnum(config.Protocol, p) orelse return ctx.fail("--git-protocol must be ssh or https", .{});
    } else if (known == null) {
        if ((try @import("../settings.zig").load(ctx)).git_protocol) |p| host.git_protocol = p;
    }
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

    var password: ?Password = null;
    switch (route) {
        .token => {
            host.token = std.mem.trim(u8, try ctx.readStdin(), " \r\n\t");
            if (host.token.?.len == 0) return ctx.fail("no token given", .{});
            host.oauth_client_id = null;
        },
        .password => {
            host = try loginWithPassword(ctx, host, args, &password);
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

    host.keyring = !args.has("insecure-storage") and keyring.backend(ctx) != .none;
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
    const kept = (try config.load(ctx)).find(host.name);
    if (kept != null and kept.?.keyring) {
        try ctx.err.writeAll("- the token is in the system keyring\n");
    } else {
        try ctx.err.writeAll("- the token is in hosts.zon, readable only by you (no system keyring, or --insecure-storage)\n");
    }
    switch (host.git_protocol) {
        .https => offerGitSetup(ctx, host) catch |e| switch (e) {
            error.Reported => try ctx.err.print("! git is not set up for this login; run `smith auth setup-git --hostname {s}`\n", .{host.name}),
            else => return e,
        },
        .ssh => if (!args.has("skip-ssh-key")) offerSshKey(ctx, &client, host, password) catch |e| switch (e) {
            error.Reported => {},
            else => return e,
        },
    }
    return 0;
}

/// The basic credentials and two-factor code of a password login, kept for
/// adding an SSH key: the token it creates cannot write to the account.
const Password = struct { basic: []const u8, otp: ?[]const u8 };

fn otpHeaders(ctx: *Ctx, otp: ?[]const u8) ![]const std.http.Header {
    const code = otp orelse return &.{};
    return ctx.alloc.dupe(std.http.Header, &.{
        .{ .name = "X-Forgejo-OTP", .value = code },
        .{ .name = "X-Gitea-OTP", .value = code },
    });
}

/// Trades a username, password and, if the account has one, a TOTP code for
/// an access token scoped to what smith needs.
fn loginWithPassword(ctx: *Ctx, host: config.Host, args: *const cli.Args, kept: *?Password) !config.Host {
    const user = args.get("user") orelse try ctx.prompt("Username:");
    if (user.len == 0) return ctx.fail("a username is required", .{});
    const password = try ctx.promptSecret("Password:");
    const credentials = try std.fmt.allocPrint(ctx.alloc, "{s}:{s}", .{ user, password });
    const encoded = try ctx.alloc.alloc(u8, std.base64.standard.Encoder.calcSize(credentials.len));
    const basic = try std.fmt.allocPrint(ctx.alloc, "Basic {s}", .{std.base64.standard.Encoder.encode(encoded, credentials)});

    const token_name = try std.fmt.allocPrint(ctx.alloc, "smith on {s} ({d})", .{ try platform.machineName(ctx.alloc, ctx.env), ctx.now });
    const body = try std.json.Stringify.valueAlloc(ctx.alloc, .{ .name = token_name, .scopes = token_scopes }, .{});

    var client: api.Client = .{ .ctx = ctx, .host = host, .base = try host.apiBase(ctx.alloc) };
    var name = user;
    var otp: ?[]const u8 = null;
    while (true) {
        const headers = try otpHeaders(ctx, otp);
        const by_email = std.mem.indexOfScalar(u8, name, '@') != null;
        const method: std.http.Method = if (by_email) .GET else .POST;
        const path = if (by_email) "/user" else try std.fmt.allocPrint(ctx.alloc, "/users/{s}/tokens", .{try api.escape(ctx.alloc, name)});
        const r = try client.raw(method, path, .{ .body = if (by_email) null else body, .authorization = basic, .extra_headers = headers });
        if (r.ok() and by_email) {
            const User = struct { login: []const u8 };
            const u = std.json.parseFromSliceLeaky(User, ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch
                return ctx.fail("{s} did not say which user {s} is", .{ host.name, user });
            if (std.mem.indexOfScalar(u8, u.login, '@') != null) return ctx.fail("{s} gave \"{s}\" as the username for {s}", .{ host.name, u.login, user });
            name = u.login;
            continue;
        }
        if (r.ok()) {
            const Created = struct { sha1: []const u8 };
            const created = std.json.parseFromSliceLeaky(Created, ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch
                return ctx.fail("{s} created a token but did not return it", .{host.name});
            var h = host;
            h.token = created.sha1;
            h.user = name;
            kept.* = .{ .basic = basic, .otp = otp };
            return h;
        }
        if (r.status != 401 and r.status != 403) return client.failStatus(method, path, r);
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
    if (cfg.hosts.len == 0) {
        return ctx.fail("You are not logged in to any Forgejo host. Run `smith auth login` to authenticate.", .{});
    }
    const default = cfg.defaultName(ctx);
    var failed = false;
    var seen: std.ArrayList([]const u8) = .empty;
    for (cfg.hosts) |first| {
        if (args.get("hostname")) |o| if (!first.matches(o)) continue;
        for (seen.items) |s| {
            if (std.ascii.eqlIgnoreCase(s, first.name)) break;
        } else {
            try seen.append(ctx.alloc, first.name);
            const accounts = try cfg.accounts(ctx.alloc, first.name);
            try term.paint(ctx, ctx.out, .bold, first.name);
            if (default != null and first.matches(default.?)) try ctx.out.writeAll(" (default)");
            try ctx.out.writeByte('\n');
            for (accounts) |stored| {
                if (!try account(ctx, cfg, stored, accounts.len > 1, path, args.has("show-token"))) failed = true;
            }
        }
    }
    return if (failed) 1 else 0;
}

/// One account's lines in `auth status`; false when its token does not work.
fn account(ctx: *Ctx, cfg: config.Config, stored: config.Host, several: bool, path: []const u8, show: bool) !bool {
    const h = if (stored.active) try config.withEnv(ctx, cfg, stored) else try config.withSecrets(ctx, stored);
    const t = h.token orelse {
        try ctx.out.print("  X no token stored{s}{s}\n", .{ if (h.user != null) " for " else "", h.user orelse "" });
        return false;
    };
    var client = api.Client.init(ctx, h) catch |e| switch (e) {
        error.Reported => return false,
        else => return e,
    };
    const r = client.raw(.GET, "/user", .{}) catch |e| {
        if (e != error.Reported) return e;
        return false;
    };
    var ok = true;
    switch (r.status) {
        200 => {
            const u = try api.decode(types.User, ctx, try client.parseValue(r.body));
            try ctx.out.print("  ✓ Logged in to {s} as {s} ({s})\n", .{ h.name, u.login, path });
        },
        403 => try ctx.out.print("  ✓ Logged in to {s} ({s}); the token cannot read the user\n", .{ h.name, path }),
        401 => {
            try ctx.out.print("  X the token for {s} on {s} is invalid or expired\n", .{ h.user orelse "the account", h.name });
            ok = false;
        },
        else => {
            try ctx.out.print("  X {s} answered HTTP {d}\n", .{ h.name, r.status });
            ok = false;
        },
    }
    if (several) try ctx.out.print("  - Active account: {s}\n", .{if (h.active) "yes" else "no"});
    if (h.refresh_token != null) try ctx.out.writeAll("  - Login: browser; the access token renews itself\n");
    try ctx.out.print("  - Git operations protocol: {t}\n", .{h.git_protocol});
    if (h.ssh_host) |s| try ctx.out.print("  - SSH host: {s}\n", .{s});
    if (show) {
        try ctx.out.print("  - Token: {s}\n", .{t});
    } else {
        try ctx.out.print("  - Token: {s}{s}\n", .{ t[0..@min(4, t.len)], "*" ** 12 });
    }
    return ok;
}

/// The host a command about accounts means: `--hostname`, else the default.
fn chosenHost(ctx: *Ctx, cfg: config.Config, args: *const cli.Args) ![]const u8 {
    if (args.get("hostname")) |n| return n;
    if (cfg.defaultName(ctx)) |n| return n;
    var names: std.ArrayList([]const u8) = .empty;
    for (cfg.hosts) |h| try names.append(ctx.alloc, h.name);
    if (names.items.len == 0) return ctx.fail("not logged in to any Forgejo host", .{});
    return ctx.fail("pass --hostname; smith is logged in to several hosts ({s})", .{try std.mem.join(ctx.alloc, ", ", names.items)});
}

fn logout(ctx: *Ctx, args: *const cli.Args) !u8 {
    var cfg = try config.load(ctx);
    const name = try chosenHost(ctx, cfg, args);
    const user = args.get("user");
    const removed = try cfg.remove(ctx.alloc, name, user) orelse
        return if (user) |u| ctx.fail("no account {s} on {s}", .{ u, name }) else ctx.fail("not logged in to {s}", .{name});
    try config.save(ctx, cfg);
    try config.forgetSecrets(ctx, removed);
    try ctx.err.print("✓ Logged out of {s}", .{removed.name});
    if (removed.user) |u| try ctx.err.print(" as {s}", .{u});
    try ctx.err.writeByte('\n');
    if (removed.refresh_token == null and removed.token != null)
        try ctx.err.writeAll("- the token stays valid on the server until revoked under Settings > Applications\n");
    if (removed.active) if (cfg.find(removed.name)) |next| {
        try ctx.err.print("✓ Switched to {s} on {s}\n", .{ next.user orelse "the remaining account", next.name });
    };
    return 0;
}

fn token(ctx: *Ctx, args: *const cli.Args) !u8 {
    const cfg = try config.load(ctx);
    const name = try chosenHost(ctx, cfg, args);
    const stored = if (args.get("user")) |u| blk: {
        for (try cfg.accounts(ctx.alloc, name)) |a| {
            if (a.user != null and std.ascii.eqlIgnoreCase(a.user.?, u)) break :blk a;
        }
        return ctx.fail("no account {s} on {s}", .{ u, name });
    } else cfg.find(name) orelse config.Host{ .name = name };
    const h = if (stored.active) try config.withEnv(ctx, cfg, stored) else try config.withSecrets(ctx, stored);
    const t = h.token orelse return ctx.fail("no token for {s}", .{h.name});
    try ctx.out.print("{s}\n", .{t});
    return 0;
}

/// `auth switch`: makes a host the default, makes another account on a host
/// the active one, or both. With no `--user` on a host with several
/// accounts, the next one becomes active.
fn switchAccount(ctx: *Ctx, args: *const cli.Args) !u8 {
    var cfg = try config.load(ctx);
    const name = try chosenHost(ctx, cfg, args);
    const accounts = try cfg.accounts(ctx.alloc, name);
    if (accounts.len == 0) return ctx.fail("not logged in to {s}; run `smith auth login --hostname {s}`", .{ name, name });
    const host_name = accounts[0].name;

    var made_default = false;
    if (args.get("hostname") != null) {
        if (cfg.default_host == null or !std.ascii.eqlIgnoreCase(cfg.default_host.?, host_name)) {
            cfg.default_host = host_name;
            made_default = true;
        }
    }

    var user = args.get("user");
    if (user == null and accounts.len > 1) {
        var i: usize = 0;
        for (accounts, 0..) |a, j| if (a.active) {
            i = j;
        };
        user = accounts[(i + 1) % accounts.len].user orelse
            return ctx.fail("the other account on {s} has no username; pass --user", .{host_name});
    }
    if (user) |u| {
        if (!try cfg.activate(ctx.alloc, host_name, u))
            return ctx.fail("no account {s} on {s}; log in with `smith auth login --hostname {s}`", .{ u, host_name, host_name });
    } else if (!made_default) {
        return ctx.fail("{s} is already the default host and has a single account", .{host_name});
    }

    try config.save(ctx, cfg);
    if (user) |u| try ctx.err.print("✓ Switched to {s} on {s}\n", .{ u, host_name });
    if (made_default) try ctx.err.print("✓ {s} is now the default host\n", .{host_name});
    return 0;
}

/// `auth setup-git`: points git's credential helper for each logged-in host
/// (or the one named) at `auth git-credential`, replacing any other helper
/// for that address.
fn setupGit(ctx: *Ctx, args: *const cli.Args) !u8 {
    const cfg = try config.load(ctx);
    var hosts: std.ArrayList(config.Host) = .empty;
    if (args.get("hostname")) |n| {
        try hosts.append(ctx.alloc, cfg.find(n) orelse return ctx.fail("not logged in to {s}; run `smith auth login --hostname {s}`", .{ n, n }));
    } else for (cfg.hosts) |h| {
        for (hosts.items) |seen| {
            if (std.ascii.eqlIgnoreCase(seen.name, h.name)) break;
        } else try hosts.append(ctx.alloc, h);
    }
    if (hosts.items.len == 0) return ctx.fail("not logged in to any Forgejo host; run `smith auth login`", .{});
    const helper = try helperCommand(ctx);
    for (hosts.items) |h| {
        try configureGit(ctx, h, helper);
        try ctx.err.print("✓ git uses smith's login for {s}\n", .{try h.webBase(ctx.alloc)});
    }
    return 0;
}

fn helperKey(ctx: *Ctx, h: config.Host) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "credential.{s}.helper", .{try h.webBase(ctx.alloc)});
}

/// The helper git runs: smith by the name `PATH` finds it under when that
/// is this binary (a symlink a package manager keeps across upgrades), else
/// the binary's own path.
fn helperCommand(ctx: *Ctx) ![]const u8 {
    const exe = std.process.executablePathAlloc(ctx.io, ctx.alloc) catch |e| return ctx.fail("cannot find smith's own path: {t}", .{e});
    const cwd = std.Io.Dir.cwd();
    var dirs = std.mem.tokenizeScalar(u8, ctx.getenv("PATH") orelse "", std.fs.path.delimiter);
    const chosen = while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(ctx.alloc, &.{ dir, if (platform.windows) "smith.exe" else "smith" });
        const real = cwd.realPathFileAlloc(ctx.io, candidate, ctx.alloc) catch continue;
        if (std.mem.eql(u8, real, exe)) break candidate;
    } else exe;
    return std.fmt.allocPrint(ctx.alloc, "!{s} auth git-credential", .{try shellQuote(ctx.alloc, chosen)});
}

fn configureGit(ctx: *Ctx, h: config.Host, helper: []const u8) !void {
    const key = try helperKey(ctx, h);
    try git.run(ctx, &.{ "config", "--global", "--replace-all", key, "" });
    try git.run(ctx, &.{ "config", "--global", "--add", key, helper });
}

/// Whether git already asks this very binary for the host's credentials.
fn gitConfigured(ctx: *Ctx, h: config.Host, helper: []const u8) !bool {
    const helpers = try git.capture(ctx, &.{ "config", "--global", "--get-all", try helperKey(ctx, h) }) orelse return false;
    var lines = std.mem.splitScalar(u8, helpers, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line, helper)) return true;
    return false;
}

fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/._+-", c) == null) break;
    } else return s;
    const escaped = try std.mem.replaceOwned(u8, alloc, s, "'", "'\\''");
    defer alloc.free(escaped);
    return std.fmt.allocPrint(alloc, "'{s}'", .{escaped});
}

/// After an HTTPS login: offers to make git use it, unless it already does.
fn offerGitSetup(ctx: *Ctx, host: config.Host) !void {
    const later = "- run `smith auth setup-git --hostname {s}` so git uses this login over HTTPS\n";
    const helper = try helperCommand(ctx);
    if (try gitConfigured(ctx, host, helper)) {
        try ctx.err.writeAll("- git uses this login over HTTPS\n");
        return;
    }
    if (!ctx.interactive() or !try askYes(ctx, "Make git use this login over HTTPS?")) {
        try ctx.err.print(later, .{host.name});
        return;
    }
    try configureGit(ctx, host, helper);
    try ctx.err.writeAll("✓ Configured git to use this login over HTTPS\n");
}

/// A yes/no question answered yes by default; ending the input says no.
fn askYes(ctx: *Ctx, question: []const u8) !bool {
    const answer = try ctx.promptOrEnd(try std.fmt.allocPrint(ctx.alloc, "{s} [Y/n]", .{question})) orelse return false;
    return answer.len == 0 or answer[0] == 'y' or answer[0] == 'Y';
}

/// `auth git-credential`: git's credential helper protocol. `get` answers
/// with the username and token of an account smith holds for exactly that
/// scheme and host; `store` and `erase` have nothing to keep or forget.
fn gitCredential(ctx: *Ctx, args: *const cli.Args) !u8 {
    const op = args.arg(0).?;
    const get = std.mem.eql(u8, op, "get");
    if (!get and !std.mem.eql(u8, op, "store") and !std.mem.eql(u8, op, "erase"))
        return ctx.fail("\"{s}\" is not a credential operation (get, store or erase)", .{op});
    const input = try ctx.readStdin();
    if (!get) return 0;
    var protocol: ?[]const u8 = null;
    var hostname: ?[]const u8 = null;
    var username: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, line[0..eq], "protocol")) protocol = value;
        if (std.mem.eql(u8, line[0..eq], "host")) hostname = value;
        if (std.mem.eql(u8, line[0..eq], "username")) username = value;
    }
    const scheme = protocol orelse return 0;
    const name = hostname orelse return 0;

    const cfg = try config.load(ctx);
    const stored = for (try cfg.accounts(ctx.alloc, name)) |a| {
        if (!std.ascii.eqlIgnoreCase(a.name, name) or !std.mem.eql(u8, a.scheme, scheme)) continue;
        if (username) |u| {
            if (a.user != null and std.ascii.eqlIgnoreCase(a.user.?, u)) break a;
        } else if (a.active) break a;
    } else return 0;
    const h = try oauth.refreshIfDue(ctx, if (stored.active) try config.withEnv(ctx, cfg, stored) else try config.withSecrets(ctx, stored));
    const t = h.token orelse return 0;
    try ctx.out.print("protocol={s}\nhost={s}\nusername={s}\npassword={s}\n", .{ scheme, name, h.user orelse "smith", t });
    return 0;
}

/// A public key in `~/.ssh`.
const LocalKey = struct { path: []const u8, text: []const u8 };

/// Whether two OpenSSH public key lines hold the same key, comments aside.
fn sameKey(a: []const u8, b: []const u8) bool {
    var x = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var y = std.mem.tokenizeAny(u8, b, " \t\r\n");
    for (0..2) |_| {
        const f = x.next() orelse return false;
        const g = y.next() orelse return false;
        if (!std.mem.eql(u8, f, g)) return false;
    }
    return true;
}

fn localKeys(ctx: *Ctx, ssh_dir: []const u8) ![]const LocalKey {
    var keys: std.ArrayList(LocalKey) = .empty;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, ssh_dir, .{ .iterate = true }) catch return keys.items;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind == .directory or !std.mem.endsWith(u8, entry.name, ".pub") or std.mem.endsWith(u8, entry.name, "-cert.pub")) continue;
        const text = dir.readFileAlloc(ctx.io, entry.name, ctx.alloc, .limited(64 * 1024)) catch continue;
        var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
        if (fields.next() == null or fields.next() == null) continue;
        try keys.append(ctx.alloc, .{ .path = try std.fs.path.join(ctx.alloc, &.{ ssh_dir, entry.name }), .text = std.mem.trim(u8, text, " \t\r\n") });
    }
    std.mem.sort(LocalKey, keys.items, {}, struct {
        fn lt(_: void, a: LocalKey, b: LocalKey) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return keys.items;
}

/// Every public key on the account, or null when they cannot be read.
fn accountKeys(ctx: *Ctx, client: *api.Client) !?[]const []const u8 {
    const Remote = struct { key: []const u8 = "" };
    const limit = client.host.page_size orelse 50;
    var keys: std.ArrayList([]const u8) = .empty;
    var page: u32 = 1;
    while (page <= 100) : (page += 1) {
        const path = try std.fmt.allocPrint(ctx.alloc, "/user/keys?page={d}&limit={d}", .{ page, limit });
        const r = client.raw(.GET, path, .{}) catch |e| switch (e) {
            error.Reported => return null,
            else => return e,
        };
        if (!r.ok()) return null;
        const batch = std.json.parseFromSliceLeaky([]const Remote, ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch return null;
        for (batch) |k| try keys.append(ctx.alloc, k.key);
        if (batch.len < limit) break;
    }
    return keys.items;
}

/// After an SSH login on a terminal: when none of the machine's public keys
/// is on the account, offers to add one, or to generate one when there is
/// none, so the first clone does not end at "Permission denied (publickey)".
fn offerSshKey(ctx: *Ctx, client: *api.Client, host: config.Host, password: ?Password) !void {
    if (!ctx.interactive()) return;
    const home = platform.home(ctx.env) orelse return;
    const ssh_dir = try std.fs.path.join(ctx.alloc, &.{ home, ".ssh" });
    const local = try localKeys(ctx, ssh_dir);
    const generated = try std.fs.path.join(ctx.alloc, &.{ ssh_dir, "id_ed25519" });
    const can_generate = ctx.onPath("ssh-keygen") and !exists(ctx, generated);
    if (local.len == 0 and !can_generate) return;

    const remote = try accountKeys(ctx, client) orelse return;
    for (local) |l| for (remote) |k| {
        if (sameKey(l.text, k)) return;
    };

    const chosen: LocalKey = if (local.len == 1) blk: {
        if (!try askYes(ctx, try std.fmt.allocPrint(ctx.alloc, "Add your SSH key {s} to {s}?", .{ local[0].path, host.name }))) return;
        break :blk local[0];
    } else if (local.len > 1) blk: {
        try ctx.err.print("None of your SSH keys is on {s}:\n", .{host.name});
        for (local, 1..) |l, i| try ctx.err.print("  {d}. {s}\n", .{ i, l.path });
        const answer = try ctx.promptOrEnd(try std.fmt.allocPrint(ctx.alloc, "Add which one? [1-{d}, Enter to skip]", .{local.len})) orelse return;
        if (answer.len == 0) return;
        const i = std.fmt.parseInt(usize, answer, 10) catch 0;
        if (i == 0 or i > local.len) {
            try ctx.err.print("! no key added; add one with `smith ssh-key add <file> --hostname {s}`\n", .{host.name});
            return;
        }
        break :blk local[i - 1];
    } else blk: {
        if (!try askYes(ctx, try std.fmt.allocPrint(ctx.alloc, "Generate an SSH key ({s}) and add it to {s}?", .{ generated, host.name }))) return;
        break :blk try generateKey(ctx, ssh_dir, generated) orelse return;
    };
    try uploadKey(ctx, client, host, password, chosen);
}

fn exists(ctx: *Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

/// Adds the key, with the password login's credentials when there are some
/// (asking for a fresh two-factor code if the first one has expired), else
/// with the token.
fn uploadKey(ctx: *Ctx, client: *api.Client, host: config.Host, password: ?Password, key: LocalKey) !void {
    const title = try std.fmt.allocPrint(ctx.alloc, "smith on {s} ({d})", .{ try platform.machineName(ctx.alloc, ctx.env), ctx.now });
    const body = try std.json.Stringify.valueAlloc(ctx.alloc, .{ .key = key.text, .title = title }, .{});
    var otp = if (password) |p| p.otp else null;
    var asked = false;
    const added = while (true) {
        const r = try client.raw(.POST, "/user/keys", .{
            .body = body,
            .authorization = if (password) |p| p.basic else null,
            .extra_headers = try otpHeaders(ctx, otp),
        });
        if (r.status != 401 or password == null or otp == null or asked) break r;
        otp = try ctx.prompt("Two-factor code (to add the key):");
        asked = true;
        if (otp.?.len == 0) break r;
    };
    if (added.ok()) {
        try ctx.err.print("✓ Added SSH key {s} to your account as \"{s}\"\n", .{ key.path, title });
        return;
    }
    const why = api.errorMessage(ctx.alloc, added.body) orelse try std.fmt.allocPrint(ctx.alloc, "HTTP {d}", .{added.status});
    try ctx.err.print("! {s} did not take the SSH key ({s}); add it with `smith ssh-key add {s} --hostname {s}` or under Settings > SSH / GPG Keys\n", .{ host.name, firstLine(why), key.path, host.name });
}

/// Runs ssh-keygen for a new ed25519 key; it asks for the passphrase itself,
/// so the passphrase never appears in a command line. Null, with a warning,
/// when it fails.
fn generateKey(ctx: *Ctx, ssh_dir: []const u8, path: []const u8) !?LocalKey {
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(ctx.io, ssh_dir, platform.private_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            try ctx.err.print("! cannot create {s}: {t}\n", .{ ssh_dir, e });
            return null;
        },
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.alloc, &.{ "ssh-keygen", "-q", "-t", "ed25519", "-f", path });
    if (ctx.stdin_data != null) try argv.appendSlice(ctx.alloc, &.{ "-N", "" });
    try ctx.out.flush();
    try ctx.err.flush();
    var child = std.process.spawn(ctx.io, .{
        .argv = argv.items,
        .stdin = if (ctx.stdin_data != null) .ignore else .inherit,
        .stdout = platform.stdoutToStderr(),
        .environ_map = ctx.env,
    }) catch |e| {
        try ctx.err.print("! cannot run ssh-keygen: {t}\n", .{e});
        return null;
    };
    platform.copyOut(ctx.io, &child, ctx.err);
    const exit = try child.wait(ctx.io);
    if (exit != .exited or exit.exited != 0) {
        try ctx.err.print("! ssh-keygen did not create {s}\n", .{path});
        return null;
    }
    const pub_path = try std.fmt.allocPrint(ctx.alloc, "{s}.pub", .{path});
    const text = cwd.readFileAlloc(ctx.io, pub_path, ctx.alloc, .limited(64 * 1024)) catch |e| {
        try ctx.err.print("! cannot read {s}: {t}\n", .{ pub_path, e });
        return null;
    };
    return .{ .path = pub_path, .text = std.mem.trim(u8, text, " \t\r\n") };
}

test "shellQuote leaves a plain path alone and single-quotes anything else" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("/usr/bin/smith", try shellQuote(a, "/usr/bin/smith"));
    const spaced = try shellQuote(a, "/opt/my tools/smith");
    defer a.free(spaced);
    try std.testing.expectEqualStrings("'/opt/my tools/smith'", spaced);
    const quoted = try shellQuote(a, "/opt/it's/smith");
    defer a.free(quoted);
    try std.testing.expectEqualStrings("'/opt/it'\\''s/smith'", quoted);
}

test "sameKey compares the type and data, not the comment or spacing" {
    try std.testing.expect(sameKey("ssh-ed25519 AAAA me@a\n", "ssh-ed25519\tAAAA"));
    try std.testing.expect(!sameKey("ssh-ed25519 AAAA", "ssh-ed25519 AAAB"));
    try std.testing.expect(!sameKey("ssh-rsa AAAA", "ssh-ed25519 AAAA"));
    try std.testing.expect(!sameKey("ssh-rsa", "ssh-rsa"));
}
