//! `config` and `alias`, over `settings.zig`.
const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const config = @import("../config.zig");
const settings = @import("../settings.zig");
const term = @import("../term.zig");

const host_flag: cli.Flag = .{ .long = "host", .short = 'h', .value = "host", .help = "A logged-in host's own setting (git_protocol only)" };

pub const config_command: cli.Command = .{
    .name = "config",
    .summary = "Read and change smith's preferences: git_protocol (ssh or https), editor, browser, pager, prompt (enabled or disabled).",
    .subs = &.{
        .{ .name = "get", .summary = "Print a preference, or its default.", .usage = "<key>", .min_args = 1, .max_args = 1, .flags = &.{host_flag}, .run = get },
        .{ .name = "set", .summary = "Change a preference.", .usage = "<key> <value>", .min_args = 2, .max_args = 2, .flags = &.{host_flag}, .run = set },
        .{ .name = "unset", .summary = "Go back to the default for a preference.", .usage = "<key>", .min_args = 1, .max_args = 1, .run = unset },
        .{ .name = "list", .summary = "Print every preference.", .flags = &.{host_flag}, .run = list },
    },
};

pub const alias_command: cli.Command = .{
    .name = "alias",
    .summary = "Make shortcuts for smith commands.",
    .subs = &.{
        .{
            .name = "set",
            .summary = "Create an alias: `smith alias set co 'pr checkout'`; $1… take arguments; a leading ! runs the rest with sh; - reads the expansion from standard input.",
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
        .{ .name = "delete", .summary = "Delete an alias, or all of them.", .usage = "[<name>]", .max_args = 1, .flags = &.{.{ .long = "all", .help = "Delete every alias" }}, .run = aliasDelete },
        .{
            .name = "import",
            .summary = "Add aliases from a YAML file of `name: expansion` lines, as gh writes them (- or nothing for standard input).",
            .usage = "[<filename> | -]",
            .max_args = 1,
            .flags = &.{.{ .long = "clobber", .help = "Replace existing aliases of the same names" }},
            .run = aliasImport,
        },
    },
};

const Key = struct {
    name: []const u8,
    default: []const u8 = "",
    choices: []const []const u8 = &.{},
};

const keys = [_]Key{
    .{ .name = "git_protocol", .default = "ssh", .choices = &.{ "ssh", "https" } },
    .{ .name = "editor" },
    .{ .name = "browser" },
    .{ .name = "pager" },
    .{ .name = "prompt", .default = "enabled", .choices = &.{ "enabled", "disabled" } },
};

fn findKey(ctx: *Ctx, name: []const u8, per_host: bool) !Key {
    for (keys) |k| if (std.mem.eql(u8, k.name, name)) {
        if (per_host and !std.mem.eql(u8, name, "git_protocol")) return ctx.fail("only git_protocol can be set per host", .{});
        return k;
    };
    return ctx.fail("unknown key \"{s}\"; the keys are git_protocol, editor, browser, pager and prompt", .{name});
}

fn value(s: settings.Settings, key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "editor")) return s.editor;
    if (std.mem.eql(u8, key, "browser")) return s.browser;
    if (std.mem.eql(u8, key, "pager")) return s.pager;
    if (std.mem.eql(u8, key, "prompt")) return if (s.prompt) |p| @tagName(p) else null;
    return if (s.git_protocol) |p| @tagName(p) else null;
}

/// The accounts of `-h HOST`, which must have logged in.
fn hostIndexes(ctx: *Ctx, cfg: config.Config, name: []const u8) ![]const usize {
    var found: std.ArrayList(usize) = .empty;
    for (cfg.hosts, 0..) |h, i| if (std.ascii.eqlIgnoreCase(h.name, name)) try found.append(ctx.alloc, i);
    if (found.items.len == 0) return ctx.fail("not logged in to {s}", .{name});
    return found.items;
}

