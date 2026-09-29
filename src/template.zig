//! `--template`: the part of Go's text/template that gh users reach for.
//!
//! Text is copied; `{{ ... }}` actions hold pipelines of commands joined by
//! `|`, the value on the left passed as the last argument on the right. An
//! operand is `.`, a field path (`.user.login`), a variable (`$`, `$x`,
//! `$x.name`), a parenthesised pipeline (`(index .labels 0).name`), a string
//! (`"a\tb"`, `` `raw` ``), character, number, `true`, `false` or `nil`.
//! `{{$x := PIPE}}` declares a variable until the end of the enclosing
//! block, `{{$x = PIPE}}` assigns one. `if` and `with` (which moves `.` to
//! the value) take `else if` / `else with` chains, `else` and `end`. `range`
//! walks an array, an object's values by sorted key, or `0..n` for a number,
//! runs its `else` when there is nothing to walk, and stops at `break` or
//! skips ahead at `continue`; `range $v := PIPE` binds the element,
//! `range $i, $v := PIPE` the index or key too. `{{/* comments */}}` are
//! dropped, `{{-` and `-}}` trim the whitespace next to them.
//!
//! Go's functions: `and`, `or` (short-circuit, returning an operand), `not`,
//! `len`, `index`, `slice`, `print`, `println`, `printf` (verbs `v s q d x X
//! o b c f e g t %` with flags, width and precision), `eq` (`eq a b c` is
//! a==b or a==c), `ne`, `lt`, `le`, `gt`, `ge`. gh's: `contains`,
//! `hasPrefix`, `hasSuffix` (`contains SUBSTR STRING`), `join SEP LIST`,
//! `pluck FIELD LIST`, `timeago TIME`, `timefmt LAYOUT TIME` (Go reference
//! layouts), `truncate LENGTH STRING`, `color STYLE TEXT` and `autocolor`
//! (mgutz/ansi styles such as `red+b`, both only when colour is on),
//! `hyperlink URL TEXT` (OSC 8 on a terminal), `tablerow FIELDS...` and
//! `tablerender`; rows never rendered are written at the end.
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
    /// `color` and `autocolor` emit ANSI colours.
    color: bool = false,
    /// Stdout is a terminal: `hyperlink` emits OSC 8 links and tables align
    /// with spaces instead of tabs.
    tty: bool = false,
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
    try expectRender("{{len (index .labels 0).name}}", issue, "3");
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

test "with and else chains" {
    try expectRender("{{with .user}}{{.login}}{{end}}", "{\"user\":{\"login\":\"u\"}}", "u");
    try expectRender("{{with .user}}{{.login}}{{else}}nobody{{end}}", "{}", "nobody");
    try expectRender("{{with $u := .user}}{{$u.login}}{{end}}", "{\"user\":{\"login\":\"u\"}}", "u");
    const chain = "{{if .a}}a{{else if .b}}b{{else if .c}}c{{else}}none{{end}}";
    try expectRender(chain, "{\"b\":1,\"c\":1}", "b");
    try expectRender(chain, "{\"c\":1}", "c");
    try expectRender(chain, "{}", "none");
    try expectRender("{{with .a}}{{.}}{{else with .b}}{{.}}!{{end}}", "{\"b\":2}", "2!");
    try expectRender("{{if $x := .a}}{{$x}}{{else if .b}}{{$x}}-{{end}}", "{\"b\":1}", "-");
    try expectFail("{{with .a}}{{else if .b}}{{end}}", "{}", "template: 1:19: unexpected \"if\" in else");
    try expectFail("{{if .a}}", "{}", "template: 1:10: unexpected EOF: {{if}} has no {{end}}");
}

