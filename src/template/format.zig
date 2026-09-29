//! Go's `fmt` verbs for `printf`, Go's reference-time layouts for `timefmt`,
//! and mgutz/ansi colour styles for `color`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const term = @import("../term.zig");
const exec = @import("exec.zig");

const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    zero: bool = false,
    sharp: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
};

const max_width = 10_000;

pub fn printf(alloc: Allocator, w: *Writer, format: []const u8, args: []const Value) Writer.Error!void {
    var next: usize = 0;
    var i: usize = 0;
    while (i < format.len) {
        const pct = std.mem.indexOfScalarPos(u8, format, i, '%') orelse {
            try w.writeAll(format[i..]);
            break;
        };
        try w.writeAll(format[i..pct]);
        i = pct + 1;
        var spec: Spec = .{};
        while (i < format.len) : (i += 1) switch (format[i]) {
            '-' => spec.minus = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '0' => spec.zero = true,
            '#' => spec.sharp = true,
            else => break,
        };
        spec.width = digits(format, &i);
        if (i < format.len and format[i] == '.') {
            i += 1;
            spec.precision = digits(format, &i) orelse 0;
        }
        if (i >= format.len) {
            try w.writeAll("%!(NOVERB)");
            break;
        }
        const n = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
        const verb = format[i..@min(i + n, format.len)];
        i += verb.len;
        if (std.mem.eql(u8, verb, "%")) {
            try w.writeByte('%');
            continue;
        }
        if ((spec.width orelse 0) > max_width or (spec.precision orelse 0) > max_width) {
            try w.writeAll("%!(BADWIDTH)");
            continue;
        }
        if (next >= args.len) {
            try w.print("%!{s}(MISSING)", .{verb});
            continue;
        }
        try one(alloc, w, if (verb.len == 1) verb[0] else 0, verb, spec, args[next]);
        next += 1;
    }
    if (next < args.len) {
        try w.writeAll("%!(EXTRA ");
        for (args[next..], next..) |v, k| {
            if (k > next) try w.writeAll(", ");
            try w.print("{s}={f}", .{ typeName(v), exec.fmtValue(v) });
        }
        try w.writeByte(')');
    }
}

fn digits(s: []const u8, i: *usize) ?usize {
    const start = i.*;
    var n: usize = 0;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) n = @min(n *| 10 +| (s[i.*] - '0'), max_width + 1);
    return if (i.* > start) n else null;
}

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

pub fn integer(v: Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.2e18) @intFromFloat(f) else null,
        else => null,
    };
}