fn get(ctx: *Ctx, args: *const cli.Args) !u8 {
    const key = try findKey(ctx, args.arg(0).?, false);
    if (args.get("host")) |name| if (std.mem.eql(u8, key.name, "git_protocol")) {
        const cfg = try config.load(ctx);
        const i = (try hostIndexes(ctx, cfg, name))[0];
        try ctx.out.print("{t}\n", .{cfg.hosts[i].git_protocol});
        return 0;
    };
    try ctx.out.print("{s}\n", .{value(try settings.load(ctx), key.name) orelse key.default});
    return 0;
}

fn set(ctx: *Ctx, args: *const cli.Args) !u8 {
    const key = try findKey(ctx, args.arg(0).?, args.get("host") != null);
    const v = args.arg(1).?;
    if (key.choices.len > 0) for (key.choices) |c| {
        if (std.mem.eql(u8, c, v)) break;
    } else return ctx.fail("{s} must be {s} or {s}", .{ key.name, key.choices[0], key.choices[1] });
    if (args.get("host")) |name| {
        var cfg = try config.load(ctx);
        const hosts = try ctx.alloc.dupe(config.Host, cfg.hosts);
        for (try hostIndexes(ctx, cfg, name)) |i| hosts[i].git_protocol = std.meta.stringToEnum(config.Protocol, v).?;
        cfg.hosts = hosts;
        try config.save(ctx, cfg);
        return 0;
    }
    var s = try settings.load(ctx);
    if (std.mem.eql(u8, key.name, "editor")) {
        s.editor = v;
    } else if (std.mem.eql(u8, key.name, "browser")) {
        s.browser = v;
    } else if (std.mem.eql(u8, key.name, "pager")) {
        s.pager = v;
    } else if (std.mem.eql(u8, key.name, "prompt")) {
        s.prompt = std.meta.stringToEnum(settings.Prompt, v).?;
    } else s.git_protocol = std.meta.stringToEnum(config.Protocol, v).?;
    try settings.save(ctx, s);
    return 0;
}

fn unset(ctx: *Ctx, args: *const cli.Args) !u8 {
    const key = try findKey(ctx, args.arg(0).?, false);
    var s = try settings.load(ctx);
    if (std.mem.eql(u8, key.name, "editor")) {
        s.editor = null;
    } else if (std.mem.eql(u8, key.name, "browser")) {
        s.browser = null;
    } else if (std.mem.eql(u8, key.name, "pager")) {
        s.pager = null;
    } else if (std.mem.eql(u8, key.name, "prompt")) {
        s.prompt = null;
    } else s.git_protocol = null;
    try settings.save(ctx, s);
    return 0;
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    if (args.get("host")) |name| {
        const cfg = try config.load(ctx);
        try ctx.out.print("git_protocol={t}\n", .{cfg.hosts[(try hostIndexes(ctx, cfg, name))[0]].git_protocol});
        return 0;
    }
    const s = try settings.load(ctx);
    for (keys) |k| try ctx.out.print("{s}={s}\n", .{ k.name, value(s, k.name) orelse k.default });
    return 0;
}

fn aliasSet(ctx: *Ctx, args: *const cli.Args) !u8 {
    const name = args.arg(0).?;
    var expansion = args.arg(1).?;
    if (std.mem.eql(u8, expansion, "-")) expansion = std.mem.trimEnd(u8, try ctx.readStdin(), "\r\n");
    if (args.has("shell") and !std.mem.startsWith(u8, expansion, "!"))
        expansion = try std.fmt.allocPrint(ctx.alloc, "!{s}", .{expansion});
    try checkAlias(ctx, name, expansion);
    var s = try settings.load(ctx);
    const replaced = try putAlias(ctx, &s, name, expansion, args.has("clobber"));
    try settings.save(ctx, s);
    try ctx.err.print("✓ {s} alias {s} for {s}\n", .{ if (replaced) "Changed" else "Added", name, expansion });
    return 0;
}

