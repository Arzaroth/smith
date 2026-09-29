const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const config = @import("../config.zig");
const api = @import("../api.zig");
const git = @import("../git.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");

const hostname_flag: cli.Flag = .{ .long = "hostname", .value = "string", .help = "The Forgejo host, e.g. git.example.com" };

pub const command: cli.Command = .{
    .name = "auth",
    .summary = "Authenticate smith with a Forgejo host.",
    .subs = &.{
        .{
            .name = "login",
            .summary = "Log in to a Forgejo host with an access token.",
            .flags = &.{
                hostname_flag,
                .{ .long = "with-token", .help = "Read the token from standard input" },
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

fn login(ctx: *Ctx, args: *const cli.Args) !u8 {
    var cfg = try config.load(ctx);
    const name = args.get("hostname") orelse ctx.getenv("SMITH_HOST") orelse
        if (ctx.interactive()) try ctx.prompt("Forgejo hostname:") else return ctx.fail("--hostname is required when not running interactively", .{});
    if (name.len == 0) return ctx.fail("a hostname is required", .{});

    var host: config.Host = cfg.find(name) orelse .{ .name = name };
    host.name = name;
    if (args.get("scheme")) |s| {
        if (!std.mem.eql(u8, s, "https") and !std.mem.eql(u8, s, "http")) return ctx.fail("--scheme must be https or http", .{});
        host.scheme = s;
    }
    if (args.get("git-protocol")) |p| host.git_protocol = std.meta.stringToEnum(config.Protocol, p) orelse
        return ctx.fail("--git-protocol must be ssh or https", .{});
    if (args.get("ssh-host")) |s| host.ssh_host = s;

    const tok = if (args.has("with-token"))
        std.mem.trim(u8, try ctx.readStdin(), " \r\n\t")
    else if (ctx.interactive()) blk: {
        try ctx.err.print(
            \\Create a token at {s}/user/settings/applications with the scopes
            \\write:repository, write:issue and read:user.
            \\
        , .{try host.webBase(ctx.alloc)});
        break :blk try ctx.promptSecret("Paste your token:");
    } else return ctx.fail("--with-token is required when not running interactively", .{});
    if (tok.len == 0) return ctx.fail("no token given", .{});
    host.token = tok;

    var client = try api.Client.init(ctx, host);
    const v = try api.decode(types.Version, ctx, try client.getValue("/version"));

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

    try ctx.err.print("✓ Logged in to {s} (Forgejo {s})", .{ host.name, v.version });
    if (host.user) |u| try ctx.err.print(" as {s}", .{u});
    try ctx.err.writeByte('\n');
    try ctx.err.print("- git operations use {t}", .{host.git_protocol});
    if (host.ssh_host) |s| try ctx.err.print(" (SSH host {s})", .{s});
    try ctx.err.writeByte('\n');
    return 0;
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
