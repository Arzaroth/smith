//! `--template`: the part of Go's text/template that gh users reach for.
//!
//! Text is copied; `{{ ... }}` actions hold pipelines of commands joined by
//! `|`, the value on the left passed as the last argument on the right. An
//! operand is `.`, a field path (`.user.login`), a variable (`$`, `$x`,
//! `$x.name`), a parenthesised pipeline (`(index .labels 0).name`), a string
//! (`"a\tb"`, `` `raw` ``), character, number, `true`, `false` or `nil`.
//! `{{$x := PIPE}}` declares a variable until the end of the enclosing
//! block, `{{$x = PIPE}}` assigns one. `if` and `range PIPE` (arrays) take
//! `else` and `end`; `range $v := PIPE` and `range $i, $v := PIPE` bind the
//! element and its index. `{{/* comments */}}` are dropped, `{{-` and `-}}`
//! trim the whitespace next to them. Functions: `len`, `join SEP LIST`
//! (gh's) and `timeago`.
//!
//! A missing field renders as nothing. Errors name their position, Go-style:
//! `template: 1:14: function "foo" not defined`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const lex = @import("template/lex.zig");
const syntax = @import("template/parse.zig");
const exec = @import("template/exec.zig");

pub const Error = error{ TemplateSyntax, TemplateExec, OutOfMemory, WriteFailed };

pub const Options = struct {
    /// For `timeago`, in Unix seconds.
    now: i64 = 0,
};

/// What went wrong, set when parsing or rendering fails with
/// `error.TemplateSyntax` or `error.TemplateExec`.
pub const Diagnostic = struct {
    message: []const u8 = "",

    pub fn fail(d: *Diagnostic, alloc: Allocator, src: []const u8, pos: usize, comptime fmt: []const u8, args: anytype) Error {
        try d.set(alloc, src, pos, fmt, args);
        return error.TemplateSyntax;
    }

    pub fn failExec(d: *Diagnostic, alloc: Allocator, src: []const u8, pos: usize, comptime fmt: []const u8, args: anytype) Error {
        try d.set(alloc, src, pos, fmt, args);
        return error.TemplateExec;
    }

    fn set(d: *Diagnostic, alloc: Allocator, src: []const u8, pos: usize, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const at = @min(pos, src.len);
        const line = 1 + std.mem.count(u8, src[0..at], "\n");
        const start = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
        d.message = try std.fmt.allocPrint(alloc, "template: {d}:{d}: " ++ fmt, .{ line, at - start + 1 } ++ args);
    }
};

pub const Template = struct {
    nodes: []const syntax.Node,
    src: []const u8,

    pub fn parse(alloc: Allocator, source: []const u8, diag: *Diagnostic) Error!Template {
        var p: syntax.Parser = .{ .alloc = alloc, .src = source, .toks = try lex.lex(alloc, source, diag), .diag = diag };
        return .{ .nodes = try p.root(), .src = source };
    }

    pub fn render(t: Template, alloc: Allocator, w: *Writer, data: Value, opts: Options, diag: *Diagnostic) Error!void {
        var e: exec.Exec = .{ .alloc = alloc, .src = t.src, .w = w, .opts = opts, .diag = diag };
        try e.run(t.nodes, data);
    }
};

const testing = std.testing;
const term = @import("term.zig");
const test_now = 1790683200;

fn renderAlloc(a: Allocator, src: []const u8, json: []const u8, opts: Options, diag: *Diagnostic) ![]const u8 {
    const data = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    try (try Template.parse(a, src, diag)).render(a, &out.writer, data, opts, diag);
    return out.written();
}

fn expectRenderOpts(src: []const u8, json: []const u8, opts: Options, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const got = renderAlloc(arena.allocator(), src, json, opts, &diag) catch |e| {
        std.debug.print("{s}\n", .{diag.message});
        return e;
    };
    try testing.expectEqualStrings(want, got);
}

fn expectRender(src: []const u8, json: []const u8, want: []const u8) !void {
    return expectRenderOpts(src, json, .{ .now = test_now }, want);
}

/// Parsing or rendering `src` fails with `message`.
fn expectFail(src: []const u8, json: []const u8, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    if (renderAlloc(arena.allocator(), src, json, .{ .now = test_now }, &diag)) |got| {
        std.debug.print("rendered {s}\n", .{got});
        return error.TestExpectedError;
    } else |e| switch (e) {
        error.TemplateSyntax, error.TemplateExec => try testing.expectEqualStrings(message, diag.message),
        else => return e,
    }
}

test "fields, ranges, conditions and functions" {
    try testing.expectEqual(test_now, term.parseTime("2026-09-29T12:00:00Z").?);
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
    try expectFail("{{range .}}", "[]", "template: 1:12: unexpected EOF: {{range}} has no {{end}}");
    try expectFail("{{end}}", "[]", "template: 1:3: unexpected {{end}}");
    try expectFail("{{.a", "{}", "template: 1:1: unclosed action");
    try expectFail("{{bogus}}", "{}", "template: 1:3: function \"bogus\" not defined");
}

test "trim markers reach across block boundaries" {
    try expectRender("{{range . -}}\n  {{.n}}\n{{end}}", "[{\"n\":1},{\"n\":2}]", "1\n2\n");
    try expectRender("{{range .}}{{.n}}{{end -}}\nX", "[{\"n\":1},{\"n\":2}]", "12X");
    try expectRender("{{if .a -}}\n yes {{- else -}}\n no{{end}}", "{\"a\":false}", "no");
}

