const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const term = @import("../term.zig");
const search = @import("search.zig");

const hostname_flag: cli.Flag = .{ .long = "hostname", .value = "string", .help = "The Forgejo host (default: the default host)" };

pub const command: cli.Command = .{
    .name = "notification",
    .summary = "Read your notifications.",
    .subs = &.{
        .{
            .name = "list",
            .summary = "List unread notifications (all of them with --all).",
            .flags = &.{ .{ .long = "all", .short = 'a', .help = "Include read ones" }, cli.limit_flag, cli.json_flag, hostname_flag },
            .run = list,
        },
        .{
            .name = "read",
            .summary = "Mark a notification as read, or all of them.",
            .usage = "[<id>]",
            .max_args = 1,
            .flags = &.{ .{ .long = "all", .short = 'a', .help = "Mark every notification as read" }, hostname_flag },
            .run = read,
        },
    },
};

const Thread = struct {
    id: i64,
    unread: bool = false,
    updated_at: ?[]const u8 = null,
    repository: ?struct { full_name: []const u8 } = null,
    subject: struct {
        title: []const u8,
        type: []const u8 = "",
        state: ?[]const u8 = null,
        html_url: ?[]const u8 = null,
    },
};

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    const path = if (args.has("all")) "/notifications?all=true" else "/notifications?all=false";
    const values = try c.listValues(path, try args.int("limit", 30), null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const threads = try api.decodeAll(Thread, ctx, values);
    if (threads.len == 0) {
        try ctx.err.writeAll("No notifications\n");
        return 0;
    }
    var table: term.Table = .{};
    for (threads) |t| try table.add(ctx.alloc, &.{
        .{ .text = if (!ctx.stdout_tty) (if (t.unread) "unread" else "read") else if (t.unread) "●" else " ", .color = .cyan },
        .{ .text = try std.fmt.allocPrint(ctx.alloc, "{d}", .{t.id}), .color = .dim },
        .{ .text = if (t.repository) |r| r.full_name else "" },
        .{ .text = t.subject.type, .color = .dim },
        .{ .text = try term.fit(ctx, t.subject.title, 60), .color = if (t.unread) .bold else .none },
        .{ .text = try term.when(ctx, t.updated_at), .color = .dim },
    });
    try table.write(ctx);
    return 0;
}

fn read(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    if (args.has("all")) {
        if (args.arg(0) != null) return ctx.fail("give an id or --all, not both", .{});
        _ = try c.call(.PUT, "/notifications?all=true&to-status=read", .{});
        try ctx.err.writeAll("✓ Marked every notification as read\n");
        return 0;
    }
    const id = args.arg(0) orelse return ctx.fail("give a notification id, or --all", .{});
    _ = std.fmt.parseInt(i64, id, 10) catch return ctx.fail("invalid notification id: {s}", .{id});
    _ = try c.call(.PATCH, try std.fmt.allocPrint(ctx.alloc, "/notifications/threads/{s}?to-status=read", .{id}), .{});
    try ctx.err.print("✓ Marked notification {s} as read\n", .{id});
    return 0;
}