test "range over objects, numbers and nothing" {
    try expectRender("{{range $k, $v := .}}{{$k}}={{$v}} {{end}}", "{\"b\":2,\"a\":1}", "a=1 b=2 ");
    try expectRender("{{range .}}{{.}}{{end}}", "{\"b\":2,\"a\":1}", "12");
    try expectRender("{{range 3}}{{.}}{{end}}", "{}", "012");
    try expectRender("{{range .missing}}x{{else}}empty{{end}}", "{}", "empty");
    try expectRender("{{range .}}x{{else}}empty{{end}}", "{}", "empty");
    try expectFail("{{range $i, $v := 3}}{{end}}", "{}", "template: 1:9: can't use 3 to iterate over more than one variable");
    try expectFail("{{range $a, $b, $c := .}}{{end}}", "{}", "template: 1:13: too many declarations in range");
}

test "break and continue" {
    try expectRender("{{range .}}{{if .stop}}{{break}}{{end}}{{.n}}{{end}}", "[{\"n\":1},{\"n\":2,\"stop\":true},{\"n\":3}]", "1");
    try expectRender("{{range .}}{{if .skip}}{{continue}}{{end}}{{.n}}{{end}}", "[{\"n\":1},{\"n\":2,\"skip\":true},{\"n\":3}]", "13");
    try expectRender("{{range .}}{{range .}}{{break}}{{end}}{{.}}{{end}}", "[[1],[2]]", "[1][2]");
    try expectFail("{{break}}", "{}", "template: 1:3: {{break}} outside {{range}}");
    try expectFail("{{if .}}{{continue}}{{end}}", "{}", "template: 1:11: {{continue}} outside {{range}}");
}

test "logic and comparison" {
    try expectRender("{{and 1 0 2}} {{and 1 2}} {{or 0 \"\" 3}} {{or 0 false}} {{not .a}} {{not 0}}", "{\"a\":[1]}", "0 2 3 false false true");
    try expectRender("{{and .missing (index .missing 5)}} {{or 1 (index .xs 5)}}", "{\"xs\":[]}", " 1");
    try expectRender("{{eq .s \"b\"}} {{eq .s \"a\" \"b\"}} {{eq 1 1.0}} {{eq .n 7}} {{ne .s \"b\"}} {{eq .missing nil}} {{eq .s nil}}", "{\"s\":\"b\",\"n\":7}", "true true true true false true false");
    try expectRender("{{lt 1 2}} {{le 2 2}} {{gt 1.5 2}} {{ge \"b\" \"a\"}} {{lt .n 10}}", "{\"n\":7}", "true true false true true");
    try expectRender("{{if and (eq .state \"open\") (gt .comments 0)}}busy{{end}}", "{\"state\":\"open\",\"comments\":2}", "busy");
    try expectFail("{{eq 1 \"1\"}}", "{}", "template: 1:3: error calling eq: incompatible types for comparison");
    try expectFail("{{eq . 1}}", "[1]", "template: 1:3: error calling eq: non-comparable type []interface {}");
    try expectFail("{{lt true false}}", "{}", "template: 1:3: error calling lt: invalid type for comparison");
    try expectFail("{{eq 1}}", "{}", "template: 1:3: wrong number of args for eq: want at least 2 got 1");
}

test "index, slice, len" {
    const data = "{\"xs\":[\"a\",\"b\",\"c\"],\"m\":{\"k\":{\"x\":1}},\"s\":\"hello\"}";
    try expectRender("{{index .xs 1}} {{index .m \"k\" \"x\"}} {{index .m \"nope\"}}|{{index .s 0}} {{index .xs}}", data, "b 1 |104 [\"a\",\"b\",\"c\"]");
    try expectRender("{{slice .xs 1}} {{slice .xs 1 2}} {{slice .s 1 3}} {{slice .xs}}", data, "[\"b\",\"c\"] [\"b\"] el [\"a\",\"b\",\"c\"]");
    try expectRender("{{len .m}} {{len .s}} {{len .missing}}", data, "1 5 0");
    try expectFail("{{index .xs 5}}", data, "template: 1:3: error calling index: index out of range: 5");
    try expectFail("{{index .m 1}}", data, "template: 1:3: error calling index: cannot index map with type int");
    try expectFail("{{slice .xs 2 1}}", data, "template: 1:3: error calling slice: invalid slice index: 2 > 1");
    try expectFail("{{slice .s 0 1 2}}", data, "template: 1:3: error calling slice: cannot 3-index slice a string");
}

