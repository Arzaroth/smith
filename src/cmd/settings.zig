//! `config` and `alias`, over `settings.zig`.
const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const config = @import("../config.zig");
const settings = @import("../settings.zig");
const term = @import("../term.zig");

pub const config_command: cli.Command = .{
    .name = "config",
    .summary = "Read and change smith's preferences: editor, browser, git_protocol.",
    .subs = &.{
        .{ .name = "get", .summary = "Print a preference.", .usage = "<key>", .min_args = 1, .max_args = 1, .run = get },
        .{ .name = "set", .summary = "Change a preference.", .usage = "<key> <value>", .min_args = 2, .max_args = 2, .run = set },
        .{ .name = "unset", .summary = "Go back to the default for a preference.", .usage = "<key>", .min_args = 1, .max_args = 1, .run = unset },
        .{ .name = "list", .summary = "Print every preference.", .run = list },
    },
};

pub const alias_command: cli.Command = .{
    .name = "alias",
    .summary = "Make shortcuts for smith commands.",
    .subs = &.{
        .{
            .name = "set",
            .summary = "Create an alias: `smith alias set co 'pr checkout'`; $1… take arguments; a leading ! runs the rest with sh.",
            .usage = "<name> <expansion>",
            .min_args = 2,
            .max_args = 2,
            .flags = &.{
                .{ .long = "shell", .short = 's', .help = "Run the expansion with sh, like a leading !" },
                .{ .long = "clobber", .help = "Replace an existing alias of the same name" },
            },
            .run = aliasSet,
        },
        .{ .name = "list", .summary = "List aliases.", .run = aliasList },
        .{ .name = "delete", .summary = "Delete an alias.", .usage = "<name>", .min_args = 1, .max_args = 1, .run = aliasDelete },
    },
};

fn checkKey(ctx: *Ctx, key: []const u8) !void {
    for (settings.keys) |k| if (std.mem.eql(u8, k, key)) return;
    return ctx.fail("unknown key \"{s}\"; the keys are editor, browser and git_protocol", .{key});
}

fn value(s: settings.Settings, key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "editor")) return s.editor;
    if (std.mem.eql(u8, key, "browser")) return s.browser;
    if (s.git_protocol) |p| return @tagName(p);
    return null;
}

fn get(ctx: *Ctx, args: *const cli.Args) !u8 {
    const key = args.arg(0).?;
    try checkKey(ctx, key);
    const v = value(try settings.load(ctx), key) orelse return 1;
    try ctx.out.print("{s}\n", .{v});
    return 0;
}

fn set(ctx: *Ctx, args: *const cli.Args) !u8 {
    const key = args.arg(0).?;
    const v = args.arg(1).?;
    try checkKey(ctx, key);
    var s = try settings.load(ctx);
    if (std.mem.eql(u8, key, "editor")) s.editor = v else if (std.mem.eql(u8, key, "browser")) s.browser = v else {
        s.git_protocol = std.meta.stringToEnum(config.Protocol, v) orelse return ctx.fail("git_protocol must be ssh or https", .{});
    }
    try settings.save(ctx, s);
    return 0;
}

fn unset(ctx: *Ctx, args: *const cli.Args) !u8 {
    const key = args.arg(0).?;
    try checkKey(ctx, key);
    var s = try settings.load(ctx);
    if (std.mem.eql(u8, key, "editor")) s.editor = null else if (std.mem.eql(u8, key, "browser")) s.browser = null else s.git_protocol = null;
    try settings.save(ctx, s);
    return 0;
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    _ = args;
    const s = try settings.load(ctx);
    for (settings.keys) |k| try ctx.out.print("{s}={s}\n", .{ k, value(s, k) orelse "" });
    return 0;
}

fn aliasSet(ctx: *Ctx, args: *const cli.Args) !u8 {
    const name = args.arg(0).?;
    const expansion = if (args.has("shell") and !std.mem.startsWith(u8, args.arg(1).?, "!"))
        try std.fmt.allocPrint(ctx.alloc, "!{s}", .{args.arg(1).?})
    else
        args.arg(1).?;
    for (@import("../app.zig").root.subs) |c| if (std.mem.eql(u8, c.name, name))
        return ctx.fail("\"{s}\" is a smith command; pick another name", .{name});
    if (name.len == 0 or name[0] == '-' or std.mem.indexOfAny(u8, name, " \t") != null)
        return ctx.fail("invalid alias name \"{s}\"", .{name});
    if (std.mem.trim(u8, expansion, " \t\n!").len == 0) return ctx.fail("the expansion is empty", .{});
    if (expansion[0] != '!') {
        const words = settings.split(ctx.alloc, expansion) catch |e| switch (e) {
            error.UnterminatedQuote => return ctx.fail("the expansion has an unterminated quote", .{}),
            else => |x| return x,
        };
        if (words.len == 0) return ctx.fail("the expansion is empty", .{});
        const known = for (@import("../app.zig").root.subs) |c| {
            if (std.mem.eql(u8, c.name, words[0])) break true;
        } else false;
        if (!known) return ctx.fail("\"{s}\" is not a smith command; prefix the expansion with ! to run it with sh", .{words[0]});
    }
    var s = try settings.load(ctx);
    var aliases: std.ArrayList(settings.Alias) = .empty;
    var replaced = false;
    for (s.aliases) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            if (!args.has("clobber")) return ctx.fail("alias {s} already exists; pass --clobber to replace it", .{name});
            try aliases.append(ctx.alloc, .{ .name = name, .expansion = expansion });
            replaced = true;
        } else try aliases.append(ctx.alloc, a);
    }
    if (!replaced) try aliases.append(ctx.alloc, .{ .name = name, .expansion = expansion });
    s.aliases = aliases.items;
    try settings.save(ctx, s);
    try ctx.err.print("✓ {s} alias {s} for {s}\n", .{ if (replaced) "Changed" else "Added", name, expansion });
    return 0;
}

fn aliasList(ctx: *Ctx, args: *const cli.Args) !u8 {
    _ = args;
    const s = try settings.load(ctx);
    if (s.aliases.len == 0) {
        try ctx.err.writeAll("No aliases; add one with `smith alias set`\n");
        return 0;
    }
    var table: term.Table = .{};
    for (s.aliases) |a| try table.add(ctx.alloc, &.{ .{ .text = try std.fmt.allocPrint(ctx.alloc, "{s}:", .{a.name}), .color = .bold }, .{ .text = a.expansion } });
    try table.write(ctx);
    return 0;
}

fn aliasDelete(ctx: *Ctx, args: *const cli.Args) !u8 {
    const name = args.arg(0).?;
    var s = try settings.load(ctx);
    var aliases: std.ArrayList(settings.Alias) = .empty;
    for (s.aliases) |a| if (!std.mem.eql(u8, a.name, name)) try aliases.append(ctx.alloc, a);
    if (aliases.items.len == s.aliases.len) return ctx.fail("no alias named {s}", .{name});
    s.aliases = aliases.items;
    try settings.save(ctx, s);
    try ctx.err.print("✓ Deleted alias {s}\n", .{name});
    return 0;
}
