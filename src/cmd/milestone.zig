const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const localtime = @import("../localtime.zig");
const types = @import("../types.zig");
const common = @import("common.zig");

const due_flag: cli.Flag = .{ .long = "due", .value = "YYYY-MM-DD", .help = "Due date" };
const description_flag: cli.Flag = .{ .long = "description", .short = 'd', .value = "string", .help = "Description" };
const name_usage = "<title | id>";

pub const command: cli.Command = .{
    .name = "milestone",
    .summary = "Manage milestones.",
    .subs = &.{
        .{
            .name = "list",
            .pages = true,
            .summary = "List a repository's milestones.",
            .flags = &.{ .{ .long = "state", .short = 's', .value = "open|closed|all", .help = "Filter by state (default open)" }, cli.json_flag, cli.repo_flag },
            .run = list,
        },
        .{ .name = "view", .summary = "Show a milestone.", .usage = name_usage, .min_args = 1, .max_args = 1, .flags = &.{ cli.json_flag, cli.repo_flag }, .run = view },
        .{ .name = "create", .summary = "Create a milestone.", .usage = "<title>", .min_args = 1, .max_args = 1, .flags = &.{ due_flag, description_flag, cli.repo_flag }, .run = create },
        .{
            .name = "edit",
            .summary = "Edit a milestone.",
            .usage = name_usage,
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ .{ .long = "title", .short = 't', .value = "string", .help = "Rename it" }, due_flag, description_flag, cli.repo_flag },
            .run = edit,
        },
        .{ .name = "close", .summary = "Close a milestone.", .usage = name_usage, .min_args = 1, .max_args = 1, .flags = &.{cli.repo_flag}, .run = close },
        .{ .name = "reopen", .summary = "Reopen a milestone.", .usage = name_usage, .min_args = 1, .max_args = 1, .flags = &.{cli.repo_flag}, .run = reopen },
        .{ .name = "delete", .summary = "Delete a milestone.", .usage = name_usage, .min_args = 1, .max_args = 1, .flags = &.{ cli.yes_flag, cli.repo_flag }, .run = delete },
    },
};

/// Forgejo looks a milestone up by id, else by title.
fn path(ctx: *Ctx, r: repo.Repo, name: []const u8) ![]const u8 {
    return r.path(ctx.alloc, "/milestones/{s}", .{try api.escape(ctx.alloc, name)});
}

fn due(ctx: *Ctx, args: *const cli.Args) !?[]const u8 {
    const d = args.get("due") orelse return null;
    const midnight = term.parseTime(try std.fmt.allocPrint(ctx.alloc, "{s}T00:00:00Z", .{d})) orelse
        return ctx.fail("--due takes a date as YYYY-MM-DD, got \"{s}\"", .{d});
    return try localtime.utc(ctx.alloc, localtime.endOfDay(ctx, @divFloor(midnight, 86400)));
}

/// The local day a due date falls on; Forgejo reports it in its own zone.
fn dueDate(ctx: *Ctx, stamp: []const u8) ![]const u8 {
    const unix = term.parseTime(stamp) orelse return stamp[0..@min(10, stamp.len)];
    var buf: [10]u8 = undefined;
    return ctx.alloc.dupe(u8, localtime.date(ctx, unix, &buf));
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const state = args.get("state") orelse "open";
    const values = try client.listValues(try common.query(ctx, try r.path(ctx.alloc, "/milestones", .{}), &.{.{ "state", state }}), 10000, null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const ms = try api.decodeAll(types.Milestone, ctx, values);
    if (ms.len == 0) {
        try ctx.err.print("No {s} milestones in {s}\n", .{ state, try r.fullName(ctx.alloc) });
        return 0;
    }
    var table: term.Table = .{};
    for (ms) |m| try table.add(ctx.alloc, &.{
        .{ .text = m.title, .color = .bold },
        .{ .text = try progress(ctx, m) },
        .{ .text = if (m.due_on) |d| try std.fmt.allocPrint(ctx.alloc, "due {s}", .{try dueDate(ctx, d)}) else "", .color = .dim },
        .{ .text = m.state, .color = common.stateColor(m.state) },
    });
    try table.write(ctx);
    return 0;
}

fn progress(ctx: *Ctx, m: types.Milestone) ![]const u8 {
    const total = m.open_issues + m.closed_issues;
    const pct: i64 = if (total == 0) 0 else @divFloor(m.closed_issues * 100, total);
    return std.fmt.allocPrint(ctx.alloc, "{d}/{d} closed ({d}%)", .{ m.closed_issues, total, pct });
}

fn view(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const v = try client.getValue(try path(ctx, r, args.arg(0).?));
    if (args.has("json")) {
        try api.printJson(ctx, v);
        return 0;
    }
    const m = try api.decode(types.Milestone, ctx, v);
    try term.paint(ctx, ctx.out, .bold, m.title);
    try ctx.out.print("\n{s} · {s}", .{ m.state, try progress(ctx, m) });
    if (m.due_on) |d| try ctx.out.print(" · due {s}", .{try dueDate(ctx, d)});
    try ctx.out.writeAll("\n\n");
    try common.writeBody(ctx, m.description);
    return 0;
}

fn create(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const Create = struct { title: []const u8, description: []const u8, due_on: ?[]const u8 = null };
    const v = try client.sendValue(.POST, try r.path(ctx.alloc, "/milestones", .{}), Create{
        .title = args.arg(0).?,
        .description = args.get("description") orelse "",
        .due_on = try due(ctx, args),
    });
    const m = try api.decode(types.Milestone, ctx, v);
    try ctx.err.print("✓ Created milestone \"{s}\" (id {d})\n", .{ m.title, m.id });
    return 0;
}

fn patch(ctx: *Ctx, args: *const cli.Args, body: anytype, verb: []const u8) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const v = try client.sendValue(.PATCH, try path(ctx, r, args.arg(0).?), body);
    const m = try api.decode(types.Milestone, ctx, v);
    try ctx.err.print("✓ {s} milestone \"{s}\"\n", .{ verb, m.title });
    return 0;
}

fn edit(ctx: *Ctx, args: *const cli.Args) !u8 {
    const Patch = struct { title: ?[]const u8 = null, description: ?[]const u8 = null, due_on: ?[]const u8 = null };
    return patch(ctx, args, Patch{ .title = args.get("title"), .description = args.get("description"), .due_on = try due(ctx, args) }, "Updated");
}

fn close(ctx: *Ctx, args: *const cli.Args) !u8 {
    return patch(ctx, args, .{ .state = "closed" }, "Closed");
}

fn reopen(ctx: *Ctx, args: *const cli.Args) !u8 {
    return patch(ctx, args, .{ .state = "open" }, "Reopened");
}

fn delete(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const m = try api.decode(types.Milestone, ctx, try client.getValue(try path(ctx, r, args.arg(0).?)));
    if (!try ctx.confirm(try std.fmt.allocPrint(ctx.alloc, "Delete milestone \"{s}\"?", .{m.title}), args.has("yes"))) return 1;
    _ = try client.call(.DELETE, try r.path(ctx.alloc, "/milestones/{d}", .{m.id}), .{});
    try ctx.err.print("✓ Deleted milestone \"{s}\"\n", .{m.title});
    return 0;
}
