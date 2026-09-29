//! The command tree and dispatch, separate from process setup so tests can
//! drive a whole invocation.
const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const Ctx = @import("Ctx.zig");

pub const version = build_options.version;

pub const root: cli.Command = .{
    .name = "smith",
    .summary = "Work with Forgejo from the command line.",
    .flags = &.{.{ .long = "version", .short = 'V', .help = "Show the version" }},
    .subs = &.{
        @import("cmd/auth.zig").command,
        @import("cmd/repo.zig").command,
    },
    .run = runRoot,
};

fn runRoot(ctx: *Ctx, args: *const cli.Args) !u8 {
    if (args.has("version")) {
        try ctx.out.print("smith {s}\n", .{version});
        return 0;
    }
    try cli.writeHelp(ctx.out, &.{&root});
    return 0;
}

/// Runs one invocation (`argv` without the program name) and returns the exit code.
pub fn run(ctx: *Ctx, argv: []const []const u8) u8 {
    const code = dispatch(ctx, argv) catch |e| switch (e) {
        error.Reported => 1,
        error.Usage => 1,
        else => blk: {
            ctx.err.print("smith: {t}\n", .{e}) catch {};
            break :blk 1;
        },
    };
    ctx.out.flush() catch {};
    ctx.err.flush() catch {};
    return code;
}

fn dispatch(ctx: *Ctx, argv: []const []const u8) !u8 {
    const r = try cli.resolve(ctx.alloc, &root, argv);
    const cmd = r.path[r.path.len - 1];
    const help_path = try helpPath(ctx, r.path);

    if (cmd.subs.len > 0 and r.rest.len > 0 and r.rest[0].len > 0 and r.rest[0][0] != '-') {
        try ctx.err.print("unknown command \"{s}\" for \"{s}\"\n\n", .{ r.rest[0], help_path });
        try cli.writeHelp(ctx.err, r.path);
        return 1;
    }
    if (cmd.run == null) {
        cli.writeHelp(ctx.out, r.path) catch {};
        return if (r.rest.len == 0) 0 else 1;
    }

    const args = cli.parse(ctx.alloc, cmd, r.rest, ctx.err) catch |e| switch (e) {
        error.Help => {
            try cli.writeHelp(ctx.out, r.path);
            return 0;
        },
        error.Usage => {
            try ctx.err.print("\nRun '{s} --help' for usage.\n", .{help_path});
            return 1;
        },
        else => |x| return x,
    };
    return cmd.run.?(ctx, &args) catch |e| switch (e) {
        error.Usage => {
            try ctx.err.print("Run '{s} --help' for usage.\n", .{help_path});
            return 1;
        },
        else => |x| return x,
    };
}

fn helpPath(ctx: *Ctx, path: []const *const cli.Command) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (path) |c| try names.append(ctx.alloc, c.name);
    return std.mem.join(ctx.alloc, " ", names.items);
}
