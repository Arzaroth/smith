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
stdin_reader: ?*Io.File.Reader = null,

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
    if (ctx.stdin_data) |d| {
        ctx.stdin_data = "";
        return d;
    }
    const r = try ctx.stdinReader();
    return r.interface.allocRemaining(ctx.alloc, .limited(16 * 1024 * 1024));
}

/// Asks a question on stderr and reads one line from stdin.
pub fn prompt(ctx: *Ctx, label: []const u8) ![]const u8 {
    try ctx.err.print("? {s} ", .{label});
    try ctx.err.flush();
    try ctx.out.flush();
    if (ctx.stdin_data) |data| {
        const end = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        ctx.stdin_data = data[@min(end + 1, data.len)..];
        return std.mem.trim(u8, data[0..end], " \r\t");
    }
    const r = &(try ctx.stdinReader()).interface;
    const line = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => r.buffered(),
        else => return e,
    };
    return ctx.alloc.dupe(u8, std.mem.trim(u8, line, " \r\n\t"));
}

/// One reader for the whole invocation, so input buffered past one prompt's
/// line is still there for the next.
fn stdinReader(ctx: *Ctx) !*Io.File.Reader {
    if (ctx.stdin_reader) |r| return r;
    const r = try ctx.alloc.create(Io.File.Reader);
    r.* = ctx.stdin.readerStreaming(ctx.io, try ctx.alloc.alloc(u8, 4096));
    ctx.stdin_reader = r;
    return r;
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
    const opener = ctx.browserOpener();
    if (ctx.stdout_tty) try ctx.err.print("Opening {s} in your browser.\n", .{url});
    try ctx.err.flush();
    const result = std.process.run(ctx.alloc, ctx.io, .{ .argv = &.{ opener, url }, .environ_map = ctx.env }) catch |e|
        return ctx.fail("could not run {s} to open {s}: {t}", .{ opener, url, e });
    if (result.term != .exited or result.term.exited != 0)
        return ctx.fail("{s} failed to open {s}", .{ opener, url });
}

fn browserOpener(ctx: *const Ctx) []const u8 {
    return ctx.getenv("SMITH_BROWSER") orelse ctx.getenv("BROWSER") orelse
        if (builtin.os.tag == .macos) "open" else "xdg-open";
}

/// Whether `openBrowser` has a chance: an opener was named, or there is a
/// desktop session to open one in.
pub fn canOpenBrowser(ctx: *const Ctx) bool {
    if (ctx.getenv("SMITH_BROWSER") != null or ctx.getenv("BROWSER") != null) return true;
    if (builtin.os.tag == .macos) return true;
    return ctx.getenv("DISPLAY") != null or ctx.getenv("WAYLAND_DISPLAY") != null;
}

/// Starts the browser on `url` without waiting for it; the caller waits on
/// the returned child once it is done. Null when the opener cannot start.
pub fn launchBrowser(ctx: *Ctx, url: []const u8) ?std.process.Child {
    return std.process.spawn(ctx.io, .{
        .argv = &.{ ctx.browserOpener(), url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = ctx.env,
    }) catch null;
}
