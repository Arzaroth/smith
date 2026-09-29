//! Turns tokens into a node tree, checking what Go checks at parse time:
//! functions and variables exist, and each function gets its arguments.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const template = @import("../template.zig");
const Diagnostic = template.Diagnostic;
const Error = template.Error;
const Token = @import("lex.zig").Token;
const funcs = @import("funcs.zig");

pub const Node = union(enum) {
    text: []const u8,
    action: Pipe,
    @"if": Cond,
    range: Range,
};

pub const Cond = struct {
    clauses: []const Clause,
    otherwise: []const Node = &.{},
};

pub const Clause = struct {
    pipe: Pipe,
    body: []const Node,
};

pub const Range = struct {
    pipe: Pipe,
    body: []const Node,
    otherwise: []const Node = &.{},
};

pub const Pipe = struct {
    pos: usize,
    decl: []const []const u8 = &.{},
    assign: bool = false,
    cmds: []const Cmd,
};

pub const Cmd = struct {
    pos: usize,
    args: []const Arg,
};

pub const Arg = struct {
    pos: usize,
    term: Term,
    fields: []const []const u8 = &.{},
};

pub const Term = union(enum) {
    dot,
    variable: []const u8,
    func: funcs.Id,
    pipe: *const Pipe,
    value: Value,
};

pub const max_depth = 32;

