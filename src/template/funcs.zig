//! The functions a template can call: Go's builtins and gh's helpers.
const std = @import("std");
const Value = std.json.Value;
const template = @import("../template.zig");
const Error = template.Error;
const term = @import("../term.zig");
const exec = @import("exec.zig");
const Exec = exec.Exec;
const truthy = exec.truthy;
const Arg = @import("parse.zig").Arg;
const format = @import("format.zig");
const typeName = format.typeName;

pub const Id = enum {
    @"and",
    @"or",
    not,
    len,
    index,
    slice,
    print,
    printf,
    println,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    contains,
    hasPrefix,
    hasSuffix,
    join,
    pluck,
    timeago,
    timefmt,
    truncate,
    color,
    autocolor,
    hyperlink,
    tablerow,
    tablerender,
};

pub fn lookup(name: []const u8) ?Id {
    return std.meta.stringToEnum(Id, name);
}

pub const Arity = struct { min: usize, max: ?usize };

pub fn arity(id: Id) Arity {
    return switch (id) {
        .@"and", .@"or", .index => .{ .min = 1, .max = null },
        .not, .len, .timeago => .{ .min = 1, .max = 1 },
        .slice => .{ .min = 1, .max = 4 },
        .print, .println, .tablerow => .{ .min = 0, .max = null },
        .printf => .{ .min = 1, .max = null },
        .eq => .{ .min = 2, .max = null },
        .tablerender => .{ .min = 0, .max = 0 },
        else => .{ .min = 2, .max = 2 },
    };
}

