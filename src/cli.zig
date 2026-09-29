const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Ctx = @import("Ctx.zig");

pub const Flag = struct {
    long: []const u8,
    short: ?u8 = null,
    /// Name of the value in help output; null for a boolean flag.
    value: ?[]const u8 = null,
    help: []const u8,
};

pub const RunFn = *const fn (*Ctx, *const Args) anyerror!u8;

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    /// Positional part of the usage line, e.g. "[<number>]".
    usage: []const u8 = "",
    flags: []const Flag = &.{},
    subs: []const Command = &.{},
    run: ?RunFn = null,
    min_args: usize = 0,
    max_args: usize = 0,
    /// Accepts `-- <args>` passed through verbatim (e.g. to git).
    passthrough: bool = false,
    /// Output goes through the pager on a terminal.
    pages: bool = false,
};

pub const repo_flag: Flag = .{ .long = "repo", .short = 'R', .value = "[HOST/]OWNER/REPO", .help = "Select another repository" };
pub const json_flag: Flag = .{ .long = "json", .help = "Print the API objects as JSON" };
pub const web_flag: Flag = .{ .long = "web", .short = 'w', .help = "Open in the browser" };
pub const limit_flag: Flag = .{ .long = "limit", .short = 'L', .value = "int", .help = "Maximum number of items to fetch (default 30)" };

pub const Args = struct {
    positionals: []const []const u8,
    passthrough: []const []const u8 = &.{},
    names: []const []const u8,
    values: []const []const u8,
    /// Where to explain a bad flag value; set by `parse`.
    err: ?*Writer = null,

    pub fn has(a: *const Args, long: []const u8) bool {
        for (a.names) |n| if (std.mem.eql(u8, n, long)) return true;
        return false;
    }

    /// Last value given for a flag.
    pub fn get(a: *const Args, long: []const u8) ?[]const u8 {
        var i = a.names.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, a.names[i], long)) return a.values[i];
        }
        return null;
    }

    /// Every value given for a repeatable flag, with comma-separated values split.
    pub fn all(a: *const Args, alloc: Allocator, long: []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (a.names, a.values) |n, v| {
            if (!std.mem.eql(u8, n, long)) continue;
            var it = std.mem.tokenizeScalar(u8, v, ',');
            while (it.next()) |part| try list.append(alloc, std.mem.trim(u8, part, " "));
        }
        return list.toOwnedSlice(alloc);
    }

    /// A flag's number; `--limit` must be at least 1.
    pub fn int(a: *const Args, long: []const u8, default: u32) !u32 {
        const v = a.get(long) orelse return default;
        const min: u32 = if (std.mem.eql(u8, long, "limit")) 1 else 0;
        const n = std.fmt.parseInt(u32, v, 10) catch null;
        if (n == null or n.? < min) {
            if (a.err) |w| w.print("--{s} takes a whole number{s}, got \"{s}\"\n", .{ long, if (min > 0) " greater than 0" else "", v }) catch {};
            return error.Usage;
        }
        return n.?;
    }

    /// A copy with one more flag set.
    pub fn with(a: *const Args, alloc: Allocator, long: []const u8, value: []const u8) !Args {
        var b = a.*;
        b.names = try std.mem.concat(alloc, []const u8, &.{ a.names, &.{long} });
        b.values = try std.mem.concat(alloc, []const u8, &.{ a.values, &.{value} });
        return b;
    }

    pub fn arg(a: *const Args, i: usize) ?[]const u8 {
        return if (i < a.positionals.len) a.positionals[i] else null;
    }
};

pub const Resolved = struct {
    path: []const *const Command,
    rest: []const []const u8,
};

/// Walks the command tree along the leading words of `argv` (without argv[0]).
pub fn resolve(alloc: Allocator, root: *const Command, argv: []const []const u8) !Resolved {
    var path: std.ArrayList(*const Command) = .empty;
    try path.append(alloc, root);
    var cmd = root;
    var i: usize = 0;
    outer: while (i < argv.len) : (i += 1) {
        for (cmd.subs) |*sub| {
            if (std.mem.eql(u8, sub.name, argv[i])) {
                cmd = sub;
                try path.append(alloc, cmd);
                continue :outer;
            }
        }
        break;
    }
    return .{ .path = try path.toOwnedSlice(alloc), .rest = argv[i..] };
}

pub const ParseError = error{ Usage, Help, OutOfMemory };