pub const Parser = struct {
    alloc: Allocator,
    src: []const u8,
    toks: []const Token,
    diag: *Diagnostic,
    i: usize = 0,
    vars: std.ArrayList([]const u8) = .empty,
    depth: u8 = 0,

    const Stop = enum { eof, end, @"else" };

    const List = struct {
        nodes: []const Node,
        stop: Stop,
        pos: usize,
    };

    pub fn root(p: *Parser) Error![]const Node {
        try p.vars.append(p.alloc, "$");
        const l = try p.list();
        if (l.stop != .eof) return p.fail(l.pos, "unexpected {{{{{t}}}}}", .{l.stop});
        return l.nodes;
    }

    fn fail(p: *Parser, pos: usize, comptime fmt: []const u8, args: anytype) Error {
        return p.diag.fail(p.alloc, p.src, pos, fmt, args);
    }

    fn peek(p: *Parser) Token {
        return p.toks[p.i];
    }

    fn next(p: *Parser) Token {
        const t = p.toks[p.i];
        if (t.tag != .eof) p.i += 1;
        return t;
    }

    fn keyword(t: Token, word: []const u8) bool {
        return t.tag == .identifier and std.mem.eql(u8, t.text, word);
    }

    fn expectClose(p: *Parser, what: []const u8) Error!void {
        const t = p.next();
        if (t.tag != .close) return p.fail(t.pos, "unexpected \"{s}\" in {s}", .{ t.text, what });
    }

    fn list(p: *Parser) Error!List {
        var nodes: std.ArrayList(Node) = .empty;
        while (true) {
            const t = p.next();
            switch (t.tag) {
                .text => try nodes.append(p.alloc, .{ .text = t.text }),
                .eof => return .{ .nodes = try nodes.toOwnedSlice(p.alloc), .stop = .eof, .pos = t.pos },
                .open => {
                    const head = p.peek();
                    if (keyword(head, "end") or keyword(head, "else")) {
                        _ = p.next();
                        const stop: Stop = if (head.text[1] == 'n') .end else .@"else";
                        if (stop == .end) try p.expectClose("end");
                        return .{ .nodes = try nodes.toOwnedSlice(p.alloc), .stop = stop, .pos = head.pos };
                    }
                    if (keyword(head, "if")) {
                        _ = p.next();
                        try nodes.append(p.alloc, .{ .@"if" = try p.cond(head) });
                    } else if (keyword(head, "range")) {
                        _ = p.next();
                        try nodes.append(p.alloc, .{ .range = try p.range(head) });
                    } else if (keyword(head, "define") or keyword(head, "template") or keyword(head, "block")) {
                        return p.fail(head.pos, "{{{{{s}}}}} is not supported", .{head.text});
                    } else {
                        try nodes.append(p.alloc, .{ .action = try p.pipeline("command", .close, false) });
                    }
                },
                else => unreachable,
            }
        }
    }

    fn enter(p: *Parser, pos: usize) Error!void {
        if (p.depth == max_depth) return p.fail(pos, "nested deeper than {d} levels", .{max_depth});
        p.depth += 1;
    }

    fn block(p: *Parser, head: Token) Error!List {
        const l = try p.list();
        if (l.stop == .eof) return p.fail(l.pos, "unexpected EOF: {{{{{s}}}}} has no {{{{end}}}}", .{head.text});
        return l;
    }

    fn cond(p: *Parser, head: Token) Error!Cond {
        try p.enter(head.pos);
        defer p.depth -= 1;
        const mark = p.vars.items.len;
        defer p.vars.shrinkRetainingCapacity(mark);
        const pipe = try p.pipeline(head.text, .close, false);
        var l = try p.block(head);
        const clauses = try p.alloc.alloc(Clause, 1);
        clauses[0] = .{ .pipe = pipe, .body = l.nodes };
        var c: Cond = .{ .clauses = clauses };
        if (l.stop == .@"else") {
            try p.expectClose("else");
            l = try p.block(head);
            if (l.stop != .end) return p.fail(l.pos, "expected end; found {{{{else}}}}", .{});
            c.otherwise = l.nodes;
        }
        return c;
    }

    fn range(p: *Parser, head: Token) Error!Range {
        try p.enter(head.pos);
        defer p.depth -= 1;
        const mark = p.vars.items.len;
        defer p.vars.shrinkRetainingCapacity(mark);
        var r: Range = .{ .pipe = try p.pipeline("range", .close, true), .body = undefined };
        var l = try p.block(head);
        r.body = l.nodes;
        if (l.stop == .@"else") {
            try p.expectClose("else");
            l = try p.block(head);
            if (l.stop != .end) return p.fail(l.pos, "expected end; found {{{{else}}}}", .{});
            r.otherwise = l.nodes;
        }
        return r;
    }

    fn declared(p: *Parser, name: []const u8) bool {
        var i = p.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.vars.items[i], name)) return true;
        }
        return false;
    }

    fn declaration(p: *Parser, context: []const u8, in_range: bool) Error!struct { names: []const []const u8, assign: bool } {
        const t = p.toks[p.i..];
        var n: usize = 0;
        if (t[0].tag == .variable and (t[1].tag == .declare or t[1].tag == .assign)) {
            n = 1;
        } else if (t[0].tag == .variable and t[1].tag == .comma) {
            if (!in_range) return p.fail(t[1].pos, "too many declarations in {s}", .{context});
            if (t[2].tag != .variable or (t[3].tag != .declare and t[3].tag != .assign))
                return p.fail(t[2].pos, "too many declarations in {s}", .{context});
            n = 2;
        } else return .{ .names = &.{}, .assign = false };
        const assign = t[2 * n - 1].tag == .assign;
        const names = try p.alloc.alloc([]const u8, n);
        for (names, 0..) |*name, k| {
            name.* = t[2 * k].text;
            if (assign) {
                if (!p.declared(name.*)) return p.fail(t[2 * k].pos, "undefined variable \"{s}\"", .{name.*});
            } else try p.vars.append(p.alloc, name.*);
        }
        p.i += 2 * n;
        return .{ .names = names, .assign = assign };
    }

    fn pipeline(p: *Parser, context: []const u8, end: Token.Tag, in_range: bool) Error!Pipe {
        const pos = p.peek().pos;
        const decl = try p.declaration(context, in_range);
        var cmds: std.ArrayList(Cmd) = .empty;
        while (true) {
            const t = p.peek();
            if (t.tag == end and cmds.items.len == 0 and decl.names.len == 0) break;
            try cmds.append(p.alloc, try p.command());
            const sep = p.next();
            if (sep.tag == .pipe) continue;
            if (sep.tag == end) break;
            if (sep.tag == .close or sep.tag == .eof) return p.fail(sep.pos, "unclosed left paren", .{});
            return p.fail(sep.pos, "unexpected \"{s}\" in {s}", .{ sep.text, context });
        }
        if (cmds.items.len == 0) {
            if (p.peek().tag == end) _ = p.next();
            return p.fail(pos, "missing value for {s}", .{context});
        }
        for (cmds.items, 0..) |c, stage| try p.check(c, stage);
        return .{ .pos = pos, .decl = decl.names, .assign = decl.assign, .cmds = try cmds.toOwnedSlice(p.alloc) };
    }

    fn check(p: *Parser, c: Cmd, stage: usize) Error!void {
        const head = c.args[0];
        if (head.term == .func) {
            try p.arity(head, c.args.len - 1 + @intFromBool(stage > 0));
        } else if (c.args.len > 1) {
            return p.fail(head.pos, "can't give argument to non-function {s}", .{p.source(head)});
        } else if (stage > 0) {
            return p.fail(head.pos, "non executable command in pipeline stage {d}", .{stage + 1});
        }
        for (c.args[1..]) |a| if (a.term == .func) try p.arity(a, 0);
    }

    fn arity(p: *Parser, a: Arg, got: usize) Error!void {
        const id = a.term.func;
        const want = funcs.arity(id);
        if (got < want.min) {
            if (want.max == null) return p.fail(a.pos, "wrong number of args for {t}: want at least {d} got {d}", .{ id, want.min, got });
            return p.fail(a.pos, "wrong number of args for {t}: want {d} got {d}", .{ id, want.min, got });
        }
        if (want.max) |max| if (got > max) {
            if (max == want.min) return p.fail(a.pos, "wrong number of args for {t}: want {d} got {d}", .{ id, max, got });
            return p.fail(a.pos, "wrong number of args for {t}: want at most {d} got {d}", .{ id, max, got });
        };
    }

    fn source(p: *Parser, a: Arg) []const u8 {
        var end = a.pos;
        while (end < p.src.len and !std.ascii.isWhitespace(p.src[end]) and p.src[end] != '}' and p.src[end] != '|') end += 1;
        return p.src[a.pos..end];
    }

    fn command(p: *Parser) Error!Cmd {
        const pos = p.peek().pos;
        var args: std.ArrayList(Arg) = .empty;
        while (true) {
            const t = p.peek();
            switch (t.tag) {
                .close, .rparen, .pipe, .eof => break,
                else => {},
            }
            if (args.items.len > 0 and !t.spaced) return p.fail(t.pos, "unexpected \"{s}\" in operand", .{t.text});
            try args.append(p.alloc, try p.operand());
        }
        if (args.items.len == 0) return p.fail(pos, "missing value for command", .{});
        return .{ .pos = pos, .args = try args.toOwnedSlice(p.alloc) };
    }

    fn operand(p: *Parser) Error!Arg {
        const t = p.next();
        var fields: std.ArrayList([]const u8) = .empty;
        const term: Term = switch (t.tag) {
            .dot => .dot,
            .field => field: {
                try fields.append(p.alloc, t.text[1..]);
                break :field .dot;
            },
            .variable => variable: {
                if (!p.declared(t.text)) return p.fail(t.pos, "undefined variable \"{s}\"", .{t.text});
                break :variable .{ .variable = t.text };
            },
            .identifier => if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false"))
                .{ .value = .{ .bool = t.text[0] == 't' } }
            else if (std.mem.eql(u8, t.text, "nil"))
                .{ .value = .null }
            else if (funcs.lookup(t.text)) |id|
                .{ .func = id }
            else if (isKeyword(t.text))
                return p.fail(t.pos, "unexpected <{s}> in operand", .{t.text})
            else
                return p.fail(t.pos, "function \"{s}\" not defined", .{t.text}),
            .string => .{ .value = .{ .string = unquote(p.alloc, t.text[1 .. t.text.len - 1]) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return p.fail(t.pos, "invalid syntax in string {s}", .{t.text}),
            } } },
            .raw_string => .{ .value = .{ .string = t.text[1 .. t.text.len - 1] } },
            .char => .{ .value = .{ .integer = char(p.alloc, t.text) catch return p.fail(t.pos, "invalid syntax in character constant {s}", .{t.text}) } },
            .number => .{ .value = number(t.text) orelse return p.fail(t.pos, "bad number syntax: \"{s}\"", .{t.text}) },
            .lparen => paren: {
                try p.enter(t.pos);
                defer p.depth -= 1;
                const pipe = try p.alloc.create(Pipe);
                pipe.* = try p.pipeline("parenthesized pipeline", .rparen, false);
                break :paren .{ .pipe = pipe };
            },
            else => return p.fail(t.pos, "unexpected \"{s}\" in operand", .{t.text}),
        };
        while (p.peek().tag == .field and !p.peek().spaced) {
            const f = p.next();
            switch (term) {
                .value, .func => return p.fail(f.pos, "unexpected . after term \"{s}\"", .{t.text}),
                else => {},
            }
            try fields.append(p.alloc, f.text[1..]);
        }
        return .{ .pos = t.pos, .term = term, .fields = try fields.toOwnedSlice(p.alloc) };
    }
};

