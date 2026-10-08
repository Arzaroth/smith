const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const api = @import("../api.zig");

fn client(h: *Harness) !api.Client {
    const a = h.arena.allocator();
    return .{
        .ctx = &h.ctx,
        .host = .{ .name = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{h.mock.port}), .scheme = "http", .token = "t0ken" },
        .base = try std.fmt.allocPrint(a, "{s}/api/v1", .{try h.base()}),
    };
}

test "smith alone prints the root help" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{});
    try h.expectOut("Work with Forgejo from the command line.");
}

test "an unknown flag points at the command's help" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "issue", "list", "--bogus" });
    try h.expectErr("unknown flag: --bogus");
    try h.expectErr("\nRun 'smith issue list --help' for usage.\n");
}

test "output that cannot be written fails, quietly when the reader went away" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var failing: std.Io.Writer = .failing;
    h.ctx.out = &failing;
    try h.expectRun(1, &.{"--version"});
    try h.expectErr("smith: cannot write the output\n");
    var closed = std.Io.File.stdout().writerStreaming(std.testing.io, &.{});
    closed.err = error.BrokenPipe;
    h.ctx.stdout_file = &closed;
    try h.expectRun(1, &.{"--version"});
    try std.testing.expectEqualStrings("", h.stderr());
}

test "a pager that quits before reading everything is no failure" {
    const a = std.testing.allocator;
    const description = try a.alloc(u8, 256 * 1024);
    defer a.free(description);
    @memset(description, 'x');
    const body = try std.fmt.allocPrint(a, "[{{\"name\":\"big\",\"description\":\"{s}\"}}]", .{description});
    defer a.free(body);
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo/labels", .body = body }}, .{});
    defer h.deinit();
    try h.env.put("SMITH_PAGER", "true");
    h.ctx.stdout_tty = true;
    try h.expectRun(0, &.{ "label", "list", "-R", "owner/repo", "--json" });
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "cannot write") == null);
}

test "an unexpected error is printed by name" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    h.ctx.stdin_data = null;
    const dir = try h.tmp.dir.openDir(std.testing.io, ".", .{});
    defer dir.close(std.testing.io);
    h.ctx.stdin = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try h.expectRun(1, &.{ "api", "/user", "--input", "-" });
    try h.expectErr("smith: ReadFailed\n");
}

test "a body that does not decompress or decode is reported" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/gzip", .raw = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 10\r\nConnection: close\r\n\r\nnot gzip!!" },
        .{ .path = "/api/v1/deflate", .raw = "HTTP/1.1 200 OK\r\nContent-Encoding: deflate\r\nContent-Length: 4\r\nConnection: close\r\n\r\n\xff\xff\xff\xff" },
        .{ .path = "/api/v1/chunked", .raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nzz\r\n" },
    }, .{});
    defer h.deinit();
    var c = try client(&h);
    for ([_][]const u8{ "/gzip", "/deflate" }) |path| {
        h.err.clearRetainingCapacity();
        try std.testing.expectError(error.Reported, c.raw(.GET, path, .{}));
        try h.expectErr("(connection or decompression error)");
    }
    h.err.clearRetainingCapacity();
    try std.testing.expectError(error.Reported, c.raw(.GET, "/chunked", .{}));
    try h.expectErr("reading the response from 127.0.0.1:");
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "decompression") == null);
}

test "a sink that cannot be written stops the response" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/file", .body = "contents", .content_type = "application/octet-stream" }}, .{});
    defer h.deinit();
    var c = try client(&h);
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, c.raw(.GET, "/file", .{ .sink = &failing }));
}

test "error statuses without a message, answers that are not JSON, and objects of the wrong shape" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/boom", .status = 500 },
        .{ .path = "/api/v1/html", .body = "<html>", .content_type = "text/html" },
    }, .{});
    defer h.deinit();
    var c = try client(&h);
    try std.testing.expectError(error.Reported, c.call(.GET, "/boom", .{}));
    try h.expectErr("HTTP 500 from GET /boom\n");
    try std.testing.expectError(error.Reported, c.getValue("/html"));
    try h.expectErr("answered with something that is not JSON\n");
    try std.testing.expectError(error.Reported, api.decode(struct { n: i64 }, &h.ctx, .{ .string = "x" }));
    try h.expectErr("from the API: UnexpectedToken\n");
}

test "an uploaded file's name cannot break out of its form header" {
    var h: Harness = undefined;
    try h.init(&.{.{ .method = .POST, .path = "/api/v1/up", .status = 201, .body = "{}" }}, .{});
    defer h.deinit();
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "asset", .data = "data" });
    const file = try h.tmp.dir.openFile(std.testing.io, "asset", .{});
    defer file.close(std.testing.io);
    var c = try client(&h);
    _ = try c.uploadFile("/up", "a\"b\r\n\\c", file, 4);
    const body = h.mock.lastBody(.POST, "/api/v1/up").?;
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"a_b___c\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\r\n\r\ndata\r\n") != null);
}
