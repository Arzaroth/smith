const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const actions = "/api/v1/repos/owner/repo/actions";

/// A zip archive holding one stored (uncompressed) file.
fn zip(alloc: std.mem.Allocator, name: []const u8, data: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    const crc = std.hash.Crc32.hash(data);
    const n: u16 = @intCast(name.len);
    const size: u32 = @intCast(data.len);
    try w.writeInt(u32, 0x04034b50, .little);
    inline for (.{ @as(u16, 20), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0) }) |x| try w.writeInt(u16, x, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u16, n, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeAll(name);
    try w.writeAll(data);
    const central: u32 = @intCast(out.written().len);
    try w.writeInt(u32, 0x02014b50, .little);
    inline for (.{ @as(u16, 20), @as(u16, 20), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0) }) |x| try w.writeInt(u16, x, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u16, n, .little);
    inline for (.{ @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0) }) |x| try w.writeInt(u16, x, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeAll(name);
    const central_size: u32 = @as(u32, @intCast(out.written().len)) - central;
    try w.writeInt(u32, 0x06054b50, .little);
    inline for (.{ @as(u16, 0), @as(u16, 0), @as(u16, 1), @as(u16, 1) }) |x| try w.writeInt(u16, x, .little);
    try w.writeInt(u32, central_size, .little);
    try w.writeInt(u32, central, .little);
    try w.writeInt(u16, 0, .little);
    return out.written();
}

fn setRoutes(h: *Harness, routes: []const Harness.Mock.Route) !void {
    h.mock.routes = try h.arena.allocator().dupe(Harness.Mock.Route, routes);
    h.mock.used = try h.arena.allocator().alloc(u32, routes.len);
    @memset(h.mock.used, 0);
}

test "run download unpacks each artifact into a directory and skips expired ones" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{
        .{ .path = actions ++ "/runs/41", .body = fx.run_failed },
        .{ .path = actions ++ "/runs/41/artifacts", .body = "[{\"id\":1,\"name\":\"logs\",\"size_in_bytes\":2},{\"id\":2,\"name\":\"old\",\"expired\":true}]" },
        .{ .path = actions ++ "/artifacts/1/zip", .body = try zip(h.arena.allocator(), "a.txt", "hi"), .content_type = "application/zip" },
    });
    try h.expectRun(0, &.{ "run", "download", "41", "-R", "owner/repo", "-D", try h.path("out") });
    try std.testing.expectEqualStrings("hi", try h.tmp.dir.readFileAlloc(std.testing.io, "out/logs/a.txt", h.arena.allocator(), .limited(64)));
    try h.expectErr("old has expired");
    try std.testing.expectError(error.FileNotFound, h.tmp.dir.access(std.testing.io, "out/logs.zip.part", .{}));
    try h.expectRun(1, &.{ "run", "download", "41", "-R", "owner/repo", "-n", "nothing*", "-D", try h.path("out") });
}

test "workflow list takes the first workflow directory that exists; run dispatches on the default branch" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo/contents/.forgejo/workflows", .status = 404, .body = "{}" },
        .{ .path = "/api/v1/repos/owner/repo/contents/.gitea/workflows", .status = 404, .body = "{}" },
        .{ .path = "/api/v1/repos/owner/repo/contents/.github/workflows", .body = "[{\"name\":\"ci.yml\",\"path\":\".github/workflows/ci.yml\",\"type\":\"file\"},{\"name\":\"README\",\"path\":\"x\",\"type\":\"file\"}]" },
        .{ .method = .POST, .path = actions ++ "/workflows/deploy.yml/dispatches", .status = 201, .body = "{\"id\":77,\"run_number\":3}" },
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
    }, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "release" });
    try h.expectRun(0, &.{ "workflow", "list" });
    try std.testing.expectEqualStrings("ci.yml\t.github/workflows/ci.yml\n", h.stdout());
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "from a file" });
    try h.expectRun(0, &.{ "workflow", "run", ".forgejo/workflows/deploy.yml", "-f", "env=@prod", "-F", try std.fmt.allocPrint(h.arena.allocator(), "notes=@{s}", .{try h.path("notes.txt")}) });
    try std.testing.expectEqualStrings("{\"ref\":\"main\",\"inputs\":{\"env\":\"@prod\",\"notes\":\"from a file\"},\"return_run_info\":true}", h.mock.lastBody(.POST, actions ++ "/workflows/deploy.yml/dispatches").?);
    try h.expectErr("smith run watch 77");
}

