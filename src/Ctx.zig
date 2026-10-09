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
paged: ?*Pager = null,

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
/// pager`, then `PAGER`) until `stopPager`; nothing happens off a terminal
/// or without a pager. The pager starts with the first output, so a command
/// that fails before printing anything leaves its error on the terminal.
pub fn startPager(ctx: *Ctx) !void {
    if (!ctx.stdout_tty or ctx.paged != null) return;
    const program = if (ctx.env.get("SMITH_PAGER")) |p| p else ctx.pager orelse ctx.getenv("PAGER") orelse return;
    if (program.len == 0 or std.mem.eql(u8, program, "cat")) return;
    if (!ctx.onPath(program)) {
        try ctx.err.print("! the pager `{s}` was not found; printing directly\n", .{program});
        return;
    }
    try ctx.out.flush();
    const p = try ctx.alloc.create(Pager);
    p.* = .{ .ctx = ctx, .program = program, .out = ctx.out, .interface = .{ .vtable = &.{ .drain = Pager.drain, .flush = Pager.flush }, .buffer = try ctx.alloc.alloc(u8, 16 * 1024) } };
    ctx.paged = p;
    ctx.out = &p.interface;
}

const Pager = struct {
    ctx: *Ctx,
    program: []const u8,
    /// Standard output, restored when paging ends.
    out: *Writer,
    child: ?std.process.Child = null,
    pipe: Io.File.Writer = undefined,
    interface: Writer,

    fn target(p: *Pager) Writer.Error!*Writer {
        if (p.child != null) return &p.pipe.interface;
        const ctx = p.ctx;
        var env = ctx.env.clone(ctx.alloc) catch return error.WriteFailed;
        if (env.get("LESS") == null) env.put("LESS", "FRX") catch return error.WriteFailed;
        if (env.get("LV") == null) env.put("LV", "-c") catch return error.WriteFailed;
        p.child = std.process.spawn(ctx.io, .{
            .argv = &.{ "sh", "-c", p.program },
            .stdin = .pipe,
            .environ_map = &env,
        }) catch return p.out;
        p.pipe = p.child.?.stdin.?.writerStreaming(ctx.io, ctx.alloc.alloc(u8, 16 * 1024) catch return error.WriteFailed);
        return &p.pipe.interface;
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const p: *Pager = @alignCast(@fieldParentPtr("interface", w));
        const t = try p.target();
        try t.writeAll(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try t.writeAll(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try t.writeAll(last);
        return n + last.len * splat;
    }

    fn flush(w: *Writer) Writer.Error!void {
        const p: *Pager = @alignCast(@fieldParentPtr("interface", w));
        if (w.end == 0) return if (p.child != null) p.pipe.interface.flush();
        const t = try p.target();
        try t.writeAll(w.buffered());
        w.end = 0;
        try t.flush();
    }
};

/// Whether the first word of a shell command names a program that exists.
fn onPath(ctx: *const Ctx, command: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, command, " \t");
    const program = words.next() orelse return false;
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        Io.Dir.cwd().access(ctx.io, program, .{}) catch return false;
        return true;
    }
    var dirs = std.mem.tokenizeScalar(u8, ctx.getenv("PATH") orelse return false, ':');
    while (dirs.next()) |dir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, program }) catch continue;
        Io.Dir.cwd().access(ctx.io, path, .{}) catch continue;
        return true;
    }
    return false;
}

/// Ends paging: the pager gets end of input and smith waits for it to exit.
/// False, with a message, when the pager failed, so the output may be lost.
pub fn stopPager(ctx: *Ctx) bool {
    const p = ctx.paged orelse return true;
    ctx.paged = null;
    ctx.out.flush() catch {};
    ctx.out = p.out;
    var child = p.child orelse return true;
    child.stdin.?.close(ctx.io);
    child.stdin = null;
    const term = child.wait(ctx.io) catch return true;
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
    return try ctx.promptOrEnd(label) orelse "";
}

/// Like `prompt`, but null when input ended (Ctrl-D) instead of an answer.
pub fn promptOrEnd(ctx: *Ctx, label: []const u8) !?[]const u8 {
    try ctx.err.print("? {s} ", .{label});
    try ctx.err.flush();
    try ctx.out.flush();
    if (ctx.stdin_data) |data| {
        if (data.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        ctx.stdin_data = data[@min(end + 1, data.len)..];
        return std.mem.trim(u8, data[0..end], " \r\t");
    }
    const r = &(try ctx.stdinReader()).interface;
    const line = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => if (r.buffered().len == 0) return null else r.buffered(),
        else => return e,
    };
    return try ctx.alloc.dupe(u8, std.mem.trim(u8, line, " \r\n\t"));
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

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    out: Writer.Allocating,
    err: Writer.Allocating,
    http: std.http.Client,
    tmp: testing.TmpDir,
    ctx: Ctx,

    fn init(f: *Fixture) !void {
        f.arena = .init(testing.allocator);
        const a = f.arena.allocator();
        f.env = .init(a);
        f.out = .init(a);
        f.err = .init(a);
        f.http = .{ .allocator = a, .io = testing.io };
        f.tmp = testing.tmpDir(.{});
        f.ctx = .{ .alloc = a, .io = testing.io, .env = &f.env, .out = &f.out.writer, .err = &f.err.writer, .http = &f.http };
        errdefer f.deinit();
        const root = try f.path("");
        f.ctx.cwd = root;
        try f.env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root) orelse root);
        try f.env.put("SMITH_KEYRING", "none");
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn path(f: *Fixture, sub: []const u8) ![]const u8 {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const len = try f.tmp.dir.realPath(testing.io, &buf);
        return std.fs.path.join(f.arena.allocator(), &.{ buf[0..len], sub });
    }

    fn stdinFrom(f: *Fixture, data: []const u8) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "stdin", .data = data });
        f.ctx.stdin = try f.tmp.dir.openFile(testing.io, "stdin", .{});
    }
};

