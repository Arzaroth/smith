//! Preferences and aliases: `$SMITH_CONFIG_DIR/config.zon`, next to the
//! hosts file but holding nothing secret.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ctx = @import("Ctx.zig");
const config = @import("config.zig");

pub const Alias = struct {
    name: []const u8,
    expansion: []const u8,
};

pub const Settings = struct {
    /// Editor for bodies, after `SMITH_EDITOR` and before `VISUAL`/`EDITOR`.
    editor: ?[]const u8 = null,
    /// Browser for `--web`, after `SMITH_BROWSER` and before `BROWSER`.
    browser: ?[]const u8 = null,
    /// Git protocol given to hosts logged in to from now on.
    git_protocol: ?config.Protocol = null,
    aliases: []const Alias = &.{},

    pub fn alias(s: Settings, name: []const u8) ?Alias {
        for (s.aliases) |a| if (std.mem.eql(u8, a.name, name)) return a;
        return null;
    }
};

pub const keys = [_][]const u8{ "editor", "browser", "git_protocol" };

fn path(ctx: *Ctx) ![]const u8 {
    return std.fs.path.join(ctx.alloc, &.{ try config.dir(ctx), "config.zon" });
}

pub fn load(ctx: *Ctx) !Settings {
    return read(ctx, false);
}

/// Like `load`, but a file that does not parse is reported and ignored, so
/// a broken `config.zon` never blocks the commands that could repair it.
pub fn loadLenient(ctx: *Ctx) !Settings {
    return read(ctx, true);
}

fn read(ctx: *Ctx, lenient: bool) !Settings {
    const p = try path(ctx);
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.alloc, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return ctx.fail("cannot read {s}: {t}", .{ p, e }),
    };
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(Settings, ctx.alloc, try ctx.alloc.dupeZ(u8, bytes), &diag, .{ .ignore_unknown_fields = true }) catch
        if (lenient) {
            try ctx.err.print("! {s} is not valid, so its preferences and aliases are ignored: {f}\n", .{ p, diag });
            return .{};
        } else ctx.fail("{s} is not valid; fix or delete it: {f}", .{ p, diag });
}

pub fn save(ctx: *Ctx, s: Settings) !void {
    const d = try config.dir(ctx);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(ctx.io, d) catch |e| return ctx.fail("cannot create {s}: {t}", .{ d, e });
    var aw: Io.Writer.Allocating = .init(ctx.alloc);
    try std.zon.stringify.serialize(s, .{ .emit_default_optional_fields = false }, &aw.writer);
    try aw.writer.writeByte('\n');
    const p = try path(ctx);
    const tmp = try std.fmt.allocPrint(ctx.alloc, "{s}.tmp", .{p});
    cwd.writeFile(ctx.io, .{ .sub_path = tmp, .data = aw.written() }) catch |e| return ctx.fail("cannot write {s}: {t}", .{ tmp, e });
    cwd.rename(tmp, cwd, p, ctx.io) catch |e| return ctx.fail("cannot write {s}: {t}", .{ p, e });
}

/// Splits an alias expansion into words: whitespace separates, single and
/// double quotes group, a backslash escapes the next character.
pub fn split(alloc: Allocator, s: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else if (c == '\\' and q == '"' and i + 1 < s.len) {
                i += 1;
                try word.append(alloc, s[i]);
            } else try word.append(alloc, c);
            continue;
        }
        switch (c) {
            ' ', '\t', '\n' => if (in_word) {
                try words.append(alloc, try word.toOwnedSlice(alloc));
                in_word = false;
            },
            '\'', '"' => {
                quote = c;
                in_word = true;
            },
            '\\' => {
                if (i + 1 < s.len) {
                    i += 1;
                    try word.append(alloc, s[i]);
                }
                in_word = true;
            },
            else => {
                try word.append(alloc, c);
                in_word = true;
            },
        }
    }
    if (quote != null) return error.UnterminatedQuote;
    if (in_word) try words.append(alloc, try word.toOwnedSlice(alloc));
    return words.toOwnedSlice(alloc);
}

/// The argument vector an alias expands to: `$1`… take the arguments given
/// after the alias, and those no placeholder used are appended.
pub fn expand(alloc: Allocator, expansion: []const u8, rest: []const []const u8) ![]const []const u8 {
    const words = try split(alloc, expansion);
    var used = try alloc.alloc(bool, rest.len);
    @memset(used, false);
    var out: std.ArrayList([]const u8) = .empty;
    for (words) |w| {
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < w.len) : (i += 1) {
            if (w[i] == '$' and i + 1 < w.len and std.ascii.isDigit(w[i + 1])) {
                var j = i + 1;
                while (j < w.len and std.ascii.isDigit(w[j])) j += 1;
                const n = std.fmt.parseInt(usize, w[i + 1 .. j], 10) catch 0;
                if (n >= 1 and n <= rest.len) {
                    try buf.appendSlice(alloc, rest[n - 1]);
                    used[n - 1] = true;
                } else return error.NotEnoughArguments;
                i = j - 1;
            } else try buf.append(alloc, w[i]);
        }
        try out.append(alloc, try buf.toOwnedSlice(alloc));
    }
    for (rest, used) |r, u| if (!u) try out.append(alloc, r);
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test split {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const w = try split(arena.allocator(), "pr list --label 'needs review' -A \"me \\\"x\\\"\"  a\\ b");
    try testing.expectEqual(@as(usize, 7), w.len);
    try testing.expectEqualStrings("needs review", w[3]);
    try testing.expectEqualStrings("me \"x\"", w[5]);
    try testing.expectEqualStrings("a b", w[6]);
}

test expand {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try expand(a, "issue list --label $1 -L 5", &.{ "bug", "--web" });
    try testing.expectEqual(@as(usize, 7), e.len);
    try testing.expectEqualStrings("bug", e[3]);
    try testing.expectEqualStrings("--web", e[6]);
    const plain = try expand(a, "pr checkout", &.{"12"});
    try testing.expectEqualStrings("12", plain[2]);
}
