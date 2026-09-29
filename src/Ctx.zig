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
/// The writer behind `out` in a real process, for why a write failed.
stdout_file: ?*Io.File.Writer = null,
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
/// `--jq` and `--template`, applied by `api.printJson`.
jq: ?[]const u8 = null,
template: ?[]const u8 = null,
/// Preferences from config.zon (`smith config`).
editor: ?[]const u8 = null,
browser: ?[]const u8 = null,
pager: ?[]const u8 = null,
/// False when prompts are turned off (`config set prompt disabled`,
/// `SMITH_PROMPT_DISABLED`): commands then act as they do in a script.
prompts: bool = true,
/// The pager standard output goes through, while one runs.
paged: ?Paged = null,

const Paged = struct {
    program: []const u8,
    child: std.process.Child,
    writer: *Io.File.Writer,
    out: *Writer,
};

/// `Reported`: the message is printed, exit 1. `AuthRequired`: likewise, but
/// exit 4, as gh does when authentication is what failed.
pub const Error = error{ Reported, AuthRequired };

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
    return ctx.stdin_tty and ctx.stdout_tty and ctx.prompts;
}

/// Sends standard output through the pager (`SMITH_PAGER`, `config set
/// pager`, then `PAGER`) until `stopPager`; nothing happens off a terminal,
/// without a pager, or when it cannot start.
pub fn startPager(ctx: *Ctx) !void {
    if (!ctx.stdout_tty or ctx.paged != null) return;
    const program = ctx.getenv("SMITH_PAGER") orelse ctx.pager orelse ctx.getenv("PAGER") orelse return;
    if (std.mem.eql(u8, program, "cat")) return;
    var env = try ctx.env.clone(ctx.alloc);
    if (env.get("LESS") == null) try env.put("LESS", "FRX");
    if (env.get("LV") == null) try env.put("LV", "-c");
    try ctx.out.flush();
    const child = std.process.spawn(ctx.io, .{
        .argv = &.{ "sh", "-c", program },
        .stdin = .pipe,
        .environ_map = &env,
    }) catch return;
    const writer = try ctx.alloc.create(Io.File.Writer);
    writer.* = child.stdin.?.writerStreaming(ctx.io, try ctx.alloc.alloc(u8, 16 * 1024));
    ctx.paged = .{ .program = program, .child = child, .writer = writer, .out = ctx.out };
    ctx.out = &writer.interface;
}

/// Ends paging: the pager gets end of input and smith waits for it to exit.
/// False, with a message, when the pager failed, so the output may be lost.
pub fn stopPager(ctx: *Ctx) bool {
    var p = ctx.paged orelse return true;
    ctx.paged = null;
    ctx.out.flush() catch {};
    ctx.out = p.out;
    p.child.stdin.?.close(ctx.io);
    p.child.stdin = null;
    const term = p.child.wait(ctx.io) catch return true;
    if (term == .exited and term.exited != 0) {
        ctx.err.print("smith: the pager `{s}` exited with {d}; set SMITH_PAGER, `smith config set pager`, or PAGER=cat\n", .{ p.program, term.exited }) catch {};
        return false;
    }
    return true;
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
    if (ctx.stdin_data != null) return ctx.prompt(label);
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
    const editor = ctx.getenv("SMITH_EDITOR") orelse ctx.editor orelse ctx.getenv("VISUAL") orelse ctx.getenv("EDITOR") orelse "vi";
    const dir = ctx.getenv("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(ctx.alloc, "{s}/smith-{s}-{s}", .{ dir, try ctx.nonce(), name });
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = initial, .flags = .{ .permissions = .fromMode(0o600), .exclusive = true } });
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
    if (ctx.stdout_tty) try ctx.err.print("Opening {s} in your browser.\n", .{url});
    try ctx.err.flush();
    if (!try ctx.launchBrowser(url)) return ctx.fail("could not run {s} to open {s}", .{ ctx.browserOpener(), url });
}

fn browserOpener(ctx: *const Ctx) []const u8 {
    return ctx.getenv("SMITH_BROWSER") orelse ctx.browser orelse ctx.getenv("BROWSER") orelse
        if (builtin.os.tag == .macos) "open" else "xdg-open";
}

/// Whether `openBrowser` has a chance: an opener was named, or there is a
/// desktop session to open one in.
pub fn canOpenBrowser(ctx: *const Ctx) bool {
    if (ctx.getenv("SMITH_BROWSER") != null or ctx.browser != null or ctx.getenv("BROWSER") != null) return true;
    if (builtin.os.tag == .macos) return true;
    return ctx.getenv("DISPLAY") != null or ctx.getenv("WAYLAND_DISPLAY") != null;
}

/// Starts the browser on `url` and leaves it running: a browser started
/// directly (not through xdg-open) would otherwise hold smith until it
/// quits. Only http(s) URLs are opened, since some come from the server and
/// an opener would hand `file:` or a custom scheme to a local handler.
/// False when the opener cannot start.
pub fn launchBrowser(ctx: *Ctx, url: []const u8) !bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://"))
        return ctx.fail("refusing to open {s}: not an http(s) URL", .{url});
    _ = std.process.spawn(ctx.io, .{
        .argv = &.{ ctx.browserOpener(), url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = ctx.env,
    }) catch return false;
    return true;
}

/// Random hex for names other users must not guess (temporary files).
pub fn nonce(ctx: *Ctx) ![]const u8 {
    var b: [12]u8 = undefined;
    ctx.io.random(&b);
    return std.fmt.allocPrint(ctx.alloc, "{x}", .{&b});
}

/// Asks a yes/no question on a terminal; without one, only `assumed` (the
/// command's `--yes`) says yes, and saying nothing is refusing.
pub fn confirm(ctx: *Ctx, question: []const u8, assumed: bool) !bool {
    if (assumed) return true;
    if (!ctx.interactive()) return ctx.fail("{s} Pass --yes to confirm when not running interactively.", .{question});
    const answer = try ctx.prompt(try std.fmt.allocPrint(ctx.alloc, "{s} [y/N]", .{question}));
    return answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}
