//! Terminal output: colours (TTY only, NO_COLOR honoured), aligned tables,
//! RFC 3339 timestamps rendered as "3 hours ago".
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Ctx = @import("Ctx.zig");

pub const Color = enum {
    none,
    bold,
    dim,
    red,
    green,
    yellow,
    magenta,
    cyan,

    fn code(c: Color) []const u8 {
        return switch (c) {
            .none => "",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
        };
    }
};

pub fn useColor(env: *const std.process.Environ.Map, tty: bool) bool {
    if (env.get("CLICOLOR_FORCE")) |v| if (v.len > 0 and !std.mem.eql(u8, v, "0")) return true;
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return false;
    if (env.get("TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return tty;
}

pub fn paint(ctx: *const Ctx, w: *Writer, color: Color, text_in: []const u8) !void {
    const text = try clean(ctx.alloc, text_in, true);
    if (ctx.color and color != .none) {
        try w.print("{s}{s}\x1b[0m", .{ color.code(), text });
    } else {
        try w.writeAll(text);
    }
}

pub const Cell = struct {
    text: []const u8,
    color: Color = .none,
    /// Only printed when piped: what colour says on a terminal (a state).
    pipe: bool = false,
};

/// Rows of cells: space-aligned on a TTY, tab-separated otherwise so the
/// output stays easy to cut and grep.
pub const Table = struct {
    rows: std.ArrayList([]const Cell) = .empty,

    pub fn add(t: *Table, alloc: Allocator, cells: []const Cell) !void {
        const copy = try alloc.dupe(Cell, cells);
        for (copy) |*c| c.text = try clean(alloc, c.text, false);
        try t.rows.append(alloc, copy);
    }

    pub fn write(t: *const Table, ctx: *const Ctx) !void {
        const w = ctx.out;
        if (!ctx.stdout_tty) {
            for (t.rows.items) |row| {
                for (row, 0..) |cell, i| {
                    if (i > 0) try w.writeByte('\t');
                    try w.writeAll(cell.text);
                }
                try w.writeByte('\n');
            }
            return;
        }
        var widths: [16]usize = @splat(0);
        var columns: usize = 0;
        for (t.rows.items) |row| {
            var j: usize = 0;
            for (row) |cell| {
                if (cell.pipe) continue;
                widths[j] = @max(widths[j], displayWidth(cell.text));
                j += 1;
            }
            columns = @max(columns, j);
        }
        for (t.rows.items) |row| {
            var j: usize = 0;
            for (row) |cell| {
                if (cell.pipe) continue;
                if (j > 0) try w.writeAll("  ");
                try paint(ctx, w, cell.color, cell.text);
                if (j + 1 < columns) try w.splatByteAll(' ', widths[j] - displayWidth(cell.text));
                j += 1;
            }
            try w.writeByte('\n');
        }
    }
};

pub fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Shortens `s` to at most `max` codepoints, ending with "...".
pub fn truncate(alloc: Allocator, s: []const u8, max: usize) ![]const u8 {
    if (displayWidth(s) <= max or max < 4) return s;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var n: usize = 0;
    while (n < max - 3) : (n += 1) _ = it.nextCodepointSlice();
    return std.fmt.allocPrint(alloc, "{s}...", .{s[0..it.i]});
}

/// Unix seconds from an RFC 3339 timestamp, or null when it does not parse.
pub fn parseTime(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        rest = rest[i..];
    }
    var offset: i64 = 0;
    if (rest.len >= 6 and (rest[0] == '+' or rest[0] == '-')) {
        const oh = std.fmt.parseInt(i64, rest[1..3], 10) catch return null;
        const om = std.fmt.parseInt(i64, rest[4..6], 10) catch return null;
        offset = (oh * 60 + om) * 60;
        if (rest[0] == '-') offset = -offset;
    } else if (!(rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z'))) {
        return null;
    }
    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset;
}

fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// "3 hours ago", like gh.
pub fn ago(alloc: Allocator, now: i64, timestamp: ?[]const u8) ![]const u8 {
    const t = parseTime(timestamp orelse return "") orelse return timestamp.?;
    const d = now - t;
    if (d < 60) return "less than a minute ago";
    const units = [_]struct { secs: i64, name: []const u8 }{
        .{ .secs = 365 * 86400, .name = "year" },
        .{ .secs = 30 * 86400, .name = "month" },
        .{ .secs = 86400, .name = "day" },
        .{ .secs = 3600, .name = "hour" },
        .{ .secs = 60, .name = "minute" },
    };
    for (units) |u| {
        if (d >= u.secs) {
            const n = @divFloor(d, u.secs);
            const prefix = if (u.secs == 3600 or u.secs >= 30 * 86400) "about " else "";
            return std.fmt.allocPrint(alloc, "{s}{d} {s}{s} ago", .{ prefix, n, u.name, if (n == 1) "" else "s" });
        }
    }
    unreachable;
}

/// "1m 23s" from two timestamps; empty when either is missing or unset.
pub fn duration(alloc: Allocator, start: ?[]const u8, stop: ?[]const u8) ![]const u8 {
    const a = parseTime(start orelse return "") orelse return "";
    const b = parseTime(stop orelse return "") orelse return "";
    if (a <= 0 or b < a) return "";
    const d = b - a;
    if (d < 60) return std.fmt.allocPrint(alloc, "{d}s", .{d});
    if (d < 3600) return std.fmt.allocPrint(alloc, "{d}m {d}s", .{ @divFloor(d, 60), @mod(d, 60) });
    return std.fmt.allocPrint(alloc, "{d}h {d}m", .{ @divFloor(d, 3600), @divFloor(@mod(d, 3600), 60) });
}

const testing = std.testing;

test parseTime {
    try testing.expectEqual(@as(?i64, 0), parseTime("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1790645904), parseTime("2026-09-29T01:38:24Z"));
    try testing.expectEqual(parseTime("2026-09-29T01:38:24Z"), parseTime("2026-09-29T03:38:24+02:00"));
    try testing.expectEqual(parseTime("2026-09-29T01:38:24Z"), parseTime("2026-09-29T01:38:24.123456Z"));
    try testing.expectEqual(@as(?i64, null), parseTime("yesterday"));
}

test ago {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = parseTime("2026-09-29T12:00:00Z").?;
    try testing.expectEqualStrings("less than a minute ago", try ago(a, now, "2026-09-29T11:59:30Z"));
    try testing.expectEqualStrings("5 minutes ago", try ago(a, now, "2026-09-29T11:55:00Z"));
    try testing.expectEqualStrings("about 1 hour ago", try ago(a, now, "2026-09-29T10:30:00Z"));
    try testing.expectEqualStrings("3 days ago", try ago(a, now, "2026-09-26T12:00:00Z"));
    try testing.expectEqualStrings("", try ago(a, now, null));
}

test duration {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("1m 5s", try duration(a, "2026-09-29T12:00:00Z", "2026-09-29T12:01:05Z"));
    try testing.expectEqualStrings("", try duration(a, "1970-01-01T01:00:00+01:00", "2026-09-29T12:01:05Z"));
}

test truncate {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("abcdefg", try truncate(a, "abcdefg", 10));
    try testing.expectEqualStrings("abc...", try truncate(a, "abcdefghij", 6));
    try testing.expectEqualStrings("été...", try truncate(a, "étéàèùìò", 6));
}

/// Server text made safe to print: control characters, which could carry
/// terminal escape sequences (clipboard writes, forged lines), become `?`.
/// `lines` keeps newlines and tabs, for bodies and logs; table cells lose
/// them so piped output keeps one row per line.
pub fn clean(alloc: Allocator, s: []const u8, lines: bool) ![]const u8 {
    var dirty = false;
    for (s, 0..) |c, i| {
        if (isControl(s, i, c, lines)) {
            dirty = true;
            break;
        }
    }
    if (!dirty) return s;
    var out = try alloc.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) {
            out[n] = '?';
            n += 1;
            i += 1;
        } else if (isControl(s, i, c, lines)) {
            out[n] = if (!lines and (c == '\t' or c == '\n')) ' ' else '?';
            n += 1;
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

fn isControl(s: []const u8, i: usize, c: u8, lines: bool) bool {
    if (c == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) return true;
    if (lines and (c == '\n' or c == '\t')) return false;
    return c < 0x20 or c == 0x7f;
}

/// A writer that passes text on to `inner` the way `clean` would with
/// `lines`, for smith's own messages on a terminal, which quote server text.
pub const Scrubber = struct {
    inner: *Writer,
    held: bool = false,
    interface: Writer,

    pub fn init(inner: *Writer, buffer: []u8) Scrubber {
        return .{ .inner = inner, .interface = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = buffer } };
    }

    fn put(s: *Scrubber, bytes: []const u8) Writer.Error!void {
        for (bytes) |c| {
            if (s.held) {
                s.held = false;
                if (c >= 0x80 and c <= 0x9f) {
                    try s.inner.writeByte('?');
                    continue;
                }
                try s.inner.writeByte(0xc2);
            }
            if (c == 0xc2) {
                s.held = true;
            } else try s.inner.writeByte(if (isControl(&.{c}, 0, c, true)) '?' else c);
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const s: *Scrubber = @alignCast(@fieldParentPtr("interface", w));
        try s.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try s.put(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try s.put(last);
        return n + last.len * splat;
    }

    fn flush(w: *Writer) Writer.Error!void {
        const s: *Scrubber = @alignCast(@fieldParentPtr("interface", w));
        try s.put(w.buffered());
        w.end = 0;
        if (s.held) {
            s.held = false;
            try s.inner.writeByte(0xc2);
        }
        try s.inner.flush();
    }
};

test Scrubber {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: [4]u8 = undefined;
    var s: Scrubber = .init(&out.writer, &buf);
    try s.interface.print("✓ {s}\n", .{"x\x1b]52;c;y\x07 \xc2\x9b2J é"});
    try s.interface.flush();
    try testing.expectEqualStrings("✓ x?]52;c;y? ?2J é\n", out.written());
}

test clean {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("plain", try clean(a, "plain", false));
    try testing.expectEqualStrings("?]52;c;cm0gLXJmIH4=?x", try clean(a, "\x1b]52;c;cm0gLXJmIH4=\x07x", false));
    try testing.expectEqualStrings("a b", try clean(a, "a\tb", false));
    try testing.expectEqualStrings("a\n\tb?", try clean(a, "a\n\tb\x1b", true));
    try testing.expectEqualStrings("x?y", try clean(a, "x\xc2\x9by", true));
    try testing.expectEqualStrings("été", try clean(a, "été", false));
}

/// `#12` on a terminal, `12` when piped.
pub fn num(ctx: *const Ctx, n: i64) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "{s}{d}", .{ if (ctx.stdout_tty) "#" else "", n });
}

/// "3 hours ago" on a terminal, the timestamp as the API sent it when piped.
pub fn when(ctx: *const Ctx, timestamp: ?[]const u8) ![]const u8 {
    if (!ctx.stdout_tty) return timestamp orelse "";
    return ago(ctx.alloc, ctx.now, timestamp);
}

/// Shortened to `max` on a terminal, whole when piped.
pub fn fit(ctx: *const Ctx, s: []const u8, max: usize) ![]const u8 {
    return if (ctx.stdout_tty) truncate(ctx.alloc, s, max) else s;
}

/// "1.2 MiB"
pub fn size(alloc: Allocator, bytes: i64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v: f64 = @floatFromInt(@max(bytes, 0));
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    if (u == 0) return std.fmt.allocPrint(alloc, "{d} B", .{bytes});
    return std.fmt.allocPrint(alloc, "{d:.1} {s}", .{ v, units[u] });
}

/// Shell-style `*` and `?` matching, for asset and name patterns.
pub fn glob(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = n;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test size {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("512 B", try size(arena.allocator(), 512));
    try testing.expectEqualStrings("1.5 KiB", try size(arena.allocator(), 1536));
    try testing.expectEqualStrings("1.7 MiB", try size(arena.allocator(), 1799688));
}

test glob {
    try testing.expect(glob("*.tar.gz", "smith-1-x86_64.tar.gz"));
    try testing.expect(glob("smith-?-*", "smith-1-linux"));
    try testing.expect(!glob("*.zip", "smith.tar.gz"));
    try testing.expect(glob("*", ""));
}