/// Parses flags and positionals for `cmd`. On a usage error, the reason is
/// written to `err` and `error.Usage` returned.
pub fn parse(alloc: Allocator, cmd: *const Command, argv: []const []const u8, err: *Writer) ParseError!Args {
    var positionals: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    var passthrough: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            if (!cmd.passthrough) {
                try positionals.appendSlice(alloc, argv[i + 1 ..]);
            } else {
                passthrough = argv[i + 1 ..];
            }
            break;
        }
        const h_is_flag = for (cmd.flags) |f| {
            if (f.short == 'h') break true;
        } else false;
        if ((std.mem.eql(u8, a, "-h") and !h_is_flag) or std.mem.eql(u8, a, "--help")) return error.Help;

        if (std.mem.startsWith(u8, a, "--") and a.len > 2) {
            const body = a[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const flag = findLong(cmd, name) orelse return usage(err, "unknown flag: --{s}", .{name});
            if (flag.value == null) {
                if (eq != null) return usage(err, "flag --{s} takes no value", .{name});
                try names.append(alloc, flag.long);
                try values.append(alloc, "");
            } else if (eq) |e| {
                try names.append(alloc, flag.long);
                try values.append(alloc, body[e + 1 ..]);
            } else {
                if (i + 1 >= argv.len) return usage(err, "flag needs an argument: --{s}", .{name});
                i += 1;
                try names.append(alloc, flag.long);
                try values.append(alloc, argv[i]);
            }
            continue;
        }

        if (a.len > 1 and a[0] == '-' and !isNumber(a)) {
            var j: usize = 1;
            while (j < a.len) : (j += 1) {
                const flag = findShort(cmd, a[j]) orelse return usage(err, "unknown shorthand flag: '{c}' in {s}", .{ a[j], a });
                try names.append(alloc, flag.long);
                if (flag.value == null) {
                    try values.append(alloc, "");
                    continue;
                }
                if (j + 1 < a.len) {
                    try values.append(alloc, a[j + 1 ..]);
                } else {
                    if (i + 1 >= argv.len) return usage(err, "flag needs an argument: -{c}", .{a[j]});
                    i += 1;
                    try values.append(alloc, argv[i]);
                }
                break;
            }
            continue;
        }

        try positionals.append(alloc, a);
    }

    if (positionals.items.len < cmd.min_args)
        return usage(err, "not enough arguments: {s} {s}", .{ cmd.name, cmd.usage });
    if (positionals.items.len > cmd.max_args)
        return usage(err, "unexpected argument: {s}", .{positionals.items[cmd.max_args]});

    return .{
        .positionals = try positionals.toOwnedSlice(alloc),
        .passthrough = passthrough,
        .names = try names.toOwnedSlice(alloc),
        .values = try values.toOwnedSlice(alloc),
        .err = err,
    };
}

fn isNumber(a: []const u8) bool {
    _ = std.fmt.parseInt(i64, a, 10) catch return false;
    return true;
}

pub const jq_flag: Flag = .{ .long = "jq", .short = 'q', .value = "expression", .help = "Filter the JSON with a jq expression (needs jq)" };
pub const template_flag: Flag = .{ .long = "template", .short = 't', .value = "string", .help = "Format the JSON with a Go-style template" };
pub const yes_flag: Flag = .{ .long = "yes", .short = 'y', .help = "Do not ask for confirmation" };

/// Flags a command gets without declaring them: `--jq` and `--template`
/// come with `--json`.
pub fn implicitFlags(cmd: *const Command) []const Flag {
    for (cmd.flags) |f| if (std.mem.eql(u8, f.long, "json")) return &.{ jq_flag, template_flag };
    return &.{};
}

fn findLong(cmd: *const Command, name: []const u8) ?Flag {
    for (cmd.flags) |f| if (std.mem.eql(u8, f.long, name)) return f;
    for (implicitFlags(cmd)) |f| if (std.mem.eql(u8, f.long, name)) return f;
    return null;
}

fn findShort(cmd: *const Command, c: u8) ?Flag {
    for (cmd.flags) |f| if (f.short == c) return f;
    for (implicitFlags(cmd)) |f| if (f.short == c) return f;
    return null;
}

fn usage(err: *Writer, comptime fmt: []const u8, args: anytype) ParseError {
    err.print(fmt ++ "\n", args) catch {};
    return error.Usage;
}

