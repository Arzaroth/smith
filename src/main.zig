const std = @import("std");
const Io = std.Io;
const app = @import("app.zig");
const term = @import("term.zig");
const Ctx = @import("Ctx.zig");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(alloc);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);

    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    http.initDefaultProxies(alloc, init.environ_map) catch {};

    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    var ctx: Ctx = .{
        .alloc = alloc,
        .io = io,
        .env = init.environ_map,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
        .stdout_tty = stdout_tty,
        .stdin_tty = Io.File.stdin().isTty(io) catch false,
        .color = term.useColor(init.environ_map, stdout_tty),
        .now = Io.Clock.real.now(io).toSeconds(),
        .http = &http,
    };
    return app.run(&ctx, argv[1..]);
}

fn refAll(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |d| {
        const v = @field(T, d.name);
        if (@TypeOf(v) == type) {
            switch (@typeInfo(v)) {
                .@"struct", .@"enum", .@"union" => refAll(v),
                else => {},
            }
        } else {
            _ = &v;
        }
    }
}

test {
    refAll(@import("cli.zig"));
    refAll(@import("config.zig"));
    refAll(@import("api.zig"));
    refAll(@import("Ctx.zig"));
    refAll(@import("term.zig"));
    refAll(@import("git.zig"));
    refAll(@import("repo.zig"));
    refAll(@import("types.zig"));
    refAll(@import("caps.zig"));
    refAll(@import("oauth.zig"));
    refAll(@import("template.zig"));
    refAll(@import("settings.zig"));
    refAll(app);
}

test {
    _ = @import("tests/smoke_test.zig");
    _ = @import("tests/auth_test.zig");
    _ = @import("tests/issue_test.zig");
    _ = @import("tests/repo_test.zig");
    _ = @import("tests/pr_test.zig");
    _ = @import("tests/run_test.zig");
    _ = @import("tests/tools_test.zig");
    _ = @import("tests/login_test.zig");
    _ = @import("tests/hosts_test.zig");
    _ = @import("tests/release_test.zig");
    _ = @import("tests/planning_test.zig");
    _ = @import("tests/actions_test.zig");
    _ = @import("tests/account_test.zig");
}
