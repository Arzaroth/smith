const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const config = @import("../config.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");
const common = @import("common.zig");

const hostname_flag: cli.Flag = .{ .long = "hostname", .value = "string", .help = "The Forgejo host (default: the default host)" };
const owner_flag: cli.Flag = .{ .long = "owner", .value = "name", .help = "Only this user's or organization's" };
const state_flag: cli.Flag = .{ .long = "state", .short = 's', .value = "open|closed|all", .help = "Filter by state (default open)" };

pub const command: cli.Command = .{
    .name = "search",
    .summary = "Search repositories, issues and pull requests across a host.",
    .subs = &.{
        .{ .name = "repos", .summary = "Search repositories.", .usage = "<query>", .min_args = 1, .max_args = 1, .flags = &.{ owner_flag, .{ .long = "archived", .help = "Include archived repositories" }, cli.limit_flag, cli.json_flag, hostname_flag }, .run = repos },
        .{ .name = "issues", .summary = "Search issues.", .usage = "<query>", .min_args = 1, .max_args = 1, .flags = &.{ state_flag, owner_flag, cli.limit_flag, cli.json_flag, hostname_flag }, .run = issues },
        .{ .name = "prs", .summary = "Search pull requests.", .usage = "<query>", .min_args = 1, .max_args = 1, .flags = &.{ state_flag, owner_flag, cli.limit_flag, cli.json_flag, hostname_flag }, .run = prs },
    },
};

pub fn client(ctx: *Ctx, args: *const cli.Args) !api.Client {
    const cfg = try config.load(ctx);
    return api.Client.init(ctx, try repo.hostFor(ctx, cfg, args.get("hostname")));
}

fn repos(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try client(ctx, args);
    var path = try common.query(ctx, "/repos/search", &.{ .{ "q", args.arg(0).? }, .{ "sort", "updated" }, .{ "order", "desc" } });
    if (!args.has("archived")) path = try std.fmt.allocPrint(ctx.alloc, "{s}&archived=false", .{path});
    if (args.get("owner")) |o| {
        const Owner = struct { id: i64 };
        const id = (try api.decode(Owner, ctx, try c.getValue(try std.fmt.allocPrint(ctx.alloc, "/users/{s}", .{try api.escape(ctx.alloc, o)})))).id;
        path = try std.fmt.allocPrint(ctx.alloc, "{s}&uid={d}&exclusive=true", .{ path, id });
    }
    const values = try c.listValues(path, try args.int("limit", 30), "data");
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const found = try api.decodeAll(types.Repository, ctx, values);
    if (found.len == 0) {
        try ctx.err.writeAll("No repositories matched\n");
        return 0;
    }
    var table: term.Table = .{};
    for (found) |r| try table.add(ctx.alloc, &.{
        .{ .text = r.full_name, .color = .bold },
        .{ .text = try term.truncate(ctx.alloc, r.description orelse "", 50) },
        .{ .text = if (r.private) "private" else if (r.fork) "fork" else "public", .color = .dim },
        .{ .text = try term.ago(ctx.alloc, ctx.now, r.updated_at), .color = .dim },
    });
    try table.write(ctx);
    return 0;
}

/// An issue or pull request from `/repos/issues/search`, which names its repository.
pub const Found = struct {
    number: i64,
    title: []const u8,
    state: []const u8,
    html_url: []const u8 = "",
    updated_at: ?[]const u8 = null,
    repository: ?struct { full_name: []const u8 } = null,
};

fn searchIssues(ctx: *Ctx, args: *const cli.Args, kind: []const u8) !u8 {
    var c = try client(ctx, args);
    const path = try common.query(ctx, "/repos/issues/search", &.{
        .{ "q", args.arg(0).? },
        .{ "type", kind },
        .{ "state", args.get("state") orelse "open" },
        .{ "owner", args.get("owner") },
    });
    const values = try c.listValues(path, try args.int("limit", 30), null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const found = try api.decodeAll(Found, ctx, values);
    if (found.len == 0) {
        try ctx.err.print("No {s} matched\n", .{if (std.mem.eql(u8, kind, "pulls")) "pull requests" else "issues"});
        return 0;
    }
    try writeFound(ctx, found);
    return 0;
}

pub fn writeFound(ctx: *Ctx, found: []const Found) !void {
    var table: term.Table = .{};
    for (found) |f| try table.add(ctx.alloc, &.{
        .{ .text = try std.fmt.allocPrint(ctx.alloc, "{s}#{d}", .{ if (f.repository) |r| r.full_name else "", f.number }), .color = common.stateColor(f.state) },
        .{ .text = if (ctx.stdout_tty) try term.truncate(ctx.alloc, f.title, 70) else f.title },
        .{ .text = try term.ago(ctx.alloc, ctx.now, f.updated_at), .color = .dim },
    });
    try table.write(ctx);
}

fn issues(ctx: *Ctx, args: *const cli.Args) !u8 {
    return searchIssues(ctx, args, "issues");
}

fn prs(ctx: *Ctx, args: *const cli.Args) !u8 {
    return searchIssues(ctx, args, "pulls");
}
