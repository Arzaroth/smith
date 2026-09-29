const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const term = @import("../term.zig");
const search = @import("search.zig");

pub const command: cli.Command = .{
    .name = "status",
    .summary = "What needs you across a host: assigned issues and pull requests, review requests, mentions.",
    .flags = &.{
        .{ .long = "hostname", .value = "string", .help = "The Forgejo host (default: the default host)" },
        .{ .long = "limit", .short = 'L', .value = "int", .help = "Items per section (default 10)" },
        cli.json_flag,
    },
    .run = run,
};

const sections = [_]struct { title: []const u8, key: []const u8, type: []const u8, filter: []const u8 }{
    .{ .title = "Assigned issues", .key = "assigned_issues", .type = "issues", .filter = "assigned" },
    .{ .title = "Assigned pull requests", .key = "assigned_pull_requests", .type = "pulls", .filter = "assigned" },
    .{ .title = "Review requests", .key = "review_requests", .type = "pulls", .filter = "review_requested" },
    .{ .title = "Mentions", .key = "mentions", .type = "issues", .filter = "mentioned" },
};

fn run(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    if (c.host.token == null) return ctx.fail("status needs a login; run `smith auth login`", .{});
    const limit = try args.int("limit", 10);
    var results: [sections.len][]const std.json.Value = undefined;
    for (sections, 0..) |s, i| {
        const path = try std.fmt.allocPrint(ctx.alloc, "/repos/issues/search?state=open&type={s}&{s}=true&sort=recentupdate", .{ s.type, s.filter });
        results[i] = try c.listValues(path, limit, null);
    }
    if (args.has("json")) {
        var obj: std.json.ObjectMap = .empty;
        for (sections, results) |s, r| {
            var arr: std.json.Array = .init(ctx.alloc);
            try arr.appendSlice(r);
            try obj.put(ctx.alloc, s.key, .{ .array = arr });
        }
        try api.printJson(ctx, std.json.Value{ .object = obj });
        return 0;
    }
    for (sections, results, 0..) |s, r, i| {
        if (i > 0) try ctx.out.writeByte('\n');
        try term.paint(ctx, ctx.out, .bold, s.title);
        try ctx.out.writeByte('\n');
        if (r.len == 0) {
            try term.paint(ctx, ctx.out, .dim, "  Nothing here\n");
            continue;
        }
        try search.writeFound(ctx, try api.decodeAll(search.Found, ctx, r));
    }
    return 0;
}