pub fn float(v: Value) ?f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn one(alloc: Allocator, w: *Writer, verb: u8, verb_text: []const u8, spec: Spec, v: Value) Writer.Error!void {
    var buf: [128]u8 = undefined;
    var scratch: Writer = .fixed(&buf);
    switch (verb) {
        'v', 's' => switch (v) {
            .integer => |n| if (verb == 'v') return int(w, n, 10, false, spec),
            .float => |f| if (verb == 'v') {
                exec.writeFloat(&scratch, f) catch unreachable;
                return number(w, scratch.buffered(), spec);
            },
            else => {},
        },
        'd', 'x', 'X', 'o', 'b', 'c' => if (integer(v)) |n| {
            if (verb == 'c') {
                var cp: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(std.math.cast(u21, n) orelse 0xfffd, &cp) catch std.unicode.utf8Encode(0xfffd, &cp) catch unreachable;
                return pad(w, cp[0..len], spec, false);
            }
            const base: u8 = switch (verb) {
                'd' => 10,
                'o' => 8,
                'b' => 2,
                else => 16,
            };
            return int(w, n, base, verb == 'X', spec);
        } else if (v == .string and (verb == 'x' or verb == 'X')) {
            var out: Writer.Allocating = .init(alloc);
            defer out.deinit();
            for (v.string) |c| try out.writer.print("{x:0>2}", .{c});
            const hex = out.written();
            if (verb == 'X') for (hex) |*c| {
                c.* = std.ascii.toUpper(c.*);
            };
            return pad(w, hex, spec, false);
        },
        'f', 'F', 'e', 'E', 'g', 'G' => if (float(v)) |f| {
            if (verb == 'g' or verb == 'G') {
                exec.writeFloat(&scratch, f) catch unreachable;
            } else if ((verb == 'f' or verb == 'F') and std.math.isFinite(f)) {
                return number(w, try fixed(alloc, f, spec.precision orelse 6), spec);
            } else {
                var fbuf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
                const mode: std.fmt.float.Mode = if (verb == 'f' or verb == 'F') .decimal else .scientific;
                const s = std.fmt.float.render(&fbuf, f, .{ .mode = mode, .precision = spec.precision orelse 6 }) catch "?";
                if (mode == .scientific) {
                    const e = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
                    const exp = std.fmt.parseInt(i32, s[@min(e + 1, s.len)..], 10) catch 0;
                    scratch.print("{s}{c}{c}{d:0>2}", .{ s[0..e], verb, @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch unreachable;
                } else scratch.writeAll(s) catch unreachable;
            }
            return number(w, scratch.buffered(), spec);
        },
        't' => if (v == .bool) return pad(w, if (v.bool) "true" else "false", spec, false),
        'q' => {
            var out: Writer.Allocating = .init(alloc);
            defer out.deinit();
            if (v == .integer) {
                try quote(&out.writer, "", '\'', v.integer);
            } else {
                var text: Writer.Allocating = .init(alloc);
                defer text.deinit();
                try exec.write(&text.writer, v);
                try quote(&out.writer, text.written(), '"', null);
            }
            return pad(w, out.written(), spec, false);
        },
        else => {},
    }
    if (verb == 'v' or verb == 's') {
        var out: Writer.Allocating = .init(alloc);
        defer out.deinit();
        try exec.write(&out.writer, v);
        var s: []const u8 = out.written();
        if (spec.precision) |p| s = prefix(s, p);
        return pad(w, s, spec, false);
    }
    if (v == .null) return w.print("%!{s}(<nil>)", .{verb_text});
    try w.print("%!{s}({s}={f})", .{ verb_text, typeName(v), exec.fmtValue(v) });
}

/// `f` with `precision` decimals, rounded half to even on its exact binary
/// value as Go does; std's rendering rounds the shortest decimal instead.
fn fixed(alloc: Allocator, f: f64, precision: usize) Writer.Error![]const u8 {
    const Int = std.math.big.int.Managed;
    const bits: u64 = @bitCast(@abs(f));
    const biased: i32 = @intCast(bits >> 52);
    const mantissa = bits & ((1 << 52) - 1);
    const m: u64 = if (biased == 0) mantissa else mantissa | (1 << 52);
    const e: i32 = if (biased == 0) -1074 else biased - 1075;
    var n = Int.initSet(alloc, m) catch return error.WriteFailed;
    const ten = Int.initSet(alloc, 10) catch return error.WriteFailed;
    var scale = Int.init(alloc) catch return error.WriteFailed;
    scale.pow(&ten, @intCast(precision)) catch return error.WriteFailed;
    var q = Int.init(alloc) catch return error.WriteFailed;
    q.mul(&n, &scale) catch return error.WriteFailed;
    if (e >= 0) {
        n.shiftLeft(&q, @intCast(e)) catch return error.WriteFailed;
        q.swap(&n);
    } else {
        var d = Int.initSet(alloc, 1) catch return error.WriteFailed;
        d.shiftLeft(&d, @intCast(-e)) catch return error.WriteFailed;
        var r = Int.init(alloc) catch return error.WriteFailed;
        n.divTrunc(&r, &q, &d) catch return error.WriteFailed;
        r.shiftLeft(&r, 1) catch return error.WriteFailed;
        const order = r.order(d);
        if (order == .gt or (order == .eq and !n.isEven())) n.addScalar(&n, 1) catch return error.WriteFailed;
        q.swap(&n);
    }
    const text = q.toString(alloc, 10, .lower) catch return error.WriteFailed;
    var out: Writer.Allocating = .init(alloc);
    if (std.math.signbit(f)) try out.writer.writeByte('-');
    if (text.len <= precision) {
        try out.writer.writeAll("0");
        if (precision > 0) {
            try out.writer.writeByte('.');
            try out.writer.splatByteAll('0', precision - text.len);
            try out.writer.writeAll(text);
        }
    } else {
        try out.writer.writeAll(text[0 .. text.len - precision]);
        if (precision > 0) try out.writer.print(".{s}", .{text[text.len - precision ..]});
    }
    return out.written();
}

/// The first `n` codepoints of `s`.
pub fn prefix(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var k: usize = 0;
    while (k < n and i < s.len) : (k += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(i + len, s.len);
    }
    return s[0..i];
}

fn width(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn pad(w: *Writer, s: []const u8, spec: Spec, numeric: bool) Writer.Error!void {
    const n = spec.width orelse 0;
    const len = width(s);
    if (len >= n) return w.writeAll(s);
    if (spec.minus) {
        try w.writeAll(s);
        return w.splatByteAll(' ', n - len);
    }
    if (spec.zero) {
        var body = s;
        if (numeric and body.len > 0 and (body[0] == '-' or body[0] == '+' or body[0] == ' ')) {
            try w.writeByte(body[0]);
            body = body[1..];
        }
        try w.splatByteAll('0', n - len);
        return w.writeAll(body);
    }
    try w.splatByteAll(' ', n - len);
    try w.writeAll(s);
}

fn number(w: *Writer, s: []const u8, spec: Spec) Writer.Error!void {
    if (s.len == 0 or s[0] == '-' or !(spec.plus or spec.space)) return pad(w, s, spec, true);
    var buf: [max_width + 400]u8 = undefined;
    buf[0] = if (spec.plus) '+' else ' ';
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[1..][0..n], s[0..n]);
    try pad(w, buf[0 .. n + 1], spec, true);
}

fn int(w: *Writer, n: i64, base: u8, upper: bool, spec: Spec) Writer.Error!void {
    var buf: [max_width + 72]u8 = undefined;
    var out: Writer = .fixed(&buf);
    if (n < 0) out.writeByte('-') catch unreachable else if (spec.plus) out.writeByte('+') catch unreachable else if (spec.space) out.writeByte(' ') catch unreachable;
    if (spec.sharp) out.writeAll(switch (base) {
        16 => if (upper) "0X" else "0x",
        8 => "0",
        2 => "0b",
        else => "",
    }) catch unreachable;
    var digit_buf: [64]u8 = undefined;
    const body = digit_buf[0..std.fmt.printInt(&digit_buf, @abs(n), base, if (upper) .upper else .lower, .{})];
    if (spec.precision) |p| if (p > body.len) out.splatByteAll('0', p - body.len) catch unreachable;
    out.writeAll(body) catch unreachable;
    var s = spec;
    if (spec.precision != null) s.zero = false;
    try pad(w, out.buffered(), s, true);
}

/// Go's strconv.Quote, or QuoteRune when `rune` is set.
fn quote(w: *Writer, s: []const u8, delim: u8, rune: ?i64) Writer.Error!void {
    try w.writeByte(delim);
    if (rune) |r| {
        var cp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(std.math.cast(u21, r) orelse 0xfffd, &cp) catch std.unicode.utf8Encode(0xfffd, &cp) catch unreachable;
        try quoteText(w, cp[0..len], delim);
    } else try quoteText(w, s, delim);
    try w.writeByte(delim);
}

fn quoteText(w: *Writer, s: []const u8, delim: u8) Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (len == 0 or i + len > s.len or (len > 1 and !std.unicode.utf8ValidateSlice(s[i .. i + len]))) {
            try w.print("\\x{x:0>2}", .{c});
            i += 1;
            continue;
        }
        if (len > 1) {
            const cp = std.unicode.utf8Decode(s[i .. i + len]) catch unreachable;
            if (cp < 0xa0) try w.print("\\u{x:0>4}", .{cp}) else try w.writeAll(s[i .. i + len]);
            i += len;
            continue;
        }
        i += 1;
        switch (c) {
            0x07 => try w.writeAll("\\a"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x0b => try w.writeAll("\\v"),
            '\\' => try w.writeAll("\\\\"),
            else => if (c == delim) {
                try w.writeByte('\\');
                try w.writeByte(c);
            } else if (c < 0x20 or c == 0x7f) {
                try w.print("\\x{x:0>2}", .{c});
            } else try w.writeByte(c),
        }
    }
}

const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// Formats an RFC 3339 timestamp with a Go layout; false when it does not parse.
pub fn timefmt(w: *Writer, layout: []const u8, stamp: []const u8) Writer.Error!bool {
    const unix = term.parseTime(stamp) orelse return false;
    var rest = stamp[19..];
    var frac: []const u8 = "";
    if (rest.len > 0 and rest[0] == '.') {
        var k: usize = 1;
        while (k < rest.len and std.ascii.isDigit(rest[k])) k += 1;
        frac = rest[1..k];
        rest = rest[k..];
    }
    const utc = rest[0] == 'Z' or rest[0] == 'z';
    const offset: i64 = if (utc) 0 else off: {
        const o = ((rest[1] - '0') * 10 + (rest[2] - '0')) * @as(i64, 3600) + ((rest[4] - '0') * 10 + (rest[5] - '0')) * @as(i64, 60);
        break :off if (rest[0] == '-') -o else o;
    };
    const local = unix + offset;
    const day = @divFloor(local, 86400);
    const secs = local - day * 86400;
    const date = civil(day);
    const hour: u64 = @intCast(@divFloor(secs, 3600));
    const minute: u64 = @intCast(@mod(@divFloor(secs, 60), 60));
    const second: u64 = @intCast(@mod(secs, 60));
    const weekday: usize = @intCast(@mod(day + 4, 7));
    const hour12 = if (hour % 12 == 0) 12 else hour % 12;

    var i: usize = 0;
    while (i < layout.len) {
        const r = layout[i..];
        if (startsWord(r, "January")) {
            try w.writeAll(months[date.month - 1]);
            i += 7;
        } else if (startsWord(r, "Jan")) {
            try w.writeAll(months[date.month - 1][0..3]);
            i += 3;
        } else if (startsWord(r, "Monday")) {
            try w.writeAll(days[weekday]);
            i += 6;
        } else if (startsWord(r, "Mon")) {
            try w.writeAll(days[weekday][0..3]);
            i += 3;
        } else if (std.mem.startsWith(u8, r, "MST")) {
            if (utc) try w.writeAll("UTC") else try zone(w, offset, false, false);
            i += 3;
        } else if (std.mem.startsWith(u8, r, "2006")) {
            try w.print("{d:0>4}", .{@as(u64, @intCast(date.year))});
            i += 4;
        } else if (std.mem.startsWith(u8, r, "_2") and !std.mem.startsWith(u8, r, "_2006")) {
            try w.print("{d: >2}", .{date.day});
            i += 2;
        } else if (r.len >= 2 and r[0] == '0' and r[1] >= '1' and r[1] <= '6') {
            try w.print("{d:0>2}", .{switch (r[1]) {
                '1' => date.month,
                '2' => date.day,
                '3' => hour12,
                '4' => minute,
                '5' => second,
                else => @as(u64, @intCast(@mod(date.year, 100))),
            }});
            i += 2;
        } else if (std.mem.startsWith(u8, r, "15")) {
            try w.print("{d:0>2}", .{hour});
            i += 2;
        } else if (r[0] >= '1' and r[0] <= '5') {
            try w.print("{d}", .{switch (r[0]) {
                '1' => date.month,
                '2' => date.day,
                '3' => hour12,
                '4' => minute,
                else => second,
            }});
            i += 1;
        } else if (std.mem.startsWith(u8, r, "PM") or std.mem.startsWith(u8, r, "pm")) {
            const pm = hour >= 12;
            try w.writeAll(if (r[0] == 'P') (if (pm) "PM" else "AM") else (if (pm) "pm" else "am"));
            i += 2;
        } else if (r[0] == '-' or r[0] == 'Z') {
            const zones = [_][]const u8{ "070000", "07:00:00", "0700", "07:00", "07" };
            for (zones) |z| {
                if (std.mem.startsWith(u8, r[1..], z)) {
                    if (r[0] == 'Z' and offset == 0) try w.writeByte('Z') else try zone(w, offset, std.mem.indexOfScalar(u8, z, ':') != null, z.len == 2);
                    if (z.len >= 6 and !(r[0] == 'Z' and offset == 0)) try w.print("{s}00", .{if (z.len == 8) ":" else ""});
                    i += 1 + z.len;
                    break;
                }
            } else {
                try w.writeByte(r[0]);
                i += 1;
            }
        } else if ((r[0] == '.' or r[0] == ',') and r.len > 1 and (r[1] == '0' or r[1] == '9')) {
            var j: usize = 1;
            while (j < r.len and r[j] == r[1]) j += 1;
            if (j < r.len and std.ascii.isDigit(r[j])) {
                try w.writeAll(r[0..j]);
            } else {
                const n = j - 1;
                var d: [9]u8 = @splat('0');
                const have = @min(frac.len, 9);
                @memcpy(d[0..have], frac[0..have]);
                var shown: []const u8 = d[0..@min(n, 9)];
                if (r[1] == '9') shown = std.mem.trimEnd(u8, shown, "0");
                if (shown.len > 0 or r[1] == '0') {
                    try w.writeByte(r[0]);
                    try w.writeAll(shown);
                }
            }
            i += j;
        } else {
            try w.writeByte(r[0]);
            i += 1;
        }
    }
    return true;
}

/// `word` starts `s` and is not the start of a longer lowercase word, as Go
/// tells "Jan" from "Janet".
fn startsWord(s: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, s, word)) return false;
    return s.len == word.len or !std.ascii.isLower(s[word.len]);
}