test "print, println and printf" {
    try expectRender("{{print \"a\" 1 2 \"b\"}}|{{println \"a\" 1}}|", "{}", "a1 2b|a 1\n|");
    try expectRender("{{printf \"%s-%d-%v-%t\" .s .n .f true}}", "{\"s\":\"x\",\"n\":7,\"f\":1.5}", "x-7-1.5-true");
    try expectRender("{{printf \"[%-6s][%6s][%.2s][%05d][%+d][%x][%X][%#x][%o][%b][%c]\" \"ab\" \"ab\" \"abc\" 42 3 255 255 255 8 5 65}}", "{}", "[ab    ][    ab][ab][00042][+3][ff][FF][0xff][10][101][A]");
    try expectRender("{{printf \"%5.2f|%f|%.0f|%e|%g|%08.3f|%-7.1f|\" 3.14159 1 2.4 123456.0 0.5 -3.14159 2.26}}", "{}", " 3.14|1.000000|2|1.234560e+05|0.5|-003.142|2.3    |");
    try expectRender("{{printf \"%q %q %v %s\" \"a\\\"b\\n\" 'x' .o .a}}", "{\"o\":{\"k\":1},\"a\":[1]}", "\"a\\\"b\\n\" 'x' {\"k\":1} [1]");
    try expectRender("{{printf \"%d%%\" 50}} {{printf \"%x\" \"hi\"}} {{printf \"%d\" 7.0}} {{printf \"%3d|%-3d|\" 5 5}}", "{}", "50% 6869 7   5|5  |");
    try expectRender("{{printf \"%d %s\" 1}}|{{printf \"%d\" 1 2}}|{{printf \"%d\" \"x\"}}|{{printf \"%z\" 1}}|{{printf \"%d\" nil}}", "{}", "1 %!s(MISSING)|1%!(EXTRA int=2)|%!d(string=x)|%!z(int=1)|%!d(<nil>)");
    try expectRender("{{printf \"#%v\" .number}} {{.title | printf \"%.3s\"}} {{printf \"%v\" 1e7}}", "{\"number\":7,\"title\":\"Crash\"}", "#7 Cra 1e+07");
    try expectRender("{{printf \"%5s|%-4s|\" \"é\" \"né\"}}", "{}", "    é|né  |");
    try expectRender("{{printf \"%.2f %.2f %.2f %.2f %.0f %.0f %.1f %.2f %f\" 2.675 1.005 0.125 0.375 2.5 3.5 -0.04 1e20 0.000001}}", "{}", "2.67 1.00 0.12 0.38 2 4 -0.0 100000000000000000000.00 0.000001");
    try expectFail("{{printf 1}}", "{}", "template: 1:3: error calling printf: format must be a string, not int");
}

test "gh's string and list helpers" {
    const data = "{\"title\":\"Crash on start\",\"labels\":[{\"name\":\"bug\"},{\"name\":\"ui\"},{\"id\":3}],\"s\":\"héllo wörld\"}";
    try expectRender("{{contains \"on\" .title}} {{contains \"x\" .title}} {{hasPrefix \"Cr\" .title}} {{hasSuffix \"art\" .title}}", data, "true false true true");
    try expectRender("{{join \", \" (pluck \"name\" .labels)}}", data, "bug, ui, ");
    try expectRender("{{pluck \"name\" .labels}}", data, "[\"bug\",\"ui\",null]");
    try expectRender("{{truncate 8 .title}}|{{.title | truncate 20}}|{{truncate 7 .s}}|{{truncate 3 .s}}|{{truncate 5 .missing}}|", data, "Crash...|Crash on start|héll...|hél||");
    try expectRender("{{truncate 2 7}}", "{}", "7");
    try expectFail("{{truncate \"x\" .title}}", data, "template: 1:3: error calling truncate: length must be an integer, not string");
    try expectFail("{{truncate 20}}", data, "template: 1:3: wrong number of args for truncate: want 2 got 1");
    try expectFail("{{pluck \"x\" .title}}", data, "template: 1:3: error calling pluck: expected a list, got string");
}

