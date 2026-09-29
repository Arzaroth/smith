//! Drives whole smith invocations against a Mock, with config, HOME and git
//! confined to a temporary directory.
const Harness = @This();

const std = @import("std");
const Io = std.Io;
const Ctx = @import("../Ctx.zig");
const app = @import("../app.zig");
const term = @import("../term.zig");
pub const Mock = @import("Mock.zig");

arena: std.heap.ArenaAllocator,
mock: Mock,
tmp: std.testing.TmpDir,
root: []const u8,
env: std.process.Environ.Map,
out: Io.Writer.Allocating,
err: Io.Writer.Allocating,
http: std.http.Client,
ctx: Ctx,

pub const Options = struct {
    token: ?[]const u8 = "t0ken",
    user: []const u8 = "me",
    /// Writes a hosts.zon naming the mock; off to test a fresh install.
    config: bool = true,
};

/// Fixed "now" for relative times: 2026-09-29T12:00:00Z.
pub const now: i64 = 1790683200;

pub fn init(h: *Harness, routes: []const Mock.Route, opts: Options) !void {
    const io = std.testing.io;
    h.arena = .init(std.testing.allocator);
    errdefer h.arena.deinit();
    const a = h.arena.allocator();

    try h.mock.start(io, routes);
    errdefer h.mock.stop();

    h.tmp = std.testing.tmpDir(.{});
    errdefer h.tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const len = try h.tmp.dir.realPath(io, &buf);
    h.root = try a.dupe(u8, buf[0..len]);

    h.env = .init(a);
    try h.env.put("HOME", h.root);
    try h.env.put("SMITH_CONFIG_DIR", try std.fs.path.join(a, &.{ h.root, "config" }));
    try h.env.put("PATH", std.testing.environ.getPosix("PATH") orelse "/usr/bin:/bin");
    try h.env.put("GIT_CONFIG_NOSYSTEM", "1");
    try h.env.put("GIT_TERMINAL_PROMPT", "0");
    try h.env.put("GIT_AUTHOR_NAME", "Test");
    try h.env.put("GIT_AUTHOR_EMAIL", "test@example.com");
    try h.env.put("GIT_COMMITTER_NAME", "Test");
    try h.env.put("GIT_COMMITTER_EMAIL", "test@example.com");
    try h.env.put("SMITH_BROWSER", "true");
    try h.env.put("TMPDIR", h.root);
    try h.env.put("SMITH_EDITOR", "true");
    try h.env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(h.root) orelse h.root);
    try h.env.put("SMITH_KEYRING", "none");
    try h.env.put("SMITH_EDITOR", "true");

    if (opts.config) {
        try h.tmp.dir.createDirPath(io, "config");
        const zon = try std.fmt.allocPrint(a,
            \\.{{ .default_host = "127.0.0.1:{d}", .hosts = .{{ .{{ .name = "127.0.0.1:{d}", .scheme = "http", .git_protocol = .https, .user = "{s}"{s} }} }} }}
            \\
        , .{ h.mock.port, h.mock.port, opts.user, if (opts.token) |t| try std.fmt.allocPrint(a, ", .token = \"{s}\"", .{t}) else "" });
        try h.tmp.dir.writeFile(io, .{ .sub_path = "config/hosts.zon", .data = zon });
    }

    h.out = .init(a);
    h.err = .init(a);
    h.http = .{ .allocator = a, .io = io };
    h.ctx = .{
        .alloc = a,
        .io = io,
        .env = &h.env,
        .out = &h.out.writer,
        .err = &h.err.writer,
        .now = now,
        .http = &h.http,
        .cwd = h.root,
        .stdin_data = "",
    };
}

pub fn deinit(h: *Harness) void {
    h.http.deinit();
    h.mock.stop();
    h.tmp.cleanup();
    h.arena.deinit();
}

/// Runs `smith <argv>` and returns its exit code; output is in `stdout()` and `stderr()`.
pub fn run(h: *Harness, argv: []const []const u8) u8 {
    h.out.clearRetainingCapacity();
    h.err.clearRetainingCapacity();
    return app.run(&h.ctx, argv);
}

pub fn stdout(h: *Harness) []const u8 {
    return h.out.written();
}

pub fn stderr(h: *Harness) []const u8 {
    return h.err.written();
}

/// "http://127.0.0.1:PORT"
pub fn base(h: *Harness) ![]const u8 {
    return std.fmt.allocPrint(h.arena.allocator(), "http://127.0.0.1:{d}", .{h.mock.port});
}

/// Path of `sub` inside the temporary directory.
pub fn path(h: *Harness, sub: []const u8) ![]const u8 {
    return std.fs.path.join(h.arena.allocator(), &.{ h.root, sub });
}

/// Runs git inside the temporary directory, failing the test on error.
pub fn git(h: *Harness, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(h.arena.allocator(), &.{ "git", "-C", h.root });
    try argv.appendSlice(h.arena.allocator(), args);
    const r = try std.process.run(h.arena.allocator(), std.testing.io, .{ .argv = argv.items, .environ_map = &h.env });
    if (r.term != .exited or r.term.exited != 0) {
        const joined = try std.mem.join(h.arena.allocator(), " ", args);
        std.debug.print("git {s} failed: {s}\n", .{ joined, r.stderr });
        return error.GitFailed;
    }
}

/// A clone at `<tmp>/<name>` whose origin is `owner/repo` on the mock, and
/// which later commands run in.
pub fn clone(h: *Harness, name: []const u8, owner: []const u8, repo: []const u8) !void {
    try h.git(&.{ "init", "-q", "-b", "main", name });
    const url = try std.fmt.allocPrint(h.arena.allocator(), "{s}/{s}/{s}.git", .{ try h.base(), owner, repo });
    try h.git(&.{ "-C", name, "remote", "add", "origin", url });
    try h.git(&.{ "-C", name, "commit", "-q", "--allow-empty", "-m", "init" });
    h.ctx.cwd = try h.path(name);
}

pub fn expectOut(h: *Harness, needle: []const u8) !void {
    if (std.mem.indexOf(u8, h.stdout(), needle) == null) {
        std.debug.print("stdout lacks \"{s}\":\n{s}\nstderr:\n{s}\n", .{ needle, h.stdout(), h.stderr() });
        return error.TestExpectedEqual;
    }
}

pub fn expectErr(h: *Harness, needle: []const u8) !void {
    if (std.mem.indexOf(u8, h.stderr(), needle) == null) {
        std.debug.print("stderr lacks \"{s}\":\n{s}\n", .{ needle, h.stderr() });
        return error.TestExpectedEqual;
    }
}

/// Runs `smith <argv>` and fails the test, showing the output, unless it exits with `code`.
pub fn expectRun(h: *Harness, code: u8, argv: []const []const u8) !void {
    const got = h.run(argv);
    if (got != code) {
        const joined = std.mem.join(h.arena.allocator(), " ", argv) catch "";
        std.debug.print("smith {s} exited {d}, expected {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ joined, got, code, h.stdout(), h.stderr() });
        return error.TestUnexpectedExitCode;
    }
}
