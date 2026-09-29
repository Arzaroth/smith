//! `--template`: the part of Go's text/template that gh users reach for.
//!
//! Text is copied; `{{ ... }}` actions are `.` or a field path (`.user.login`),
//! a string literal, `range PIPE` / `if PIPE` with `else` and `end`, and the
//! functions `len X`, `join SEP X` and `timeago X`. `{{-` and `-}}` trim the
//! whitespace next to them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const term = @import("term.zig");

pub const Error = error{ TemplateSyntax, OutOfMemory, WriteFailed };

const Node = union(enum) {
    text: []const u8,
    expr: []const []const u8,
    range: Block,
    cond: Block,

    const Block = struct {
        expr: []const []const u8,
        body: []const Node,
        otherwise: []const Node = &.{},
    };
};

pub const Template = struct {
    nodes: []const Node,

    pub fn parse(alloc: Allocator, source: []const u8) Error!Template {
        var p: Parser = .{ .alloc = alloc, .src = source };
        const nodes = try p.nodes(false);
        if (p.pos < p.src.len) return error.TemplateSyntax;
        return .{ .nodes = nodes };
    }

    pub fn render(t: Template, alloc: Allocator, w: *Writer, data: Value, now: i64) Error!void {
        const r: Renderer = .{ .alloc = alloc, .w = w, .now = now };
        try r.all(t.nodes, data);
    }
};

const Parser = struct {
    alloc: Allocator,
    src: []const u8,
    pos: usize = 0,
    /// Set when the action that ended a block was `else` or `end`.
    stop: enum { none, @"else", end } = .none,

    fn nodes(p: *Parser, in_block: bool) Error![]const Node {
        var list: std.ArrayList(Node) = .empty;
        var trim_next = false;
        while (p.pos < p.src.len) {
            const open = std.mem.indexOfPos(u8, p.src, p.pos, "{{") orelse p.src.len;
            var text = p.src[p.pos..open];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            trim_next = false;
            if (open == p.src.len) {
                if (text.len > 0) try list.append(p.alloc, .{ .text = text });
                p.pos = open;
                break;
            }
            var inner_start = open + 2;
            if (inner_start < p.src.len and p.src[inner_start] == '-') {
                text = std.mem.trimEnd(u8, text, " \t\r\n");
                inner_start += 1;
            }
            if (text.len > 0) try list.append(p.alloc, .{ .text = text });
            const close = std.mem.indexOfPos(u8, p.src, inner_start, "}}") orelse return error.TemplateSyntax;
            var inner_end = close;
            if (inner_end > inner_start and p.src[inner_end - 1] == '-') {
                inner_end -= 1;
                trim_next = true;
            }
            p.pos = close + 2;
            const words = try tokenize(p.alloc, p.src[inner_start..inner_end]);
            if (words.len == 0) return error.TemplateSyntax;
            const head = words[0];
            if (std.mem.eql(u8, head, "end") or std.mem.eql(u8, head, "else")) {
                if (!in_block) return error.TemplateSyntax;
                p.stop = if (head[1] == 'n') .end else .@"else";
                return list.toOwnedSlice(p.alloc);
            }
            if (std.mem.eql(u8, head, "range") or std.mem.eql(u8, head, "if")) {
                if (words.len < 2) return error.TemplateSyntax;
                try validate(words[1..]);
                var block: Node.Block = .{ .expr = words[1..], .body = try p.nodes(true) };
                if (p.stop == .@"else") block.otherwise = try p.nodes(true);
                if (p.stop != .end) return error.TemplateSyntax;
                p.stop = .none;
                try list.append(p.alloc, if (head[0] == 'r') .{ .range = block } else .{ .cond = block });
                continue;
            }
            try validate(words);
            try list.append(p.alloc, .{ .expr = words });
        }
        if (in_block) return error.TemplateSyntax;
        return list.toOwnedSlice(p.alloc);
    }
};

/// Splits an action into words, keeping quoted strings whole (quotes included).
fn tokenize(alloc: Allocator, s: []const u8) Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == ' ' or s[i] == '\t') {
            i += 1;
            continue;
        }
        const start = i;
        if (s[i] == '"') {
            i += 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            if (i >= s.len) return error.TemplateSyntax;
            i += 1;
        } else {
            while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
        }
        try words.append(alloc, s[start..i]);
    }
    return words.toOwnedSlice(alloc);
}

