//! What differs on Windows: where home and the config live, private file
//! modes, turning off the terminal's echo, running a command line the user
//! configured, programs on `PATH`, and the machine's name.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const windows = builtin.os.tag == .windows;

/// Owner-only on POSIX. Windows has no mode bits: a file takes the ACL of
/// its directory, which under the user's profile is the user's alone.
pub const private_file: Io.File.Permissions = if (windows) .default_file else .fromMode(0o600);
pub const private_dir: Io.File.Permissions = if (windows) .default_dir else .fromMode(0o700);

/// The user's home: `HOME`, else `USERPROFILE` on Windows.
pub fn home(env: *const std.process.Environ.Map) ?[]const u8 {
    if (get(env, "HOME")) |h| return h;
    return if (windows) get(env, "USERPROFILE") else null;
}

/// Where per-user configuration goes: `XDG_CONFIG_HOME`, else `%APPDATA%`
/// on Windows, else `~/.config`.
pub fn configRoot(alloc: Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (get(env, "XDG_CONFIG_HOME")) |x| return x;
    if (windows) if (get(env, "APPDATA")) |a| return a;
    const h = home(env) orelse return null;
    return try std.fs.path.join(alloc, &.{ h, ".config" });
}

fn get(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// The machine's name, for titles of the tokens and keys smith creates.
pub fn machineName(alloc: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (windows) return get(env, "COMPUTERNAME") orelse "windows";
    const u = std.posix.uname();
    return alloc.dupe(u8, std.mem.sliceTo(&u.nodename, 0));
}

/// Splits a command line on spaces and tabs, keeping double-quoted runs
/// together: how a pager or editor setting runs on Windows, where there may
/// be no `sh` to hand it to.
pub fn words(alloc: Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quoted = false;
    for (line) |c| {
        if (c == '"') {
            quoted = !quoted;
            in_word = true;
        } else if (!quoted and (c == ' ' or c == '\t')) {
            if (in_word) try out.append(alloc, try word.toOwnedSlice(alloc));
            in_word = false;
        } else {
            try word.append(alloc, c);
            in_word = true;
        }
    }
    if (in_word) try out.append(alloc, try word.toOwnedSlice(alloc));
    return out.items;
}

/// The path of `program` in one of `PATH`'s directories, trying Windows'
/// executable extensions there; null when none has it.
pub fn findOnPath(alloc: Allocator, io: Io, env: *const std.process.Environ.Map, program: []const u8) !?[]const u8 {
    const extensions: []const []const u8 = if (windows) &.{ "", ".exe", ".cmd", ".bat", ".com" } else &.{""};
    var dirs = std.mem.tokenizeScalar(u8, get(env, "PATH") orelse return null, std.fs.path.delimiter);
    while (dirs.next()) |dir| {
        for (extensions) |ext| {
            const candidate = try std.fmt.allocPrint(alloc, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, program, ext });
            Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            return candidate;
        }
    }
    return null;
}

/// How a child's standard output goes to smith's standard error: handed
/// over directly on POSIX; on Windows std reopens a `.file` by name, which
/// fails for a pipe, so the output comes through one and `copyOut` passes it
/// on.
pub fn stdoutToStderr() std.process.SpawnOptions.StdIo {
    return if (windows) .pipe else .{ .file = .stderr() };
}

pub fn copyOut(io: Io, child: *std.process.Child, to: *Io.Writer) void {
    if (!windows) return;
    const out = child.stdout orelse return;
    var buf: [4096]u8 = undefined;
    var r = out.readerStreaming(io, &buf);
    _ = r.interface.streamRemaining(to) catch {};
    to.flush() catch {};
}

/// The terminal's state before `echoOff`, for `restore`.
pub const Echo = if (windows) struct { handle: std.os.windows.HANDLE, mode: u32 } else struct { fd: std.posix.fd_t, termios: std.posix.termios };

/// Stops the terminal from echoing what is typed; null when `file` is not a
/// terminal or the setting cannot change.
pub fn echoOff(file: Io.File) ?Echo {
    if (windows) {
        var mode: u32 = 0;
        if (kernel32.GetConsoleMode(file.handle, &mode) == 0) return null;
        if (kernel32.SetConsoleMode(file.handle, mode & ~kernel32.ENABLE_ECHO_INPUT) == 0) return null;
        return .{ .handle = file.handle, .mode = mode };
    }
    const saved = std.posix.tcgetattr(file.handle) catch return null;
    var silent = saved;
    silent.lflag.ECHO = false;
    std.posix.tcsetattr(file.handle, .NOW, silent) catch return null;
    return .{ .fd = file.handle, .termios = saved };
}

pub fn restore(e: Echo) void {
    if (windows) {
        _ = kernel32.SetConsoleMode(e.handle, e.mode);
    } else {
        std.posix.tcsetattr(e.fd, .NOW, e.termios) catch {};
    }
}

/// Lets a Windows console show the colours smith writes as escape
/// sequences; nothing elsewhere.
pub fn enableColor(file: Io.File) void {
    if (!windows) return;
    var mode: u32 = 0;
    if (kernel32.GetConsoleMode(file.handle, &mode) == 0) return;
    _ = kernel32.SetConsoleMode(file.handle, mode | kernel32.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
}

const kernel32 = struct {
    const ENABLE_ECHO_INPUT: u32 = 0x4;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x4;
    extern "kernel32" fn GetConsoleMode(console: std.os.windows.HANDLE, mode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(console: std.os.windows.HANDLE, mode: u32) callconv(.winapi) c_int;
};

test "words keeps quoted runs together" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const w = try words(arena.allocator(), "\"C:\\Program Files\\Code\\code.exe\"  --wait\t-n");
    try std.testing.expectEqual(@as(usize, 3), w.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\Code\\code.exe", w[0]);
    try std.testing.expectEqualStrings("--wait", w[1]);
    try std.testing.expectEqualStrings("-n", w[2]);
}
