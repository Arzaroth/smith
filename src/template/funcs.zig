//! The functions a template can call.
const std = @import("std");
const Value = std.json.Value;
const template = @import("../template.zig");
const Error = template.Error;
const term = @import("../term.zig");
const exec = @import("exec.zig");
const Exec = exec.Exec;
const Arg = @import("parse.zig").Arg;

pub const Id = enum {
    len,
    join,
    timeago,
};

pub fn lookup(name: []const u8) ?Id {
    return std.meta.stringToEnum(Id, name);
}

pub const Arity = struct { min: usize, max: ?usize };

pub fn arity(id: Id) Arity {
    return switch (id) {
        .len, .timeago => .{ .min = 1, .max = 1 },
        .join => .{ .min = 2, .max = 2 },
    };
}

/// Calls `id` with `args`, then the value piped in, if any.
pub fn call(e: *Exec, id: Id, pos: usize, args: []const Arg, dot: Value, piped: ?Value) Error!Value {
    const n = args.len + @intFromBool(piped != null);
    const v = try e.alloc.alloc(Value, n);
    for (args, 0..) |a, i| v[i] = try e.arg(a, dot);
    if (piped) |p| v[n - 1] = p;
    return switch (id) {
        .len => .{ .integer = switch (v[0]) {
            .array => |a| @intCast(a.items.len),
            .object => |o| @intCast(o.count()),
            .string => |s| @intCast(s.len),
            .null => 0,
            else => return e.fail(pos, "error calling len: len of type {s}", .{typeName(v[0])}),
        } },
        .join => join(e, v[0], v[1]),
        .timeago => if (v[0] == .string) .{ .string = term.ago(e.alloc, e.opts.now, v[0].string) catch return error.OutOfMemory } else v[0],
    };
}

/// Go's name for the type a JSON value decodes to.
pub fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "<nil>",
        .bool => "bool",
        .integer => "int",
        .float, .number_string => "float64",
        .string => "string",
        .array => "[]interface {}",
        .object => "map[string]interface {}",
    };
}

/// `v` as text, the way an action prints it.
pub fn text(e: *Exec, v: Value) Error![]const u8 {
    if (v == .string) return v.string;
    var out: std.Io.Writer.Allocating = .init(e.alloc);
    try exec.write(&out.writer, v);
    return out.written();
}

fn join(e: *Exec, sep: Value, list: Value) Error!Value {
    const s = try text(e, sep);
    var out: std.Io.Writer.Allocating = .init(e.alloc);
    if (list == .array) for (list.array.items, 0..) |item, i| {
        if (i > 0) try out.writer.writeAll(s);
        try exec.write(&out.writer, item);
    };
    return .{ .string = out.written() };
}