fn zone(w: *Writer, offset: i64, colon: bool, hours_only: bool) Writer.Error!void {
    const abs: u64 = @abs(offset);
    try w.writeByte(if (offset < 0) '-' else '+');
    try w.print("{d:0>2}", .{abs / 3600});
    if (hours_only) return;
    if (colon) try w.writeByte(':');
    try w.print("{d:0>2}", .{abs / 60 % 60});
}

const Date = struct { year: i64, month: u64, day: u64 };

fn civil(days_since_epoch: i64) Date {
    const z = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = @intCast(m), .day = @intCast(d) };
}

const colors = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

/// The SGR sequence for an mgutz/ansi style ("green", "red+b",
/// "white+h:blue"), or null when it names no colour or attribute.
pub fn style(alloc: Allocator, spec: []const u8) error{OutOfMemory}!?[]const u8 {
    var codes: std.ArrayList(u8) = .empty;
    var halves = std.mem.splitScalar(u8, spec, ':');
    var bg = false;
    while (halves.next()) |half| : (bg = true) {
        if (bg and half.len == 0) continue;
        const plus = std.mem.indexOfScalar(u8, half, '+') orelse half.len;
        const name = half[0..plus];
        const attrs = if (plus < half.len) half[plus + 1 ..] else "";
        const bright = std.mem.indexOfScalar(u8, attrs, 'h') != null;
        for (attrs) |a| {
            if (bg) {
                if (a != 'h') return null;
                continue;
            }
            const code: []const u8 = switch (a) {
                'b' => "1",
                'd' => "2",
                'u' => "4",
                'B' => "5",
                'i' => "7",
                's' => "9",
                'h' => continue,
                else => return null,
            };
            try sep(alloc, &codes);
            try codes.appendSlice(alloc, code);
        }
        if (name.len == 0 or std.mem.eql(u8, name, "default")) continue;
        try sep(alloc, &codes);
        if (std.fmt.parseInt(u8, name, 10)) |n| {
            try codes.print(alloc, "{d};5;{d}", .{ @as(u8, if (bg) 48 else 38), n });
        } else |_| {
            const index = for (colors, 0..) |c, k| {
                if (std.mem.eql(u8, c, name)) break k;
            } else return null;
            const base: usize = if (bg) (if (bright) 100 else 40) else if (bright) 90 else 30;
            try codes.print(alloc, "{d}", .{base + index});
        }
    }
    if (codes.items.len == 0) return "";
    return try std.fmt.allocPrint(alloc, "\x1b[{s}m", .{codes.items});
}

fn sep(alloc: Allocator, codes: *std.ArrayList(u8)) !void {
    if (codes.items.len > 0) try codes.append(alloc, ';');
}

/// Columns a terminal gives `s`, not counting escape sequences.
pub fn visibleWidth(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1;
            i += 1;
        } else if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == ']') {
            i += 2;
            while (i < s.len and s[i] != 0x07 and !(s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\')) i += 1;
            i += if (i < s.len and s[i] == 0x1b) 2 else 1;
        } else {
            i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            n += 1;
        }
    }
    return n;
}
