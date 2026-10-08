//! The machine's offset from UTC, for dates a user types or reads: `TZ` (a
//! zone name or file, else a POSIX rule; empty means UTC, as in glibc) or
//! `/etc/localtime`, through `std.tz`. Past a zone file's last transition,
//! which is where current dates fall in slim zone files, its POSIX rule
//! footer decides.
const std = @import("std");
const Ctx = @import("Ctx.zig");

/// Seconds east of UTC at `unix`; 0 when the zone cannot be read.
pub fn offset(ctx: *Ctx, unix: i64) i32 {
    const tz = ctx.env.get("TZ") orelse return fromFile(ctx, "/etc/localtime", unix) orelse 0;
    const spec = if (tz.len > 0 and tz[0] == ':') tz[1..] else tz;
    if (spec.len == 0) return 0;
    const path = if (spec[0] == '/')
        spec
    else if (std.mem.indexOf(u8, spec, "..") == null)
        std.fmt.allocPrint(ctx.alloc, "/usr/share/zoneinfo/{s}", .{spec}) catch return 0
    else
        "";
    if (path.len > 0) if (fromFile(ctx, path, unix)) |o| return o;
    return rule(spec, unix) orelse 0;
}

/// `YYYY-MM-DD` of the local day `unix` falls on.
pub fn date(ctx: *Ctx, unix: i64, buf: *[16]u8) []const u8 {
    const d = civil(@divFloor(unix + offset(ctx, unix), 86400));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(std.math.clamp(d.year, 0, 99999))), d.month, d.day }) catch unreachable;
}

/// The UTC second at which the local day `days` (since the epoch) ends: the
/// later one when a fall-back makes 23:59:59 happen twice.
pub fn endOfDay(ctx: *Ctx, days: i64) i64 {
    const local = days * 86400 + 86399;
    var best: ?i64 = null;
    for ([_]i64{ local - 86400, local, local + 86400 }) |near| {
        const o = offset(ctx, near);
        const candidate = local - o;
        if (offset(ctx, candidate) == o and (best == null or candidate > best.?)) best = candidate;
    }
    return best orelse local - offset(ctx, local - offset(ctx, local));
}

/// `unix` as an RFC 3339 UTC timestamp; an error outside years 0 to 9999.
pub fn utc(alloc: std.mem.Allocator, unix: i64) ![]const u8 {
    const days = @divFloor(unix, 86400);
    const secs = unix - days * 86400;
    const d = civil(days);
    if (d.year < 0 or d.year > 9999) return error.OutOfRange;
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u64, @intCast(d.year)), d.month, d.day, @as(u64, @intCast(@divFloor(secs, 3600))), @as(u64, @intCast(@mod(@divFloor(secs, 60), 60))), @as(u64, @intCast(@mod(secs, 60))) });
}

fn fromFile(ctx: *Ctx, path: []const u8, unix: i64) ?i32 {
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(ctx.io, path, .{}) catch return null;
    if (stat.kind != .file) return null;
    const bytes = cwd.readFileAlloc(ctx.io, path, ctx.alloc, .limited(1024 * 1024)) catch return null;
    var reader: std.Io.Reader = .fixed(bytes);
    const tz = std.tz.Tz.parse(ctx.alloc, &reader) catch return null;
    var i = tz.transitions.len;
    while (i > 0 and tz.transitions[i - 1].ts > unix) i -= 1;
    if (i == tz.transitions.len) if (tz.footer) |f| if (rule(f, unix)) |o| return o;
    if (i > 0) return tz.transitions[i - 1].timetype.offset;
    return if (tz.timetypes.len > 0) tz.timetypes[0].offset else null;
}

/// Evaluates a POSIX TZ rule such as `CET-1CEST,M3.5.0,M10.5.0/3` at `unix`;
/// a daylight name without dates takes the US rules, as glibc does.
fn rule(s: []const u8, unix: i64) ?i32 {
    var p: Parser = .{ .s = s };
    if (!p.name()) return null;
    const std_off = -(p.offset() orelse return null);
    if (p.i == s.len) return std_off;
    if (!p.name()) return std_off;
    var dst_off = std_off + 3600;
    if (p.i < s.len and s[p.i] != ',') dst_off = -(p.offset() orelse return null);
    if (p.i == s.len) p = .{ .s = ",M3.2.0,M11.1.0" };
    if (!p.eat(',')) return std_off;
    const start = p.rule() orelse return null;
    if (!p.eat(',')) return null;
    const end = p.rule() orelse return null;
    const year = civil(@divFloor(unix + std_off, 86400)).year;
    const start_utc = (start.day(year) orelse return null) * 86400 + start.time - std_off;
    const end_utc = (end.day(year) orelse return null) * 86400 + end.time - dst_off;
    const dst = if (start_utc < end_utc)
        unix >= start_utc and unix < end_utc
    else
        !(unix >= end_utc and unix < start_utc);
    return if (dst) dst_off else std_off;
}

