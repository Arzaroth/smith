//! Walks the node tree against a JSON value, writing the output.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const template = @import("../template.zig");
const Diagnostic = template.Diagnostic;
const Error = template.Error;
const Options = template.Options;
const parse = @import("parse.zig");
const Node = parse.Node;
const Pipe = parse.Pipe;
const Arg = parse.Arg;
const funcs = @import("funcs.zig");

pub const Exec = struct {
    alloc: Allocator,
    src: []const u8,
    w: *Writer,
    opts: Options,
    diag: *Diagnostic,
    vars: std.ArrayList(Var) = .empty,

    const Var = struct { name: []const u8, value: Value };

    pub fn run(e: *Exec, nodes: []const Node, data: Value) Error!void {
        try e.vars.append(e.alloc, .{ .name = "$", .value = data });
        try e.walk(nodes, data);
    }

    pub fn fail(e: *Exec, pos: usize, comptime fmt: []const u8, args: anytype) Error {
        return e.diag.failExec(e.alloc, e.src, pos, fmt, args);
    }

    fn walk(e: *Exec, nodes: []const Node, dot: Value) Error!void {
        for (nodes) |n| switch (n) {
            .text => |t| try e.w.writeAll(t),
            .action => |p| {
                const v = try e.pipe(p, dot);
                if (p.decl.len == 0) try write(e.w, v);
            },
            .@"if" => |c| {
                const mark = e.vars.items.len;
                defer e.vars.shrinkRetainingCapacity(mark);
                for (c.clauses) |clause| {
                    if (truthy(try e.pipe(clause.pipe, dot))) break try e.walk(clause.body, dot);
                } else try e.walk(c.otherwise, dot);
            },
            .range => |r| try e.range(r, dot),
        };
    }

    fn range(e: *Exec, r: parse.Range, dot: Value) Error!void {
        const v = try e.value(r.pipe, dot);
        const mark = e.vars.items.len;
        defer e.vars.shrinkRetainingCapacity(mark);
        switch (v) {
            .array => |a| {
                if (a.items.len == 0) return e.walk(r.otherwise, dot);
                for (a.items, 0..) |item, i| {
                    e.vars.shrinkRetainingCapacity(mark);
                    try e.declare(r.pipe, &.{ .{ .integer = @intCast(i) }, item });
                    try e.walk(r.body, item);
                }
            },
            .null => try e.walk(r.otherwise, dot),
            else => return e.fail(r.pipe.pos, "range can't iterate over {f}", .{fmtValue(v)}),
        }
    }

    /// Binds a range's variables: one gets the element, two the key and the element.
    fn declare(e: *Exec, p: Pipe, pair: *const [2]Value) Error!void {
        for (p.decl, pair[2 - p.decl.len ..]) |name, v| try e.bind(p, name, v);
    }

    fn bind(e: *Exec, p: Pipe, name: []const u8, v: Value) Error!void {
        if (!p.assign) return e.vars.append(e.alloc, .{ .name = name, .value = v });
        var i = e.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, e.vars.items[i].name, name)) {
                e.vars.items[i].value = v;
                return;
            }
        }
    }

    fn lookup(e: *Exec, name: []const u8) Value {
        var i = e.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, e.vars.items[i].name, name)) return e.vars.items[i].value;
        }
        return .null;
    }

    /// The value of a pipeline, its variables left unbound.
    fn value(e: *Exec, p: Pipe, dot: Value) Error!Value {
        var v: Value = .null;
        for (p.cmds, 0..) |c, i| {
            const head = c.args[0];
            v = if (head.term == .func)
                try funcs.call(e, head.term.func, head.pos, c.args[1..], dot, if (i > 0) v else null)
            else
                try e.arg(head, dot);
        }
        return v;
    }

    pub fn pipe(e: *Exec, p: Pipe, dot: Value) Error!Value {
        const v = try e.value(p, dot);
        for (p.decl) |name| try e.bind(p, name, v);
        return v;
    }

    pub fn arg(e: *Exec, a: Arg, dot: Value) Error!Value {
        var v: Value = switch (a.term) {
            .dot => dot,
            .variable => |name| e.lookup(name),
            .func => |id| try funcs.call(e, id, a.pos, &.{}, dot, null),
            .pipe => |p| try e.pipe(p.*, dot),
            .value => |v| v,
        };
        for (a.fields) |f| v = switch (v) {
            .object => |o| o.get(f) orelse .null,
            else => .null,
        };
        return v;
    }
};

pub fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |n| n != 0,
        .float => |f| f != 0,
        .string, .number_string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => |o| o.count() > 0,
    };
}

/// A value as an action prints it: strings raw, numbers as Go's %v would,
/// lists and objects as JSON, nothing for null.
pub fn write(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .null => {},
        .string, .number_string => |s| try w.writeAll(s),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try writeFloat(w, f),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

pub fn fmtValue(v: Value) std.fmt.Alt(Value, formatValue) {
    return .{ .data = v };
}

fn formatValue(v: Value, w: *Writer) Writer.Error!void {
    return write(w, v);
}

/// Go's %v for a float64: shortest digits, exponent form below 1e-4 and from 1e6.
pub fn writeFloat(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("NaN");
    if (std.math.isInf(f)) return w.writeAll(if (f > 0) "+Inf" else "-Inf");
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const sci = std.fmt.float.render(&buf, f, .{ .mode = .scientific }) catch unreachable;
    const e = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e + 1 ..], 10) catch unreachable;
    if (exp < -4 or exp >= 6) {
        try w.print("{s}e{c}{d:0>2}", .{ sci[0..e], @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
        return;
    }
    var buf2: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    try w.writeAll(std.fmt.float.render(&buf2, f, .{ .mode = .decimal }) catch unreachable);
}
