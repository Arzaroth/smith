//! Everything a command needs from the process: allocator, I/O, environment,
//! output streams and terminal facts. Tests build one around buffers.
const Ctx = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;

/// Arena for the whole invocation; nothing is freed individually.
alloc: Allocator,
io: Io,
env: *const std.process.Environ.Map,
out: *Writer,
err: *Writer,
stdin: Io.File = .stdin(),
stdout_tty: bool = false,
stdin_tty: bool = false,
color: bool = false,
/// Unix seconds, for relative times.
now: i64 = 0,
http: *std.http.Client,
/// Working directory for git; null means the process's own.
cwd: ?[]const u8 = null,
/// Stands in for standard input when set.
stdin_data: ?[]const u8 = null,

pub const Error = error{Reported};

/// Prints a message to stderr; the caller returns the error to exit 1.
pub fn fail(ctx: *const Ctx, comptime fmt: []const u8, args: anytype) Error {
    ctx.err.print(fmt ++ "\n", args) catch {};
    return error.Reported;
}

/// An environment variable, treating an empty value as unset.
pub fn getenv(ctx: *const Ctx, name: []const u8) ?[]const u8 {
    const v = ctx.env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

pub fn interactive(ctx: *const Ctx) bool {
    return ctx.stdin_tty and ctx.stdout_tty;
}

pub fn readStdin(ctx: *Ctx) ![]const u8 {
    if (ctx.stdin_data) |d| return d;
    var buf: [4096]u8 = undefined;
    var r = ctx.stdin.readerStreaming(ctx.io, &buf);
    return r.interface.allocRemaining(ctx.alloc, .limited(16 * 1024 * 1024));
}

/// Asks a question on stderr and reads one line from stdin.
pub fn prompt(ctx: *Ctx, label: []const u8) ![]const u8 {
    try ctx.err.print("? {s} ", .{label});
    try ctx.err.flush();
    try ctx.out.flush();
    var buf: [4096]u8 = undefined;
    var r = ctx.stdin.readerStreaming(ctx.io, &buf);
    const line = r.interface.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => r.interface.buffered(),
        else => return e,
    };
    return ctx.alloc.dupe(u8, std.mem.trim(u8, line, " \r\n\t"));
}

/// Like `prompt`, with terminal echo turned off while the user types.
pub fn promptSecret(ctx: *Ctx, label: []const u8) ![]const u8 {
    const fd = ctx.stdin.handle;
    const saved = std.posix.tcgetattr(fd) catch return ctx.prompt(label);
    var silent = saved;
    silent.lflag.ECHO = false;
    std.posix.tcsetattr(fd, .NOW, silent) catch return ctx.prompt(label);
    defer {
        std.posix.tcsetattr(fd, .NOW, saved) catch {};
        ctx.err.writeByte('\n') catch {};
    }
    return ctx.prompt(label);
}

/// Opens `initial` in the user's editor and returns what they saved.
pub fn editText(ctx: *Ctx, name: []const u8, initial: []const u8) ![]const u8 {
    const editor = ctx.getenv("SMITH_EDITOR") orelse ctx.getenv("VISUAL") orelse ctx.getenv("EDITOR") orelse "vi";
    const dir = ctx.getenv("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(ctx.alloc, "{s}/smith-{d}-{s}", .{ dir, std.posix.system.getpid(), name });
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = initial, .flags = .{ .permissions = .fromMode(0o600) } });
    defer cwd.deleteFile(ctx.io, path) catch {};

    try ctx.out.flush();
    try ctx.err.flush();
    var child = try std.process.spawn(ctx.io, .{ .argv = &.{ "sh", "-c", "exec $0 \"$1\"", editor, path }, .environ_map = ctx.env });
    const term = try child.wait(ctx.io);
    if (term != .exited or term.exited != 0) return ctx.fail("editor exited with an error", .{});
    return cwd.readFileAlloc(ctx.io, path, ctx.alloc, .limited(16 * 1024 * 1024));
}

/// Opens a URL in the browser; `SMITH_BROWSER` or `BROWSER` override the
/// platform opener.
pub fn openBrowser(ctx: *Ctx, url: []const u8) !void {
    const opener = ctx.getenv("SMITH_BROWSER") orelse ctx.getenv("BROWSER") orelse
        if (builtin.os.tag == .macos) "open" else "xdg-open";
    if (ctx.stdout_tty) try ctx.err.print("Opening {s} in your browser.\n", .{url});
    try ctx.err.flush();
    const result = std.process.run(ctx.alloc, ctx.io, .{ .argv = &.{ opener, url }, .environ_map = ctx.env }) catch |e|
        return ctx.fail("could not run {s} to open {s}: {t}", .{ opener, url, e });
    if (result.term != .exited or result.term.exited != 0)
        return ctx.fail("{s} failed to open {s}", .{ opener, url });
}