const Rule = struct {
    kind: enum { month_week_day, julian, zero_based },
    month: u8 = 0,
    week: u8 = 0,
    weekday: u8 = 0,
    n: u16 = 0,
    time: i64 = 7200,

    /// Days since the epoch of the transition day in `year`.
    fn day(r: Rule, year: i64) ?i64 {
        switch (r.kind) {
            .julian => {
                var n: i64 = r.n - 1;
                if (leap(year) and r.n >= 60) n += 1;
                return daysFromCivil(year, 1, 1) + n;
            },
            .zero_based => return daysFromCivil(year, 1, 1) + r.n,
            .month_week_day => {
                const first = daysFromCivil(year, r.month, 1);
                const first_weekday = @mod(first + 4, 7);
                var d = first + @mod(@as(i64, r.weekday) - first_weekday, 7) + (@as(i64, r.week) - 1) * 7;
                const next_month = if (r.month == 12) daysFromCivil(year + 1, 1, 1) else daysFromCivil(year, r.month + 1, 1);
                while (d >= next_month) d -= 7;
                return d;
            },
        }
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn eat(p: *Parser, c: u8) bool {
        if (p.i < p.s.len and p.s[p.i] == c) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn name(p: *Parser) bool {
        if (p.eat('<')) {
            const end = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return false;
            p.i = end + 1;
            return true;
        }
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        return p.i - start >= 3;
    }

    /// Up to six digits: every field of a rule is smaller.
    fn number(p: *Parser) ?i64 {
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        if (p.i - start > 6) return null;
        return std.fmt.parseInt(i64, p.s[start..p.i], 10) catch null;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds, positive as written (west of UTC).
    fn offset(p: *Parser) ?i32 {
        const negative = p.eat('-');
        if (!negative) _ = p.eat('+');
        var seconds = (p.number() orelse return null) * 3600;
        if (p.eat(':')) seconds += (p.number() orelse return null) * 60;
        if (p.eat(':')) seconds += p.number() orelse return null;
        if (seconds > 168 * 3600) return null;
        return @intCast(if (negative) -seconds else seconds);
    }

    fn rule(p: *Parser) ?Rule {
        var r: Rule = undefined;
        if (p.eat('M')) {
            const month = p.number() orelse return null;
            if (!p.eat('.')) return null;
            const week = p.number() orelse return null;
            if (!p.eat('.')) return null;
            const weekday = p.number() orelse return null;
            if (month < 1 or month > 12 or week < 1 or week > 5 or weekday > 6) return null;
            r = .{ .kind = .month_week_day, .month = @intCast(month), .week = @intCast(week), .weekday = @intCast(weekday) };
        } else if (p.eat('J')) {
            const n = p.number() orelse return null;
            if (n < 1 or n > 365) return null;
            r = .{ .kind = .julian, .n = @intCast(n) };
        } else {
            const n = p.number() orelse return null;
            if (n > 365) return null;
            r = .{ .kind = .zero_based, .n = @intCast(n) };
        }
        if (p.eat('/')) r.time = p.offset() orelse return null;
        return r;
    }
};

fn leap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

pub fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Date = struct { year: i64, month: u8, day: u8 };

fn civil(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .month = m, .day = d };
}

const testing = std.testing;

test rule {
    const winter = daysFromCivil(2026, 12, 31) * 86400 + 12 * 3600;
    const summer = daysFromCivil(2026, 7, 1) * 86400;
    try testing.expectEqual(@as(?i32, 3600), rule("CET-1CEST,M3.5.0,M10.5.0/3", winter));
    try testing.expectEqual(@as(?i32, 7200), rule("CET-1CEST,M3.5.0,M10.5.0/3", summer));
    try testing.expectEqual(@as(?i32, -18000), rule("EST5EDT,M3.2.0,M11.1.0", winter));
    try testing.expectEqual(@as(?i32, -14400), rule("EST5EDT,M3.2.0,M11.1.0", summer));
    try testing.expectEqual(@as(?i32, 39600), rule("AEST-10AEDT,M10.1.0,M4.1.0/3", winter));
    try testing.expectEqual(@as(?i32, 36000), rule("AEST-10AEDT,M10.1.0,M4.1.0/3", summer));
    try testing.expectEqual(@as(?i32, 0), rule("UTC0", summer));
    try testing.expectEqual(@as(?i32, 19800), rule("<+0530>-5:30", summer));
    const spring_forward = daysFromCivil(2026, 3, 29) * 86400 + 3600;
    try testing.expectEqual(@as(?i32, 3600), rule("CET-1CEST,M3.5.0,M10.5.0/3", spring_forward - 1));
    try testing.expectEqual(@as(?i32, 7200), rule("CET-1CEST,M3.5.0,M10.5.0/3", spring_forward));
    try testing.expectEqual(@as(?i32, null), rule("bogus", summer));
}

test civil {
    try testing.expectEqual(Date{ .year = 2026, .month = 12, .day = 31 }, civil(daysFromCivil(2026, 12, 31)));
    try testing.expectEqual(Date{ .year = 1970, .month = 1, .day = 1 }, civil(0));
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, civil(daysFromCivil(2024, 2, 29)));
}

test "a TZ rule with a transition time is a rule, a zone name is not" {
    try testing.expectEqual(@as(?i32, 7200), rule("CET-1CEST,M3.5.0,M10.5.0/3", daysFromCivil(2026, 7, 1) * 86400));
    try testing.expectEqual(@as(?i32, null), rule("Europe/Paris", 0));
    try testing.expectEqual(@as(?i32, null), rule("UTC", 0));
}

test "julian and zero-based rule days, around a leap day" {
    try testing.expectEqual(@as(?i32, 3600), rule("AAA0BBB,J60,J300", daysFromCivil(2024, 3, 1) * 86400 + 3 * 3600));
    try testing.expectEqual(@as(?i32, 0), rule("AAA0BBB,J60,J300", daysFromCivil(2024, 2, 29) * 86400 + 12 * 3600));
    try testing.expectEqual(@as(?i32, 3600), rule("AAA0BBB,J59,J300", daysFromCivil(2023, 2, 28) * 86400 + 3 * 3600));
    try testing.expectEqual(@as(?i32, 3600), rule("AAA0BBB,59,300", daysFromCivil(2024, 2, 29) * 86400 + 3 * 3600));
    try testing.expectEqual(@as(?i32, 0), rule("AAA0BBB,59,300", daysFromCivil(2023, 2, 28) * 86400 + 12 * 3600));
    try testing.expectEqual(@as(?i32, null), rule("AAA0BBB,J0,J300", 0));
    try testing.expectEqual(@as(?i32, null), rule("AAA0BBB,J,J300", 0));
    try testing.expectEqual(@as(?i32, null), rule("AAA0BBB,366,300", 0));
    try testing.expectEqual(@as(?i32, null), rule("AAA0BBB,,300", 0));
    try testing.expect(leap(2000) and leap(2024) and !leap(1900) and !leap(2023));
}

test "a zone file without transitions gives its first type's offset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var tzif: std.Io.Writer.Allocating = .init(a);
    const w = &tzif.writer;
    try w.writeAll("TZif");
    try w.writeByte(0);
    try w.splatByteAll(0, 15);
    for ([_]u32{ 0, 0, 0, 0, 1, 4 }) |n| try w.writeInt(u32, n, .big);
    try w.writeInt(i32, 5400, .big);
    try w.writeAll(&.{ 0, 0 });
    try w.writeAll("ABC\x00");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zone", .data = tzif.written() });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    var env: std.process.Environ.Map = .init(a);
    try env.put("TZ", try std.fs.path.join(a, &.{ buf[0..len], "zone" }));
    var ctx: Ctx = .{ .alloc = a, .io = testing.io, .env = &env, .out = undefined, .err = undefined, .http = undefined };
    try testing.expectEqual(@as(i32, 5400), offset(&ctx, 0));
}
