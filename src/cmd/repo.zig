const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const config = @import("../config.zig");
const api = @import("../api.zig");
const git = @import("../git.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");

pub const command: cli.Command = .{
    .name = "repo",
    .summary = "Work with repositories.",
    .subs = &.{
        .{
            .name = "clone",
            .summary = "Clone a repository locally; a fork gets an `upstream` remote.",
            .usage = "<repository> [<directory>] [-- <gitflags>...]",
            .min_args = 1,
            .max_args = 2,
            .passthrough = true,
            .flags = &.{.{ .long = "upstream-remote-name", .short = 'u', .value = "string", .help = "Name of the remote pointing at a fork's parent (default upstream)" }},
            .run = clone,
        },
        .{
            .name = "view",
            .summary = "Show a repository's description and details.",
            .usage = "[<repository>]",
            .max_args = 1,
            .flags = &.{ cli.web_flag, cli.json_flag },
            .run = view,
        },
        .{
            .name = "list",
            .summary = "List the repositories of a user or organization.",
            .usage = "[<owner>]",
            .max_args = 1,
            .flags = &.{ cli.limit_flag, cli.json_flag, .{ .long = "hostname", .value = "string", .help = "The Forgejo host to list from" } },
            .run = list,
        },
    },
};

/// The repository named by a positional argument (`REPO`, `OWNER/REPO` or
/// `HOST/OWNER/REPO`), or the current one.
fn target(ctx: *Ctx, args: *const cli.Args, spec_arg: ?[]const u8) !repo.Repo {
    const s = spec_arg orelse return repo.resolve(ctx, args);
    const cfg = try config.load(ctx);
    if (std.mem.indexOfScalar(u8, s, '/') == null) {
        const host = try repo.hostFor(ctx, cfg, null);
        const owner = host.user orelse return ctx.fail("cannot tell whose \"{s}\" this is; use OWNER/REPO", .{s});
        return .{ .host = host, .owner = owner, .name = s };
    }
    const spec = repo.parseSpec(s) orelse return ctx.fail("expected [HOST/]OWNER/REPO, got \"{s}\"", .{s});
    return .{ .host = try repo.hostFor(ctx, cfg, spec.host), .owner = spec.owner, .name = spec.name };
}

fn cloneUrl(r: types.Repository, protocol: config.Protocol) ?[]const u8 {
    return switch (protocol) {
        .ssh => r.ssh_url orelse r.clone_url,
        .https => r.clone_url orelse r.ssh_url,
    };
}

fn clone(ctx: *Ctx, args: *const cli.Args) !u8 {
    const t = try target(ctx, args, args.arg(0));
    var client = try t.client(ctx);
    const info = try api.decode(types.Repository, ctx, try client.getValue(try t.path(ctx.alloc, "", .{})));
    const url = cloneUrl(info, t.host.git_protocol) orelse return ctx.fail("{s} has no clone URL", .{info.full_name});
    const dir = args.arg(1) orelse info.name;

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.alloc, &.{ "clone", url, dir });
    try argv.appendSlice(ctx.alloc, args.passthrough);
    try git.run(ctx, argv.items);

    if (info.fork) if (info.parent) |parent| {
        const name = args.get("upstream-remote-name") orelse "upstream";
        const parent_url = cloneUrl(parent.*, t.host.git_protocol) orelse return 0;
        try git.run(ctx, &.{ "-C", dir, "remote", "add", "-f", "--", name, parent_url });
        try ctx.err.print("✓ Added remote {s} for {s}\n", .{ name, parent.full_name });
    };
    return 0;
}

fn view(ctx: *Ctx, args: *const cli.Args) !u8 {
    const t = try target(ctx, args, args.arg(0));
    if (args.has("web")) {
        try ctx.openBrowser(try t.webUrl(ctx.alloc, "", .{}));
        return 0;
    }
    var client = try t.client(ctx);
    const v = try client.getValue(try t.path(ctx.alloc, "", .{}));
    if (args.has("json")) {
        try api.printJson(ctx, v);
        return 0;
    }
    const r = try api.decode(types.Repository, ctx, v);
    const w = ctx.out;
    try term.paint(ctx, w, .bold, r.full_name);
    try w.writeByte('\n');
    if (r.description) |d| if (d.len > 0) try w.print("{s}\n", .{d});
    try w.writeByte('\n');
    try w.print("{s}", .{if (r.private) "private" else "public"});
    if (r.fork) if (r.parent) |p| try w.print(" · fork of {s}", .{p.full_name});
    if (r.archived) try w.writeAll(" · archived");
    try w.print(" · {d} stars · {d} forks · {d} open issues · {d} open pull requests\n", .{ r.stars_count, r.forks_count, r.open_issues_count, r.open_pr_counter });
    if (r.default_branch) |b| try w.print("Default branch: {s}\n", .{b});
    if (r.ssh_url) |u| try w.print("SSH:   {s}\n", .{u});
    if (r.clone_url) |u| try w.print("HTTPS: {s}\n", .{u});
    try term.paint(ctx, w, .dim, r.html_url);
    try w.writeByte('\n');
    return 0;
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const cfg = try config.load(ctx);
    const host = try repo.hostFor(ctx, cfg, args.get("hostname"));
    var client = try api.Client.init(ctx, host);
    const limit = try args.int("limit", 30);

    const values = if (args.arg(0)) |owner| blk: {
        const user_path = try std.fmt.allocPrint(ctx.alloc, "/users/{s}/repos", .{try api.escape(ctx.alloc, owner)});
        const probe = try client.raw(.GET, try std.fmt.allocPrint(ctx.alloc, "{s}?limit=1", .{user_path}), .{});
        if (probe.status == 404) {
            break :blk try client.listValues(try std.fmt.allocPrint(ctx.alloc, "/orgs/{s}/repos", .{try api.escape(ctx.alloc, owner)}), limit, null);
        }
        break :blk try client.listValues(user_path, limit, null);
    } else try client.listValues("/user/repos", limit, null);

    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const repos = try api.decodeAll(types.Repository, ctx, values);
    if (repos.len == 0) {
        try ctx.err.writeAll("No repositories found\n");
        return 0;
    }
    var table: term.Table = .{};
    for (repos) |r| {
        const kind = if (r.private) "private" else if (r.fork) "fork" else if (r.archived) "archived" else "public";
        try table.add(ctx.alloc, &.{
            .{ .text = r.full_name, .color = .bold },
            .{ .text = try term.truncate(ctx.alloc, r.description orelse "", 50) },
            .{ .text = kind, .color = .dim },
            .{ .text = try term.ago(ctx.alloc, ctx.now, r.updated_at), .color = .dim },
        });
    }
    try table.write(ctx);
    return 0;
}
