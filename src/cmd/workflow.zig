const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");

pub const command: cli.Command = .{
    .name = "workflow",
    .summary = "List and dispatch Forgejo Actions workflows.",
    .subs = &.{
        .{
            .name = "list",
            .pages = true,
            .summary = "List the workflow files on the default branch.",
            .flags = &.{ cli.json_flag, cli.repo_flag },
            .run = list,
        },
        .{
            .name = "run",
            .summary = "Dispatch a workflow that runs on workflow_dispatch.",
            .usage = "<workflow-file>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{
                .{ .long = "ref", .short = 'r', .value = "branch", .help = "Branch or tag to run on (default: the default branch)" },
                .{ .long = "field", .short = 'F', .value = "key=value", .help = "Workflow input; @file reads the value from a file (repeatable)" },
                .{ .long = "raw-field", .short = 'f', .value = "key=value", .help = "Workflow input taken literally (repeatable)" },
                cli.repo_flag,
            },
            .run = run,
        },
    },
};

/// Where Forgejo looks for workflows, in its order of preference.
const dirs = [_][]const u8{ ".forgejo/workflows", ".gitea/workflows", ".github/workflows" };

const Entry = struct { name: []const u8, path: []const u8, type: []const u8 = "file" };

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    var all: std.ArrayList(std.json.Value) = .empty;
    for (dirs) |d| {
        const resp = try client.raw(.GET, try r.path(ctx.alloc, "/contents/{s}", .{d}), .{});
        if (resp.status == 404) continue;
        if (!resp.ok()) return client.failStatus(.GET, d, resp);
        const v = try client.parseValue(resp.body);
        if (v != .array) continue;
        for (v.array.items) |item| {
            const e = try api.decode(Entry, ctx, item);
            if (!std.mem.eql(u8, e.type, "file")) continue;
            if (!std.mem.endsWith(u8, e.name, ".yml") and !std.mem.endsWith(u8, e.name, ".yaml")) continue;
            try all.append(ctx.alloc, item);
        }
        break;
    }
    if (args.has("json")) {
        try api.printJson(ctx, all.items);
        return 0;
    }
    if (all.items.len == 0) {
        try ctx.err.print("No workflows in {s}\n", .{try r.fullName(ctx.alloc)});
        return 0;
    }
    var table: term.Table = .{};
    for (all.items) |item| {
        const e = try api.decode(Entry, ctx, item);
        try table.add(ctx.alloc, &.{ .{ .text = e.name, .color = .bold }, .{ .text = e.path, .color = .dim } });
    }
    try table.write(ctx);
    return 0;
}

fn run(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const file = std.fs.path.basename(args.arg(0).?);
    const ref = args.get("ref") orelse blk: {
        const info = try api.decode(types.Repository, ctx, try client.getValue(try r.path(ctx.alloc, "", .{})));
        break :blk info.default_branch orelse "main";
    };
    var inputs: std.json.ObjectMap = .empty;
    for (args.names, args.values) |n, v| {
        const raw = std.mem.eql(u8, n, "raw-field");
        if (!raw and !std.mem.eql(u8, n, "field")) continue;
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse return ctx.fail("invalid field \"{s}\"; expected key=value", .{v});
        var value = v[eq + 1 ..];
        if (!raw and std.mem.startsWith(u8, value, "@")) value = std.Io.Dir.cwd().readFileAlloc(ctx.io, value[1..], ctx.alloc, .limited(1024 * 1024)) catch |e|
            return ctx.fail("cannot read {s}: {t}", .{ value[1..], e });
        try inputs.put(ctx.alloc, v[0..eq], .{ .string = value });
    }
    const Dispatch = struct { ref: []const u8, inputs: std.json.Value, return_run_info: bool };
    const resp = try client.sendValue(.POST, try r.path(ctx.alloc, "/actions/workflows/{s}/dispatches", .{try api.escape(ctx.alloc, file)}), Dispatch{
        .ref = ref,
        .inputs = .{ .object = inputs },
        .return_run_info = true,
    });
    try ctx.err.print("✓ Dispatched {s} on {s}\n", .{ file, ref });
    if (resp == .object) if (resp.object.get("id")) |id| if (id == .integer)
        try ctx.err.print("- follow it with `smith run watch {d}`\n", .{id.integer});
    return 0;
}
