const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const repo = @import("../repo.zig");
const types = @import("../types.zig");

pub const command: cli.Command = .{
    .name = "browse",
    .summary = "Open the repository, an issue, a pull request or a file in the browser.",
    .usage = "[<number> | <path>[:<line>]]",
    .max_args = 1,
    .flags = &.{
        .{ .long = "branch", .short = 'b', .value = "string", .help = "Branch to show a path on (default: the default branch)" },
        .{ .long = "settings", .short = 's', .help = "Open the repository settings" },
        .{ .long = "actions", .short = 'a', .help = "Open the Actions page" },
        .{ .long = "no-browser", .short = 'n', .help = "Print the URL instead of opening it" },
        cli.repo_flag,
    },
    .run = run,
};

fn run(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    const url = if (args.has("settings"))
        try r.webUrl(ctx.alloc, "/settings", .{})
    else if (args.has("actions"))
        try r.webUrl(ctx.alloc, "/actions", .{})
    else if (args.arg(0)) |target| blk: {
        const trimmed = std.mem.trimStart(u8, target, "#");
        if (std.fmt.parseInt(i64, trimmed, 10)) |n| break :blk try r.webUrl(ctx.alloc, "/issues/{d}", .{n}) else |_| {}
        const branch = args.get("branch") orelse default: {
            var client = try r.client(ctx);
            const info = try api.decode(types.Repository, ctx, try client.getValue(try r.path(ctx.alloc, "", .{})));
            break :default info.default_branch orelse "main";
        };
        var path = if (std.mem.startsWith(u8, target, "./")) target[2..] else target;
        var anchor: []const u8 = "";
        if (std.mem.lastIndexOfScalar(u8, path, ':')) |c| {
            if (std.fmt.parseInt(u32, path[c + 1 ..], 10)) |line| {
                anchor = try std.fmt.allocPrint(ctx.alloc, "#L{d}", .{line});
                path = path[0..c];
            } else |_| {}
        }
        break :blk try r.webUrl(ctx.alloc, "/src/branch/{s}/{s}{s}", .{ branch, path, anchor });
    } else if (args.get("branch")) |b|
        try r.webUrl(ctx.alloc, "/src/branch/{s}", .{b})
    else
        try r.webUrl(ctx.alloc, "", .{});

    if (args.has("no-browser")) {
        try ctx.out.print("{s}\n", .{url});
        return 0;
    }
    try ctx.openBrowser(url);
    return 0;
}