test "secrets: set from stdin, list, delete; your own cannot be listed" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .PUT, .path = actions ++ "/secrets/TOKEN", .status = 201, .body = "" },
        .{ .path = actions ++ "/secrets", .body = "[{\"name\":\"TOKEN\",\"created_at\":\"2026-09-29T11:00:00Z\"}]" },
        .{ .method = .DELETE, .path = actions ++ "/secrets/TOKEN", .status = 204 },
        .{ .method = .PUT, .path = "/api/v1/orgs/team/actions/secrets/K", .status = 201, .body = "" },
    }, .{});
    defer h.deinit();
    h.ctx.stdin_data = "s3cr3t\n";
    try h.expectRun(0, &.{ "secret", "set", "TOKEN", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"data\":\"s3cr3t\"}", h.mock.lastBody(.PUT, actions ++ "/secrets/TOKEN").?);
    try h.expectRun(0, &.{ "secret", "list", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("TOKEN\t2026-09-29T11:00:00Z\n", h.stdout());
    try h.expectRun(1, &.{ "secret", "delete", "TOKEN", "-R", "owner/repo" });
    try h.expectErr("--yes");
    try h.expectRun(0, &.{ "secret", "delete", "TOKEN", "-R", "owner/repo", "--yes" });
    try h.expectRun(0, &.{ "secret", "set", "K", "--org", "team", "-b", "v" });
    try h.expectRun(1, &.{ "secret", "list", "--user" });
    try h.expectErr("cannot list your own secrets");
    try h.expectRun(1, &.{ "secret", "list", "--user", "--org", "team" });
    h.ctx.stdin_tty = true;
    h.ctx.stdout_tty = true;
    try h.env.put("SMITH_PROMPT_DISABLED", "1");
    h.ctx.stdin_data = "from-stdin\n";
    try h.expectRun(0, &.{ "secret", "set", "TOKEN", "-R", "owner/repo" });
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "Value for") == null);
    try std.testing.expectEqualStrings("{\"data\":\"from-stdin\"}", h.mock.lastBody(.PUT, actions ++ "/secrets/TOKEN").?);
}

test "variables: set creates when missing and updates otherwise, get prints the value" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .PUT, .path = actions ++ "/variables/REGION", .status = 404, .body = "{}", .times = 1 },
        .{ .method = .POST, .path = actions ++ "/variables/REGION", .status = 201, .body = "" },
        .{ .method = .PUT, .path = actions ++ "/variables/REGION", .status = 204, .body = "" },
        .{ .path = actions ++ "/variables/REGION", .body = "{\"name\":\"REGION\",\"data\":\"eu\"}" },
        .{ .path = "/api/v1/user/actions/variables", .body = "[{\"name\":\"A\",\"data\":\"1\"}]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "variable", "set", "REGION", "-b", "eu", "-R", "owner/repo" });
    try h.expectErr("Created variable REGION");
    try std.testing.expectEqualStrings("{\"value\":\"eu\"}", h.mock.lastBody(.POST, actions ++ "/variables/REGION").?);
    try h.expectRun(0, &.{ "variable", "set", "REGION", "-b", "us", "-R", "owner/repo" });
    try h.expectErr("Updated variable REGION");
    try h.expectRun(0, &.{ "variable", "get", "REGION", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("eu\n", h.stdout());
    try h.expectRun(0, &.{ "variable", "list", "--user" });
    try std.testing.expectEqualStrings("A\t1\n", h.stdout());
    try h.expectRun(1, &.{ "variable", "delete", "A", "--user" });
    try h.expectErr("--yes");
}