const Renderer = struct {
    alloc: Allocator,
    w: *Writer,
    now: i64,

    fn all(r: Renderer, nodes: []const Node, dot: Value) Error!void {
        for (nodes) |n| switch (n) {
            .text => |t| try r.w.writeAll(t),
            .expr => |e| try r.write(try r.eval(e, dot)),
            .range => |b| {
                const v = try r.eval(b.expr, dot);
                const items: []const Value = switch (v) {
                    .array => |a| a.items,
                    else => &.{},
                };
                if (items.len == 0) try r.all(b.otherwise, dot);
                for (items) |item| try r.all(b.body, item);
            },
            .cond => |b| try r.all(if (truthy(try r.eval(b.expr, dot))) b.body else b.otherwise, dot),
        };
    }

    fn eval(r: Renderer, words: []const []const u8, dot: Value) Error!Value {
        const head = words[0];
        if (std.mem.eql(u8, head, "len")) {
            if (words.len != 2) return error.TemplateSyntax;
            const v = try r.eval(words[1..], dot);
            return .{ .integer = @intCast(switch (v) {
                .array => |a| a.items.len,
                .object => |o| o.count(),
                .string => |s| s.len,
                else => 0,
            }) };
        }
        if (std.mem.eql(u8, head, "join")) {
            if (words.len != 3) return error.TemplateSyntax;
            const sep = try r.eval(words[1..2], dot);
            const v = try r.eval(words[2..], dot);
            var out: std.Io.Writer.Allocating = .init(r.alloc);
            if (v == .array) for (v.array.items, 0..) |item, i| {
                if (i > 0) try out.writer.writeAll(if (sep == .string) sep.string else "");
                try (Renderer{ .alloc = r.alloc, .w = &out.writer, .now = r.now }).write(item);
            };
            return .{ .string = out.written() };
        }
        if (std.mem.eql(u8, head, "timeago")) {
            if (words.len != 2) return error.TemplateSyntax;
            const v = try r.eval(words[1..], dot);
            if (v != .string) return v;
            return .{ .string = term.ago(r.alloc, r.now, v.string) catch return error.OutOfMemory };
        }
        if (words.len != 1) return error.TemplateSyntax;
        if (head[0] == '"') return .{ .string = try unquote(r.alloc, head) };
        if (head[0] != '.') return error.TemplateSyntax;
        var v = dot;
        var it = std.mem.tokenizeScalar(u8, head, '.');
        while (it.next()) |field| {
            v = switch (v) {
                .object => |o| o.get(field) orelse .null,
                else => .null,
            };
        }
        return v;
    }

    fn write(r: Renderer, v: Value) Error!void {
        switch (v) {
            .null => {},
            .string => |s| try r.w.writeAll(s),
            .number_string => |s| try r.w.writeAll(s),
            .integer => |n| try r.w.print("{d}", .{n}),
            .float => |f| try r.w.print("{d}", .{f}),
            .bool => |b| try r.w.writeAll(if (b) "true" else "false"),
            else => try std.json.Stringify.value(v, .{}, r.w),
        }
    }
};

fn truthy(v: Value) bool {
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

fn unquote(alloc: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 2 < s.len) {
            i += 1;
            try out.append(alloc, switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                else => s[i],
            });
        } else try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

fn expectRender(src: []const u8, json: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    try (try Template.parse(a, src)).render(a, &out.writer, data, term.parseTime("2026-09-29T12:00:00Z").?);
    try testing.expectEqualStrings(want, out.written());
}

test "fields, ranges, conditions and functions" {
    try expectRender("{{.title}} by {{.user.login}}", "{\"title\":\"T\",\"user\":{\"login\":\"u\"}}", "T by u");
    try expectRender("{{range .}}#{{.number}} {{end}}", "[{\"number\":1},{\"number\":2}]", "#1 #2 ");
    try expectRender("{{range .}}x{{else}}none{{end}}", "[]", "none");
    try expectRender("{{if .draft}}draft{{else}}ready{{end}}", "{\"draft\":false}", "ready");
    try expectRender("{{len .}} {{join \", \" .}}", "[\"a\",\"b\"]", "2 a, b");
    try expectRender("{{timeago .t}}", "{\"t\":\"2026-09-29T09:00:00Z\"}", "about 3 hours ago");
    try expectRender("{{range .}}\n  {{- .n -}}\n{{end}}", "[{\"n\":1},{\"n\":2}]", "12");
    try expectRender("{{\"a\\tb\\n\"}}", "null", "a\tb\n");
    try expectRender("{{.missing}}|", "{}", "|");
}

test "syntax errors are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.TemplateSyntax, Template.parse(a, "{{range .}}"));
    try testing.expectError(error.TemplateSyntax, Template.parse(a, "{{end}}"));
    try testing.expectError(error.TemplateSyntax, Template.parse(a, "{{.a"));
    try testing.expectError(error.TemplateSyntax, Template.parse(a, "{{bogus}}"));
}

fn validate(words: []const []const u8) Error!void {
    const head = words[0];
    const arity: usize = if (std.mem.eql(u8, head, "len") or std.mem.eql(u8, head, "timeago"))
        2
    else if (std.mem.eql(u8, head, "join"))
        3
    else if (head[0] == '.' or head[0] == '"')
        1
    else
        return error.TemplateSyntax;
    if (words.len != arity) return error.TemplateSyntax;
    for (words[1..]) |w| if (w[0] != '.' and w[0] != '"') return error.TemplateSyntax;
}
