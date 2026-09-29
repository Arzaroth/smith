//! Splits a template into text and the tokens of its actions. Trim markers
//! are applied here, comments dropped.
const std = @import("std");
const Allocator = std.mem.Allocator;
const template = @import("../template.zig");
const Diagnostic = template.Diagnostic;
const Error = template.Error;

pub const Token = struct {
    tag: Tag,
    text: []const u8,
    pos: usize,
    /// Whitespace separates it from the token before it in the action.
    spaced: bool = false,

    pub const Tag = enum {
        text,
        open,
        close,
        pipe,
        lparen,
        rparen,
        declare,
        assign,
        comma,
        dot,
        field,
        variable,
        identifier,
        string,
        raw_string,
        char,
        number,
        invalid,
        eof,
    };
};

const space = " \t\r\n";

fn isSpace(c: u8) bool {
    return std.mem.indexOfScalar(u8, space, c) != null;
}

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn trimLeft(src: []const u8, i: usize) bool {
    return i + 1 < src.len and src[i] == '-' and isSpace(src[i + 1]);
}

fn trimRight(src: []const u8, i: usize) bool {
    return i + 3 < src.len and isSpace(src[i]) and src[i + 1] == '-' and std.mem.eql(u8, src[i + 2 .. i + 4], "}}");
}

pub fn lex(alloc: Allocator, src: []const u8, diag: *Diagnostic) Error![]const Token {
    var toks: std.ArrayList(Token) = .empty;
    var pos: usize = 0;
    var trim_next = false;
    while (true) {
        const open = std.mem.indexOfPos(u8, src, pos, "{{") orelse src.len;
        const trim = open < src.len and trimLeft(src, open + 2);
        var start = pos;
        var end = open;
        if (trim_next) while (start < end and isSpace(src[start])) {
            start += 1;
        };
        if (trim) while (end > start and isSpace(src[end - 1])) {
            end -= 1;
        };
        if (end > start) try toks.append(alloc, .{ .tag = .text, .text = src[start..end], .pos = start });
        if (open == src.len) break;
        var i = open + 2 + @as(usize, if (trim) 2 else 0);
        while (i < src.len and isSpace(src[i]) and trim) i += 1;
        if (std.mem.startsWith(u8, src[i..], "/*")) {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse return diag.fail(alloc, src, open, "unclosed comment", .{});
            i = close + 2;
            trim_next = trimRight(src, i);
            if (trim_next) i += 2;
            if (!std.mem.startsWith(u8, src[i..], "}}")) return diag.fail(alloc, src, open, "comment ends before closing delimiter", .{});
            pos = i + 2;
            continue;
        }
        try toks.append(alloc, .{ .tag = .open, .text = "{{", .pos = open });
        trim_next = false;
        var spaced = true;
        while (true) {
            if (i >= src.len) return diag.fail(alloc, src, open, "unclosed action", .{});
            if (trimRight(src, i)) {
                trim_next = true;
                try toks.append(alloc, .{ .tag = .close, .text = "}}", .pos = i + 2, .spaced = true });
                i += 4;
                break;
            }
            if (std.mem.startsWith(u8, src[i..], "}}")) {
                try toks.append(alloc, .{ .tag = .close, .text = "}}", .pos = i, .spaced = spaced });
                i += 2;
                break;
            }
            const c = src[i];
            if (isSpace(c)) {
                spaced = true;
                i += 1;
                continue;
            }
            const begin = i;
            const tag: Token.Tag = tag: switch (c) {
                '|' => {
                    i += 1;
                    break :tag .pipe;
                },
                '(' => {
                    i += 1;
                    break :tag .lparen;
                },
                ')' => {
                    i += 1;
                    break :tag .rparen;
                },
                ',' => {
                    i += 1;
                    break :tag .comma;
                },
                '=' => {
                    i += 1;
                    break :tag .assign;
                },
                ':' => {
                    if (i + 1 < src.len and src[i + 1] == '=') {
                        i += 2;
                        break :tag .declare;
                    }
                    i += 1;
                    break :tag .invalid;
                },
                '"', '\'' => {
                    i += 1;
                    while (i < src.len and src[i] != c and src[i] != '\n') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                    if (i >= src.len or src[i] != c) return diag.fail(alloc, src, begin, "unterminated {s}", .{if (c == '"') "quoted string" else "character constant"});
                    i += 1;
                    break :tag if (c == '"') .string else .char;
                },
                '`' => {
                    const close = std.mem.indexOfScalarPos(u8, src, i + 1, '`') orelse return diag.fail(alloc, src, begin, "unterminated raw quoted string", .{});
                    i = close + 1;
                    break :tag .raw_string;
                },
                '$' => {
                    i += 1;
                    while (i < src.len and isAlnum(src[i])) i += 1;
                    break :tag .variable;
                },
                '.' => {
                    if (i + 1 < src.len and std.ascii.isDigit(src[i + 1])) continue :tag '0';
                    i += 1;
                    if (i < src.len and isAlnum(src[i])) {
                        while (i < src.len and isAlnum(src[i])) i += 1;
                        break :tag .field;
                    }
                    break :tag .dot;
                },
                '+', '-', '0'...'9' => {
                    if (c == '+' or c == '-') {
                        const next = if (i + 1 < src.len) src[i + 1] else 0;
                        if (!std.ascii.isDigit(next) and next != '.') {
                            i += 1;
                            break :tag .invalid;
                        }
                        i += 1;
                    }
                    while (i < src.len) : (i += 1) {
                        const d = src[i];
                        if (isAlnum(d) or d == '.') continue;
                        if ((d == '+' or d == '-') and (src[i - 1] == 'e' or src[i - 1] == 'E')) continue;
                        break;
                    }
                    break :tag .number;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    while (i < src.len and isAlnum(src[i])) i += 1;
                    break :tag .identifier;
                },
                else => {
                    i += std.unicode.utf8ByteSequenceLength(c) catch 1;
                    i = @min(i, src.len);
                    break :tag .invalid;
                },
            };
            try toks.append(alloc, .{ .tag = tag, .text = src[begin..i], .pos = begin, .spaced = spaced });
            spaced = false;
        }
        pos = i;
    }
    try toks.append(alloc, .{ .tag = .eof, .text = "", .pos = src.len });
    return toks.toOwnedSlice(alloc);
}