pub fn writeHelp(w: *Writer, path: []const *const Command) Writer.Error!void {
    const cmd = path[path.len - 1];
    try w.print("{s}\n\nUSAGE\n  ", .{cmd.summary});
    for (path, 0..) |c, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(c.name);
    }
    if (cmd.subs.len > 0) {
        try w.writeAll(" <command> [flags]\n");
        try w.writeAll("\nCOMMANDS\n");
        var width: usize = 0;
        for (cmd.subs) |s| width = @max(width, s.name.len);
        for (cmd.subs) |s| {
            try w.print("  {s}", .{s.name});
            try w.splatByteAll(' ', width - s.name.len + 3);
            try w.print("{s}\n", .{s.summary});
        }
    } else {
        if (cmd.usage.len > 0) try w.print(" {s}", .{cmd.usage});
        try w.writeAll(" [flags]\n");
    }

    try w.writeAll("\nFLAGS\n");
    var width: usize = "-h, --help".len;
    for ([_][]const Flag{ cmd.flags, implicitFlags(cmd) }) |group| for (group) |f| {
        width = @max(width, flagLabelLen(f));
    };
    for ([_][]const Flag{ cmd.flags, implicitFlags(cmd) }) |group| for (group) |f| {
        try w.writeAll("  ");
        if (f.short) |s| try w.print("-{c}, ", .{s}) else try w.writeAll("    ");
        try w.print("--{s}", .{f.long});
        if (f.value) |v| try w.print(" {s}", .{v});
        try w.splatByteAll(' ', width - flagLabelLen(f) + 3);
        try w.print("{s}\n", .{f.help});
    };
    const h_is_flag = for (cmd.flags) |f| {
        if (f.short == 'h') break true;
    } else false;
    try w.writeAll(if (h_is_flag) "      --help" else "  -h, --help");
    try w.splatByteAll(' ', width - "-h, --help".len + 3);
    try w.writeAll("Show help for this command\n");
}

fn flagLabelLen(f: Flag) usize {
    return 4 + 2 + f.long.len + if (f.value) |v| v.len + 1 else 0;
}

const testing = std.testing;

const test_cmd: Command = .{
    .name = "list",
    .summary = "List things",
    .usage = "[<owner>]",
    .max_args = 1,
    .flags = &.{
        .{ .long = "state", .short = 's', .value = "string", .help = "Filter by state" },
        .{ .long = "draft", .short = 'd', .help = "Draft" },
        .{ .long = "label", .short = 'l', .value = "name", .help = "Label" },
        limit_flag,
    },
};

fn testParse(arena: Allocator, argv: []const []const u8) !Args {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    return parse(arena, &test_cmd, argv, &w);
}

test "parse long, short, clustered and = flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try testParse(a, &.{ "--state=closed", "-dl", "bug", "-L5", "owner", "--label", "a,b" });
    try testing.expectEqualStrings("closed", p.get("state").?);
    try testing.expect(p.has("draft"));
    try testing.expectEqual(@as(u32, 5), try p.int("limit", 30));
    try testing.expectEqualStrings("owner", p.arg(0).?);
    const labels = try p.all(a, "label");
    try testing.expectEqual(@as(usize, 3), labels.len);
    try testing.expectEqualStrings("b", labels[2]);
}

test "parse rejects unknown flags and extra arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.Usage, testParse(a, &.{"--nope"}));
    try testing.expectError(error.Usage, testParse(a, &.{ "a", "b" }));
    try testing.expectError(error.Usage, testParse(a, &.{"--state"}));
    try testing.expectError(error.Help, testParse(a, &.{"-h"}));
}

test "negative numbers and -- stay positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try testParse(arena.allocator(), &.{ "--", "--state" });
    try testing.expectEqualStrings("--state", p.arg(0).?);
    try testing.expect(!p.has("state"));
}

test "resolve walks subcommands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root: Command = .{ .name = "smith", .summary = "", .subs = &.{.{ .name = "pr", .summary = "", .subs = &.{test_cmd} }} };
    const r = try resolve(arena.allocator(), &root, &.{ "pr", "list", "-s", "open" });
    try testing.expectEqual(@as(usize, 3), r.path.len);
    try testing.expectEqualStrings("list", r.path[2].name);
    try testing.expectEqual(@as(usize, 2), r.rest.len);
}

test "help lists flags" {
    var buf: [2048]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const root: Command = .{ .name = "smith", .summary = "" };
    try writeHelp(&w, &.{ &root, &test_cmd });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "smith list [<owner>] [flags]") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "-s, --state string") != null);
}