test "timefmt" {
    const data = "{\"t\":\"2026-03-05T14:07:09Z\",\"o\":\"2026-03-05T09:07:09.123-05:00\",\"z\":\"2026-12-31T00:00:00+02:00\"}";
    try expectRender("{{timefmt \"2006-01-02 15:04:05\" .t}}", data, "2026-03-05 14:07:09");
    try expectRender("{{timefmt \"Mon Jan _2 3:4:5 PM 06\" .t}}", data, "Thu Mar  5 2:7:9 PM 26");
    try expectRender("{{timefmt \"Monday, January 2, 2006 03:04pm MST\" .t}}", data, "Thursday, March 5, 2026 02:07pm UTC");
    try expectRender("{{timefmt \"15:04 -0700 Z07:00 MST .000 .999\" .o}}", data, "09:07 -0500 -05:00 -0500 .123 .123");
    try expectRender("{{timefmt \"2006-01-02T15:04:05Z07:00 1/2 Janet\" .z}}", data, "2026-12-31T00:00:00+02:00 12/31 Janet");
    try expectRender("{{timefmt \"Z07:00 .999|\" .t}}{{timefmt \"x\" .missing}}", data, "Z |");
    try expectFail("{{timefmt \"2006\" \"yesterday\"}}", data, "template: 1:3: error calling timefmt: cannot parse \"yesterday\" as an RFC 3339 time");
}

test "color, autocolor and hyperlink follow the output" {
    const on: Options = .{ .color = true, .tty = true };
    try expectRenderOpts("{{color \"green\" \"ok\"}}|{{autocolor \"red+b\" .n}}|{{color \"blue+u:white\" \"x\"}}|{{color \"white+h\" \"y\"}}|{{color \"208\" \"z\"}}", "{\"n\":7}", on, "\x1b[32mok\x1b[0m|\x1b[1;31m7\x1b[0m|\x1b[4;34;47mx\x1b[0m|\x1b[97my\x1b[0m|\x1b[38;5;208mz\x1b[0m");
    try expectRenderOpts("{{color \"green\" \"ok\"}}|{{autocolor \"red+b\" .n}}", "{\"n\":7}", .{}, "ok|7");
    try expectRenderOpts("{{hyperlink .url .title}}|{{hyperlink .url \"\"}}", "{\"url\":\"http://x/1\",\"title\":\"T\"}", on, "\x1b]8;;http://x/1\x1b\\T\x1b]8;;\x1b\\|\x1b]8;;http://x/1\x1b\\http://x/1\x1b]8;;\x1b\\");
    try expectRenderOpts("{{hyperlink .url .title}}", "{\"url\":\"http://x/1\",\"title\":\"T\"}", .{}, "T");
    try expectFail("{{color \"mauve\" \"x\"}}", "{}", "template: 1:3: error calling color: unknown style \"mauve\"");
}

test "tablerow and tablerender" {
    const rows = "[{\"n\":7,\"t\":\"Crash\"},{\"n\":12,\"t\":\"A longer\\ttitle\"}]";
    try expectRenderOpts("{{range .}}{{tablerow .n .t}}{{end}}", rows, .{ .tty = true }, "7   Crash\n12  A longer title\n");
    try expectRenderOpts("{{range .}}{{tablerow .n .t}}{{end}}", rows, .{}, "7\tCrash\n12\tA longer title\n");
    try expectRenderOpts("head\n{{range .}}{{tablerow .n .t}}{{end}}{{tablerender}}tail\n", rows, .{ .tty = true }, "head\n7   Crash\n12  A longer title\ntail\n");
    try expectRenderOpts("{{range .}}{{tablerow (printf \"#%v\" .n | autocolor \"green\") .t}}{{end}}", rows, .{ .tty = true, .color = true }, "\x1b[32m#7\x1b[0m   Crash\n\x1b[32m#12\x1b[0m  A longer title\n");
}
