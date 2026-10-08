//! Tokens in the system keyring: Secret Service through `secret-tool` on
//! Linux, the login keychain through `security` on macOS. Secrets travel on
//! the helper's stdin, never its command line.
//!
//! `SMITH_KEYRING` picks the backend: `none` (plain file), `secret-tool`,
//! `security`, or the absolute path of a secret-tool-compatible program.
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("Ctx.zig");

pub const Backend = union(enum) {
    none,
    secret_tool: []const u8,
    security,
};

pub fn backend(ctx: *const Ctx) Backend {
    if (ctx.getenv("SMITH_KEYRING")) |k| {
        if (std.mem.eql(u8, k, "none") or std.mem.eql(u8, k, "file")) return .none;
        if (std.mem.eql(u8, k, "security")) return .security;
        if (std.mem.eql(u8, k, "secret-tool")) return .{ .secret_tool = "secret-tool" };
        if (std.fs.path.isAbsolute(k)) return .{ .secret_tool = k };
        return .none;
    }
    return switch (builtin.os.tag) {
        .macos => .security,
        .linux, .freebsd, .openbsd, .netbsd => .{ .secret_tool = "secret-tool" },
        else => .none,
    };
}

pub const Kind = enum { token, refresh };

const Result = struct { ok: bool, stdout: []const u8 };

fn run(ctx: *Ctx, argv: []const []const u8, input: ?[]const u8) Result {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = if (input != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = ctx.env,
    }) catch return .{ .ok = false, .stdout = "" };
    defer child.kill(ctx.io);
    if (input) |data| {
        var buf: [1024]u8 = undefined;
        var w = child.stdin.?.writerStreaming(ctx.io, &buf);
        w.interface.writeAll(data) catch {};
        w.interface.flush() catch {};
        child.stdin.?.close(ctx.io);
        child.stdin = null;
    }
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(ctx.io, &buf);
    const out = r.interface.allocRemaining(ctx.alloc, .limited(64 * 1024)) catch "";
    const term = child.wait(ctx.io) catch return .{ .ok = false, .stdout = "" };
    return .{ .ok = term == .exited and term.exited == 0, .stdout = out };
}

fn attributes(ctx: *Ctx, host: []const u8, user: ?[]const u8, kind: Kind) ![]const []const u8 {
    return ctx.alloc.dupe([]const u8, &.{ "service", "smith", "host", host, "user", user orelse "", "kind", @tagName(kind) });
}

fn service(ctx: *Ctx, host: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "smith:{s}", .{host});
}

fn account(ctx: *Ctx, user: ?[]const u8, kind: Kind) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "{s}:{t}", .{ user orelse "", kind });
}

fn quotable(fields: []const []const u8) bool {
    for (fields) |s| if (std.mem.indexOfAny(u8, s, "\"\\\n\r") != null) return false;
    return true;
}

/// Stores a secret; false when the keyring cannot take it.
pub fn store(ctx: *Ctx, host: []const u8, user: ?[]const u8, kind: Kind, secret: []const u8) !bool {
    switch (backend(ctx)) {
        .none => return false,
        .secret_tool => |tool| {
            const label = try std.fmt.allocPrint(ctx.alloc, "smith: {s} {s} ({t})", .{ host, user orelse "", kind });
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(ctx.alloc, &.{ tool, "store", "--label", label });
            try argv.appendSlice(ctx.alloc, try attributes(ctx, host, user, kind));
            return run(ctx, argv.items, secret).ok;
        },
        .security => {
            if (!quotable(&.{ host, user orelse "", secret })) return false;
            const command = try std.fmt.allocPrint(ctx.alloc, "add-generic-password -U -s \"{s}\" -a \"{s}\" -w \"{s}\"\n", .{ try service(ctx, host), try account(ctx, user, kind), secret });
            return run(ctx, &.{ "security", "-i" }, command).ok;
        },
    }
}

pub fn lookup(ctx: *Ctx, host: []const u8, user: ?[]const u8, kind: Kind) !?[]const u8 {
    const r = switch (backend(ctx)) {
        .none => return null,
        .secret_tool => |tool| blk: {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(ctx.alloc, &.{ tool, "lookup" });
            try argv.appendSlice(ctx.alloc, try attributes(ctx, host, user, kind));
            break :blk run(ctx, argv.items, null);
        },
        .security => run(ctx, &.{ "security", "find-generic-password", "-s", try service(ctx, host), "-a", try account(ctx, user, kind), "-w" }, null),
    };
    if (!r.ok) return null;
    const secret = std.mem.trimEnd(u8, r.stdout, "\r\n");
    return if (secret.len == 0) null else secret;
}

pub fn remove(ctx: *Ctx, host: []const u8, user: ?[]const u8, kind: Kind) !void {
    switch (backend(ctx)) {
        .none => {},
        .secret_tool => |tool| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(ctx.alloc, &.{ tool, "clear" });
            try argv.appendSlice(ctx.alloc, try attributes(ctx, host, user, kind));
            _ = run(ctx, argv.items, null);
        },
        .security => _ = run(ctx, &.{ "security", "delete-generic-password", "-s", try service(ctx, host), "-a", try account(ctx, user, kind) }, null),
    }
}