fn checkAlias(ctx: *Ctx, name: []const u8, expansion: []const u8) !void {
    for (@import("../app.zig").root.subs) |c| if (std.mem.eql(u8, c.name, name))
        return ctx.fail("\"{s}\" is a smith command; pick another name", .{name});
    if (name.len == 0 or name[0] == '-' or std.mem.indexOfAny(u8, name, " \t") != null)
        return ctx.fail("invalid alias name \"{s}\"", .{name});
    if (std.mem.trim(u8, expansion, " \t\n!").len == 0) return ctx.fail("the expansion of {s} is empty", .{name});
    if (expansion[0] == '!') return;
    const words = settings.split(ctx.alloc, expansion) catch |e| switch (e) {
        error.UnterminatedQuote => return ctx.fail("the expansion of {s} has an unterminated quote", .{name}),
        else => |x| return x,
    };
    if (words.len == 0) return ctx.fail("the expansion of {s} is empty", .{name});
    for (@import("../app.zig").root.subs) |c| if (std.mem.eql(u8, c.name, words[0])) return;
    return ctx.fail("\"{s}\" is not a smith command; prefix the expansion with ! to run it with sh", .{words[0]});
}

/// Adds or, with `clobber`, replaces an alias; true when it replaced one.
fn putAlias(ctx: *Ctx, s: *settings.Settings, name: []const u8, expansion: []const u8, clobber: bool) !bool {
    var aliases: std.ArrayList(settings.Alias) = .empty;
    var replaced = false;
    for (s.aliases) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            if (!clobber) return ctx.fail("alias {s} already exists; pass --clobber to replace it", .{name});
            try aliases.append(ctx.alloc, .{ .name = name, .expansion = expansion });
            replaced = true;
        } else try aliases.append(ctx.alloc, a);
    }
    if (!replaced) try aliases.append(ctx.alloc, .{ .name = name, .expansion = expansion });
    s.aliases = aliases.items;
    return replaced;
}

fn aliasImport(ctx: *Ctx, args: *const cli.Args) !u8 {
    const path = args.arg(0) orelse "-";
    const text = if (std.mem.eql(u8, path, "-"))
        try ctx.readStdin()
    else
        std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(1024 * 1024)) catch |e|
            return ctx.fail("cannot read {s}: {t}", .{ path, e });
    const entries = settings.parseAliasFile(ctx.alloc, text) catch |e| switch (e) {
        error.InvalidAliasFile => return ctx.fail("{s} is not a YAML map of alias names to expansions", .{path}),
        else => |x| return x,
    };
    for (entries) |a| try checkAlias(ctx, a.name, a.expansion);
    var s = try settings.load(ctx);
    for (entries) |a| {
        const replaced = try putAlias(ctx, &s, a.name, a.expansion, args.has("clobber"));
        try ctx.err.print("✓ {s} alias {s} for {s}\n", .{ if (replaced) "Changed" else "Added", a.name, a.expansion });
    }
    try settings.save(ctx, s);
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
    var s = try settings.load(ctx);
    if (args.has("all")) {
        if (args.arg(0) != null) return ctx.fail("give an alias name or --all, not both", .{});
        const n = s.aliases.len;
        s.aliases = &.{};
        try settings.save(ctx, s);
        try ctx.err.print("✓ Deleted {d} aliases\n", .{n});
        return 0;
    }
    const name = args.arg(0) orelse return ctx.fail("give an alias name, or --all", .{});
    var aliases: std.ArrayList(settings.Alias) = .empty;
    for (s.aliases) |a| if (!std.mem.eql(u8, a.name, name)) try aliases.append(ctx.alloc, a);
    if (aliases.items.len == s.aliases.len) return ctx.fail("no alias named {s}", .{name});
    s.aliases = aliases.items;
    try settings.save(ctx, s);
    try ctx.err.print("✓ Deleted alias {s}\n", .{name});
    return 0;
}