fn isKeyword(s: []const u8) bool {
    const words = [_][]const u8{ "if", "else", "end", "range", "with", "break", "continue", "define", "template", "block" };
    for (words) |w| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

fn number(s: []const u8) ?Value {
    if (std.fmt.parseInt(i64, s, 0)) |n| return .{ .integer = n } else |_| {}
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) return null;
    const f = std.fmt.parseFloat(f64, s) catch return null;
    if (std.math.isNan(f) or std.math.isInf(f)) return null;
    return .{ .float = f };
}

fn char(alloc: Allocator, quoted: []const u8) !i64 {
    const s = try unquote(alloc, quoted[1 .. quoted.len - 1]);
    const len = std.unicode.utf8ByteSequenceLength(if (s.len > 0) s[0] else return error.Invalid) catch return error.Invalid;
    if (len != s.len) return error.Invalid;
    if (len == 1) return s[0];
    return std.unicode.utf8Decode(s) catch error.Invalid;
}

/// The body of a Go double-quoted string with its escapes resolved.
fn unquote(alloc: Allocator, s: []const u8) error{ OutOfMemory, Invalid }![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            try out.append(alloc, s[i]);
            continue;
        }
        i += 1;
        if (i >= s.len) return error.Invalid;
        const c = s[i];
        const simple: ?u8 = switch (c) {
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            '\\', '"', '\'' => c,
            else => null,
        };
        if (simple) |b| {
            try out.append(alloc, b);
            continue;
        }
        const digits: usize, const base: u8 = switch (c) {
            'x' => .{ 2, 16 },
            'u' => .{ 4, 16 },
            'U' => .{ 8, 16 },
            '0'...'7' => .{ 3, 8 },
            else => return error.Invalid,
        };
        const from = if (base == 8) i else i + 1;
        if (from + digits > s.len) return error.Invalid;
        const n = std.fmt.parseInt(u32, s[from .. from + digits], base) catch return error.Invalid;
        i = from + digits - 1;
        if (c == 'x' or base == 8) {
            if (n > 0xff) return error.Invalid;
            try out.append(alloc, @intCast(n));
        } else {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(std.math.cast(u21, n) orelse return error.Invalid, &buf) catch return error.Invalid;
            try out.appendSlice(alloc, buf[0..len]);
        }
    }
    return out.toOwnedSlice(alloc);
}