test "the pager receives writes larger than its buffer, vectors and splats" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.env.put("PATH", testing.environ.getPosix("PATH") orelse "/usr/bin:/bin");
    try f.env.put("SMITH_PAGER", try std.fmt.allocPrint(a, "cat > '{s}'", .{try f.path("paged")}));
    f.ctx.stdout_tty = true;
    try f.ctx.startPager();
    errdefer _ = f.ctx.stopPager();
    try testing.expect(f.ctx.paged != null);
    const big = try a.alloc(u8, 20000);
    @memset(big, 'a');
    try f.ctx.out.writeAll(big);
    var parts = [_][]const u8{ "head", "ab" };
    try f.ctx.out.writeSplatAll(&parts, 10000);
    try testing.expect(f.ctx.stopPager());
    const got = try f.tmp.dir.readFileAlloc(testing.io, "paged", a, .limited(1024 * 1024));
    try testing.expectEqual(@as(usize, 20000 + 4 + 20000), got.len);
    try testing.expect(std.mem.startsWith(u8, got[20000..], "headabab"));
}

test "prompts read lines from standard input, then the rest of it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.stdinFrom(" first \nrest\nof it");
    defer f.ctx.stdin.close(testing.io);
    try testing.expectEqualStrings("first", (try f.ctx.promptOrEnd("Name?")).?);
    try testing.expectEqualStrings("rest\nof it", try f.ctx.readStdin());
    try testing.expectEqual(@as(?[]const u8, null), try f.ctx.promptOrEnd("More?"));
    try testing.expectEqualStrings("? Name? ? More? ", f.err.written());
}

test "a prompt takes a last line without a newline" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.stdinFrom("yes");
    defer f.ctx.stdin.close(testing.io);
    try testing.expectEqualStrings("yes", try f.ctx.prompt("Sure?"));
}

test "a secret prompt reads a file as it is when standard input is no terminal" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.stdinFrom("hunter2\n");
    defer f.ctx.stdin.close(testing.io);
    try testing.expectEqualStrings("hunter2", try f.ctx.promptSecret("Token:"));
    try testing.expectEqualStrings("? Token: ", f.err.written());
}

test "a secret prompt turns echo off on a terminal and back on after" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const master = Io.Dir.cwd().openFile(testing.io, "/dev/ptmx", .{ .mode = .read_write }) catch return error.SkipZigTest;
    defer master.close(testing.io);
    var unlock: c_int = 0;
    if (linux.errno(linux.ioctl(master.handle, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.SkipZigTest;
    var n: c_uint = 0;
    if (linux.errno(linux.ioctl(master.handle, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.SkipZigTest;
    const name = try std.fmt.allocPrint(f.arena.allocator(), "/dev/pts/{d}", .{n});
    const slave = Io.Dir.cwd().openFile(testing.io, name, .{ .mode = .read_write }) catch return error.SkipZigTest;
    defer slave.close(testing.io);
    const typist = try std.Thread.spawn(.{}, typeOnceSilent, .{ master, slave });
    f.ctx.stdin = slave;
    f.ctx.stdin_data = null;
    const got = f.ctx.promptSecret("Password:");
    typist.join();
    try testing.expectEqualStrings("s3cret", try got);
    try testing.expectEqualStrings("? Password: \n", f.err.written());
    try testing.expect((try std.posix.tcgetattr(slave.handle)).lflag.ECHO);
    try master.writeStreamingAll(testing.io, "x\n");
    var echoed: [64]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOfScalar(u8, echoed[0..len], 'x') == null and len < echoed.len) {
        len += try master.readStreaming(testing.io, &.{echoed[len..]});
    }
    try testing.expectEqualStrings("x\r\n", echoed[0..len]);
}

fn typeOnceSilent(master: Io.File, slave: Io.File) void {
    for (0..10_000_000) |_| {
        const t = std.posix.tcgetattr(slave.handle) catch break;
        if (!t.lflag.ECHO) break;
        std.Thread.yield() catch {};
    }
    master.writeStreamingAll(testing.io, "s3cret\n") catch {};
}

test "a browser needs an opener or a desktop session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    if (builtin.os.tag != .macos) {
        try testing.expect(!f.ctx.canOpenBrowser());
        try testing.expectEqualStrings("xdg-open", f.ctx.browserOpener());
    }
    try f.env.put("WAYLAND_DISPLAY", "wayland-0");
    try testing.expect(f.ctx.canOpenBrowser());
    _ = f.env.swapRemove("WAYLAND_DISPLAY");
    try f.env.put("DISPLAY", ":0");
    try testing.expect(f.ctx.canOpenBrowser());
}

test "a browser that cannot start is reported" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.env.put("SMITH_BROWSER", "/nonexistent/smith-opener");
    f.ctx.stdout_tty = true;
    try testing.expectError(error.Reported, f.ctx.openBrowser("https://example.test/x"));
    try testing.expectEqualStrings("Opening https://example.test/x in your browser.\ncould not run /nonexistent/smith-opener to open https://example.test/x\n", f.err.written());
}