/// Calls `id` with `args`, then the value piped in, if any.
pub fn call(e: *Exec, id: Id, pos: usize, args: []const Arg, dot: Value, piped: ?Value) Error!Value {
    if (id == .@"and" or id == .@"or") {
        var v: Value = .null;
        for (args) |a| {
            v = try e.arg(a, dot);
            if (truthy(v) == (id == .@"or")) return v;
        }
        return piped orelse v;
    }
    const n = args.len + @intFromBool(piped != null);
    const v = try e.alloc.alloc(Value, n);
    for (args, 0..) |a, i| v[i] = try e.arg(a, dot);
    if (piped) |p| v[n - 1] = p;
    const c: Call = .{ .e = e, .id = id, .pos = pos };
    return switch (id) {
        .@"and", .@"or" => unreachable,
        .not => .{ .bool = !truthy(v[0]) },
        .len => .{ .integer = switch (v[0]) {
            .array => |a| @intCast(a.items.len),
            .object => |o| @intCast(o.count()),
            .string => |s| @intCast(s.len),
            .null => 0,
            else => return c.fail("len of type {s}", .{typeName(v[0])}),
        } },
        .index => c.index(v[0], v[1..]),
        .slice => c.slice(v[0], v[1..]),
        .print, .println => {
            var out: std.Io.Writer.Allocating = .init(e.alloc);
            for (v, 0..) |x, i| {
                if (i > 0 and (id == .println or (x != .string and v[i - 1] != .string))) try out.writer.writeByte(' ');
                try exec.write(&out.writer, x);
            }
            if (id == .println) try out.writer.writeByte('\n');
            return .{ .string = out.written() };
        },
        .printf => {
            if (v[0] != .string) return c.fail("format must be a string, not {s}", .{typeName(v[0])});
            var out: std.Io.Writer.Allocating = .init(e.alloc);
            try format.printf(e.alloc, &out.writer, v[0].string, v[1..]);
            return .{ .string = out.written() };
        },
        .eq, .ne => {
            for (v[1..]) |x| if (try c.equal(v[0], x)) return .{ .bool = id == .eq };
            return .{ .bool = id == .ne };
        },
        .lt, .le, .gt, .ge => {
            const order = try c.compare(v[0], v[1]);
            return .{ .bool = switch (id) {
                .lt => order == .lt,
                .le => order != .gt,
                .gt => order == .gt,
                else => order != .lt,
            } };
        },
        .contains, .hasPrefix, .hasSuffix => {
            const needle = try text(e, v[0]);
            const s = try text(e, v[1]);
            return .{ .bool = switch (id) {
                .contains => std.mem.indexOf(u8, s, needle) != null,
                .hasPrefix => std.mem.startsWith(u8, s, needle),
                else => std.mem.endsWith(u8, s, needle),
            } };
        },
        .join => {
            const sep = try text(e, v[0]);
            var out: std.Io.Writer.Allocating = .init(e.alloc);
            if (v[1] == .array) for (v[1].array.items, 0..) |item, i| {
                if (i > 0) try out.writer.writeAll(sep);
                try exec.write(&out.writer, item);
            };
            return .{ .string = out.written() };
        },
        .pluck => {
            const field = try text(e, v[0]);
            var out: std.json.Array = .init(e.alloc);
            switch (v[1]) {
                .array => |a| for (a.items) |item| if (item == .object) try out.append(item.object.get(field) orelse .null),
                .null => {},
                else => return c.fail("expected a list, got {s}", .{typeName(v[1])}),
            }
            return .{ .array = out };
        },
        .timeago => if (v[0] == .string) .{ .string = term.ago(e.alloc, e.opts.now, v[0].string) catch return error.OutOfMemory } else v[0],
        .timefmt => {
            if (v[1] == .null) return .{ .string = "" };
            const layout = try text(e, v[0]);
            const stamp = try text(e, v[1]);
            var out: std.Io.Writer.Allocating = .init(e.alloc);
            if (!try format.timefmt(&out.writer, layout, stamp)) return c.fail("cannot parse \"{s}\" as an RFC 3339 time", .{stamp});
            return .{ .string = out.written() };
        },
        .truncate => {
            const max = format.integer(v[0]) orelse return c.fail("length must be an integer, not {s}", .{typeName(v[0])});
            const s = try text(e, v[1]);
            const limit: usize = @intCast(@max(max, 0));
            if ((std.unicode.utf8CountCodepoints(s) catch s.len) <= limit) return .{ .string = s };
            if (limit < 4) return .{ .string = format.prefix(s, limit) };
            return .{ .string = try std.fmt.allocPrint(e.alloc, "{s}...", .{format.prefix(s, limit - 3)}) };
        },
        .color, .autocolor => {
            const spec = try text(e, v[0]);
            const s = try text(e, v[1]);
            const code = try format.style(e.alloc, spec) orelse return c.fail("unknown style \"{s}\"", .{spec});
            if (!e.opts.color or code.len == 0) return .{ .string = s };
            return .{ .string = try std.fmt.allocPrint(e.alloc, "{s}{s}\x1b[0m", .{ code, s }) };
        },
        .hyperlink => {
            const url = try text(e, v[0]);
            const label = try text(e, v[1]);
            const shown = if (label.len > 0) label else url;
            if (!e.opts.tty or !linkable(url)) return .{ .string = shown };
            return .{ .string = try std.fmt.allocPrint(e.alloc, "\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ url, shown }) };
        },
        .tablerow => {
            const row = try e.alloc.alloc([]const u8, n);
            for (v, row) |x, *cell| {
                const s = try e.alloc.dupe(u8, try text(e, x));
                for (s) |*ch| if (ch.* == '\t' or ch.* == '\n' or ch.* == '\r') {
                    ch.* = ' ';
                };
                cell.* = s;
            }
            try e.rows.append(e.alloc, row);
            return .{ .string = "" };
        },
        .tablerender => .{ .string = try table(e) },
    };
}

const Call = struct {
    e: *Exec,
    id: Id,
    pos: usize,

    fn fail(c: Call, comptime fmt: []const u8, args: anytype) Error {
        return c.e.fail(c.pos, "error calling {t}: " ++ fmt, .{c.id} ++ args);
    }

    fn index(c: Call, item: Value, keys: []const Value) Error!Value {
        var v = item;
        for (keys) |k| v = switch (v) {
            .array => |a| at: {
                const i = format.integer(k) orelse return c.fail("cannot index slice/array with type {s}", .{typeName(k)});
                if (i < 0 or i >= a.items.len) return c.fail("index out of range: {d}", .{i});
                break :at a.items[@intCast(i)];
            },
            .object => |o| if (k == .string) o.get(k.string) orelse .null else return c.fail("cannot index map with type {s}", .{typeName(k)}),
            .string => |s| at: {
                const i = format.integer(k) orelse return c.fail("cannot index string with type {s}", .{typeName(k)});
                if (i < 0 or i >= s.len) return c.fail("index out of range: {d}", .{i});
                break :at .{ .integer = s[@intCast(i)] };
            },
            .null => .null,
            else => return c.fail("can't index item of type {s}", .{typeName(v)}),
        };
        return v;
    }

    fn slice(c: Call, item: Value, bounds: []const Value) Error!Value {
        const len: usize = switch (item) {
            .array => |a| a.items.len,
            .string => |s| s.len,
            .null => return .null,
            else => return c.fail("can't slice item of type {s}", .{typeName(item)}),
        };
        if (item == .string and bounds.len == 3) return c.fail("cannot 3-index slice a string", .{});
        var idx: [3]usize = .{ 0, len, len };
        for (bounds, 0..) |b, i| {
            const n = format.integer(b) orelse return c.fail("cannot index slice/array with type {s}", .{typeName(b)});
            if (n < 0 or n > len) return c.fail("index out of range: {d}", .{n});
            idx[i] = @intCast(n);
        }
        if (idx[0] > idx[1] or idx[1] > idx[2]) return c.fail("invalid slice index: {d} > {d}", .{ @max(idx[0], idx[1]), @min(idx[1], idx[2]) });
        return switch (item) {
            .string => |s| .{ .string = s[idx[0]..idx[1]] },
            else => {
                var out: std.json.Array = .init(c.e.alloc);
                try out.appendSlice(item.array.items[idx[0]..idx[1]]);
                return .{ .array = out };
            },
        };
    }

    const Kind = enum { null, bool, number, string, other };

    fn kind(v: Value) Kind {
        return switch (v) {
            .null => .null,
            .bool => .bool,
            .integer, .float, .number_string => .number,
            .string => .string,
            .array, .object => .other,
        };
    }

    fn equal(c: Call, a: Value, b: Value) Error!bool {
        const ka = kind(a);
        const kb = kind(b);
        if (ka == .other) return c.fail("non-comparable type {s}", .{typeName(a)});
        if (kb == .other) return c.fail("non-comparable type {s}", .{typeName(b)});
        if (ka == .null or kb == .null) return ka == kb;
        if (ka != kb) return c.fail("incompatible types for comparison", .{});
        return switch (ka) {
            .bool => a.bool == b.bool,
            .string => std.mem.eql(u8, a.string, b.string),
            else => (try c.compare(a, b)) == .eq,
        };
    }

    fn compare(c: Call, a: Value, b: Value) Error!std.math.Order {
        const ka = kind(a);
        const kb = kind(b);
        if (ka != .number and ka != .string or kb != .number and kb != .string) return c.fail("invalid type for comparison", .{});
        if (ka != kb) return c.fail("incompatible types for comparison", .{});
        if (ka == .string) return std.mem.order(u8, a.string, b.string);
        if (a == .integer and b == .integer) return std.math.order(a.integer, b.integer);
        return std.math.order(format.float(a).?, format.float(b).?);
    }
};

/// `v` as text, the way an action prints it.
pub fn text(e: *Exec, v: Value) Error![]const u8 {
    if (v == .string) return v.string;
    var out: std.Io.Writer.Allocating = .init(e.alloc);
    try exec.write(&out.writer, v);
    return out.written();
}

/// The rows collected by `tablerow`, like smith's own tables: aligned on a
/// terminal, tab-separated in a pipe.
pub fn table(e: *Exec) Error![]const u8 {
    const rows = e.rows.items;
    e.rows = .empty;
    var out: std.Io.Writer.Allocating = .init(e.alloc);
    const w = &out.writer;
    var columns: usize = 0;
    for (rows) |row| columns = @max(columns, row.len);
    const widths = try e.alloc.alloc(usize, columns);
    @memset(widths, 0);
    for (rows) |row| for (row, 0..) |cell, j| {
        widths[j] = @max(widths[j], format.visibleWidth(cell));
    };
    for (rows) |row| {
        for (row, 0..) |cell, j| {
            if (j > 0) try w.writeAll(if (e.opts.tty) "  " else "\t");
            try w.writeAll(cell);
            if (e.opts.tty and j + 1 < columns) try w.splatByteAll(' ', widths[j] - format.visibleWidth(cell));
        }
        try w.writeByte('\n');
    }
    return out.written();
}

/// Links go only to http(s) URLs with nothing a terminal could misread.
fn linkable(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return false;
    for (url) |c| if (c <= 0x20 or c >= 0x7f) return false;
    return true;
}