test "nesting is capped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const deep = try std.mem.concat(a, u8, &.{ "{{if .}}" ** 40, "{{end}}" ** 40 });
    try testing.expectError(error.TemplateSyntax, Template.parse(a, deep, &diag));
    try testing.expectEqualStrings("template: 1:259: nested deeper than 32 levels", diag.message);
    _ = try Template.parse(a, "{{if .}}" ** 30 ++ "{{end}}" ** 30, &diag);
    try expectFail("{{len " ++ "(" ** 40 ++ "." ++ ")" ** 40 ++ "}}", "[]", "template: 1:39: nested deeper than 32 levels");
}

test "pipelines, parentheses and literals" {
    const issue =
        \\{"title":"Crash","labels":[{"name":"bug"},{"name":"ui"}],"n":7}
    ;
    try expectRender("{{.labels | len}}", issue, "2");
    try expectRender("{{len (.user).name}} {{(.user).name}}", "{\"user\":{\"name\":\"bob\"}}", "3 bob");
    try expectRender("{{(.labels)}}", "{\"labels\":[1,2]}", "[1,2]");
    try expectRender("{{\"x\" | len}} {{`a\\b` | len}}", "{}", "1 3");
    try expectRender("{{1}} {{-2}} {{0x1f}} {{1.5}} {{1e6}} {{2.0}} {{'a'}} {{true}} {{false}} {{nil}}|", "{}", "1 -2 31 1.5 1e+06 2 97 true false |");
    try expectRender("{{\"\\u00e9\\x41\\101\\\"\"}}", "{}", "éAA\"");
    try expectRender("{{`multi\nline`}}", "{}", "multi\nline");
    try expectRender("{{.f}} {{.g}} {{.h}}", "{\"f\":0.5,\"g\":123456789.0,\"h\":0.00001}", "0.5 1.23456789e+08 1e-05");
}

test "variables" {
    try expectRender("{{$x := .a}}{{$x}}{{$x = 2}}{{$x}}", "{\"a\":1}", "12");
    try expectRender("{{range $v := .xs}}{{$.name}}{{$v}}{{end}}", "{\"name\":\"n\",\"xs\":[1,2]}", "n1n2");
    try expectRender("{{range $i, $v := .}}{{$i}}={{$v.k}} {{end}}", "[{\"k\":\"a\"},{\"k\":\"b\"}]", "0=a 1=b ");
    try expectRender("{{$n := 0}}{{range .}}{{$n = .}}{{end}}{{$n}}", "[1,2,3]", "3");
    try expectRender("{{$x := 1}}{{if true}}{{$x := 2}}{{$x}}{{end}}{{$x}}", "{}", "21");
    try expectFail("{{if true}}{{$x := 2}}{{end}}{{$x}}", "{}", "template: 1:32: undefined variable \"$x\"");
    try expectFail("{{$y = 1}}", "{}", "template: 1:3: undefined variable \"$y\"");
    try expectFail("{{$a, $b := .}}", "{}", "template: 1:5: too many declarations in command");
}

test "comments" {
    try expectRender("a{{/* note */}}b", "{}", "ab");
    try expectRender("a {{- /* note */ -}} b", "{}", "ab");
    try expectRender("{{/* a\nmulti-line }} comment */}}x", "{}", "x");
    try expectFail("{{/* open", "{}", "template: 1:1: unclosed comment");
    try expectFail("{{/* x */ .a}}", "{}", "template: 1:1: comment ends before closing delimiter");
}

test "parse errors name their position" {
    try expectFail("{{.title}}\n{{foo}}", "{}", "template: 2:3: function \"foo\" not defined");
    try expectFail("{{}x}}", "{}", "template: 1:3: unexpected \"}\" in operand");
    try expectFail("{{}}", "{}", "template: 1:3: missing value for command");
    try expectFail("{{.a | }}", "{}", "template: 1:8: missing value for command");
    try expectFail("{{len .a .b}}", "{}", "template: 1:3: wrong number of args for len: want 1 got 2");
    try expectFail("{{.a | len .b}}", "{}", "template: 1:8: wrong number of args for len: want 1 got 2");
    try expectFail("{{.a .b}}", "{}", "template: 1:3: can't give argument to non-function .a");
    try expectFail("{{.a | .b}}", "{}", "template: 1:8: non executable command in pipeline stage 2");
    try expectFail("{{(.a}}", "{}", "template: 1:6: unclosed left paren");
    try expectFail("{{.a)}}", "{}", "template: 1:5: unexpected \")\" in command");
    try expectFail("{{\"abc}}", "{}", "template: 1:3: unterminated quoted string");
    try expectFail("{{`abc}}", "{}", "template: 1:3: unterminated raw quoted string");
    try expectFail("{{\"\\q\"}}", "{}", "template: 1:3: invalid syntax in string \"\\q\"");
    try expectFail("{{'ab'}}", "{}", "template: 1:3: invalid syntax in character constant 'ab'");
    try expectFail("{{1x}}", "{}", "template: 1:3: bad number syntax: \"1x\"");
    try expectFail("{{.a\"x\"}}", "{}", "template: 1:5: unexpected \"\"x\"\" in operand");
    try expectFail("{{\"x\".a}}", "{}", "template: 1:6: unexpected . after term \"\"x\"\"");
    try expectFail("{{template \"x\"}}", "{}", "template: 1:3: {{template}} is not supported");
    try expectFail("{{if}}{{end}}", "{}", "template: 1:5: missing value for if");
    try expectFail("{{else}}", "{}", "template: 1:3: unexpected {{else}}");
    try expectFail("{{if .}}{{else}}{{else}}{{end}}", "{}", "template: 1:19: expected end; found {{else}}");
    try expectFail("{{end x}}", "{}", "template: 1:7: unexpected \"x\" in end");
}

test "execution errors name their position" {
    try expectFail("{{range .}}{{end}}", "\"s\"", "template: 1:9: range can't iterate over s");
    try expectFail("ok {{len .}}", "true", "template: 1:6: error calling len: len of type bool");
}
