//! The command tree and dispatch, separate from process setup so tests can
//! drive a whole invocation.
const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const Ctx = @import("Ctx.zig");
const settings = @import("settings.zig");

pub const version = build_options.version;

pub const root: cli.Command = .{
    .name = "smith",
    .summary = "Work with Forgejo from the command line.",
    .flags = &.{.{ .long = "version", .short = 'V', .help = "Show the version" }},
    .subs = &.{
        @import("cmd/auth.zig").command,
        @import("cmd/repo.zig").command,
        @import("cmd/issue.zig").command,
        @import("cmd/pr.zig").command,
        @import("cmd/run.zig").command,
        @import("cmd/release.zig").command,
        @import("cmd/label.zig").command,
        @import("cmd/milestone.zig").command,
        @import("cmd/workflow.zig").command,
        @import("cmd/secret.zig").secret_command,
        @import("cmd/secret.zig").variable_command,
        @import("cmd/search.zig").command,
        @import("cmd/status.zig").command,
        @import("cmd/notification.zig").command,
        @import("cmd/key.zig").ssh_command,
        @import("cmd/key.zig").gpg_command,
        @import("cmd/key.zig").org_command,
        @import("cmd/settings.zig").alias_command,
        @import("cmd/settings.zig").config_command,
        @import("cmd/api.zig").command,
        @import("cmd/browse.zig").command,
        @import("cmd/completion.zig").command,
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
        error.AuthRequired => 4,
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

fn dispatch(ctx: *Ctx, argv_in: []const []const u8) !u8 {
    const prefs = try settings.load(ctx);
    ctx.editor = prefs.editor;
    ctx.browser = prefs.browser;
    var argv = argv_in;
    if (argv.len > 0 and argv[0].len > 0 and argv[0][0] != '-' and !isCommand(argv[0])) {
        if (prefs.alias(argv[0])) |a| {
            if (a.expansion[0] == '!') return shellAlias(ctx, a.expansion[1..], argv[1..]);
            argv = try settings.expand(ctx.alloc, a.expansion, argv[1..]);
        }
    }
    const r = try cli.resolve(ctx.alloc, &root, argv);
    const cmd = r.path[r.path.len - 1];
    const help_path = try helpPath(ctx, r.path);

    if (cmd.subs.len > 0 and r.rest.len > 0 and r.rest[0].len > 0 and r.rest[0][0] != '-') {
        try ctx.err.print("unknown command \"{s}\" for \"{s}\"\n\n", .{ r.rest[0], help_path });
        try cli.writeHelp(ctx.err, r.path);
        return 1;
    }
    if (cmd.run == null) {
        const asked = r.rest.len == 0 or std.mem.eql(u8, r.rest[0], "-h") or std.mem.eql(u8, r.rest[0], "--help");
        try cli.writeHelp(if (asked) ctx.out else ctx.err, r.path);
        return if (asked) 0 else 1;
    }

    var args = cli.parse(ctx.alloc, cmd, r.rest, ctx.err) catch |e| switch (e) {
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
    ctx.jq = args.get("jq");
    ctx.template = args.get("template");
    if ((ctx.jq != null or ctx.template != null) and !args.has("json")) args = try args.with(ctx.alloc, "json", "");
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

fn isCommand(name: []const u8) bool {
    for (root.subs) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

/// Runs a `!` alias with sh, its arguments as $1, $2…
fn shellAlias(ctx: *Ctx, script: []const u8, args: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.alloc, &.{ "sh", "-c", script, "smith-alias" });
    try argv.appendSlice(ctx.alloc, args);
    try ctx.out.flush();
    try ctx.err.flush();
    var child = std.process.spawn(ctx.io, .{ .argv = argv.items, .environ_map = ctx.env }) catch |e|
        return ctx.fail("cannot run sh: {t}", .{e});
    const term = try child.wait(ctx.io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}
