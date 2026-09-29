const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const usage =
    \\smith - work with Forgejo from the command line
    \\
    \\USAGE
    \\  smith <command> <subcommand> [flags]
    \\
    \\Nothing is implemented yet; see ROADMAP.md.
    \\
    \\FLAGS
    \\  -h, --help      Show this help
    \\  -V, --version   Show the version
    \\
;

const Action = enum { help, version, unknown };

fn parse(args: []const []const u8) Action {
    if (args.len < 2) return .help;
    const first = args[1];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) return .help;
    if (std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "--version")) return .version;
    return .unknown;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const err = &stderr_writer.interface;

    switch (parse(args)) {
        .help => try out.writeAll(usage),
        .version => try out.print("smith {s}\n", .{build_options.version}),
        .unknown => {
            try err.print("smith: unknown command \"{s}\"\n\n{s}", .{ args[1], usage });
            try err.flush();
            return 1;
        },
    }
    try out.flush();
    return 0;
}

test parse {
    try std.testing.expectEqual(Action.help, parse(&.{"smith"}));
    try std.testing.expectEqual(Action.help, parse(&.{ "smith", "--help" }));
    try std.testing.expectEqual(Action.version, parse(&.{ "smith", "-V" }));
    try std.testing.expectEqual(Action.unknown, parse(&.{ "smith", "pr" }));
}
