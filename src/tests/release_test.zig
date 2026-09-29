const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const releases = "/api/v1/repos/owner/repo/releases";

fn releaseJson(h: *Harness) ![]const u8 {
    return std.mem.replaceOwned(u8, h.arena.allocator(), fx.release, "BASE", try h.base());
}

fn setRoutes(h: *Harness, routes: []const Harness.Mock.Route) !void {
    h.mock.routes = try h.arena.allocator().dupe(Harness.Mock.Route, routes);
    h.mock.used = try h.arena.allocator().alloc(u32, routes.len);
    @memset(h.mock.used, 0);
}

test "list marks the latest; view shows the assets" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const rel = try releaseJson(&h);
    try setRoutes(&h, &.{
        .{ .path = releases, .body = try std.fmt.allocPrint(h.arena.allocator(), "[{s}]", .{rel}) },
        .{ .path = releases ++ "/latest", .body = rel },
    });
    try h.expectRun(0, &.{ "release", "list", "-R", "owner/repo" });
    try h.expectOut("One\tLatest\tv1.0.0\t1 day ago\n");
    try h.expectRun(0, &.{ "release", "view", "-R", "owner/repo" });
    try h.expectOut("alice released this 1 day ago · tag v1.0.0");
    try h.expectOut("smith-linux.tar.gz\t1.5 KiB\t4 downloads");
}

test "create sends the release and uploads each file as a multipart attachment" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const rel = try releaseJson(&h);
    const bare = try std.mem.replaceOwned(u8, h.arena.allocator(), rel, "\"assets\":[", "\"assets\":[],\"x\":[");
    try setRoutes(&h, &.{
        .{ .method = .POST, .path = releases, .status = 201, .body = bare },
        .{ .method = .POST, .path = releases ++ "/9/assets", .status = 201, .body = "{\"id\":3,\"name\":\"a.txt\"}" },
    });
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "payload" });
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.md", .data = "Fixed things." });
    h.ctx.cwd = h.root;
    try h.expectRun(0, &.{ "release", "create", "v1.0.0", try h.path("a.txt"), "-R", "owner/repo", "-F", try h.path("notes.md"), "--prerelease" });
    try h.expectOut("http://forge.test/owner/repo/releases/tag/v1.0.0\n");
    try h.expectErr("Uploaded a.txt (7 B)");

    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.mock.lastBody(.POST, releases).?, .{});
    try std.testing.expectEqualStrings("v1.0.0", v.object.get("name").?.string);
    try std.testing.expectEqualStrings("Fixed things.", v.object.get("body").?.string);
    try std.testing.expect(v.object.get("prerelease").?.bool);

    var upload: ?Harness.Mock.Request = null;
    for (h.mock.requests.items) |r| if (std.mem.startsWith(u8, r.target, releases ++ "/9/assets")) {
        upload = r;
    };
    try std.testing.expect(std.mem.indexOf(u8, upload.?.target, "name=a.txt") != null);
    try std.testing.expect(std.mem.startsWith(u8, upload.?.header("content-type").?, "multipart/form-data; boundary=smith-"));
    try std.testing.expect(std.mem.indexOf(u8, upload.?.body, "name=\"attachment\"; filename=\"a.txt\"\r\nContent-Type: application/octet-stream\r\n\r\npayload\r\n--smith-") != null);
}

test "upload refuses to replace an asset unless --clobber" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{
        .{ .path = releases ++ "/tags/v1.0.0", .body = try releaseJson(&h) },
        .{ .method = .DELETE, .path = releases ++ "/9/assets/2", .status = 204 },
        .{ .method = .POST, .path = releases ++ "/9/assets", .status = 201, .body = "{}" },
    });
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "SHA256SUMS", .data = "x" });
    try h.expectRun(1, &.{ "release", "upload", "v1.0.0", try h.path("SHA256SUMS"), "-R", "owner/repo" });
    try h.expectErr("pass --clobber");
    try h.expectRun(0, &.{ "release", "upload", "v1.0.0", try h.path("SHA256SUMS"), "-R", "owner/repo", "--clobber" });
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.DELETE, releases ++ "/9/assets/2"));
}

test "download fetches the matching assets into a directory" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{
        .{ .path = releases ++ "/latest", .body = try releaseJson(&h) },
        .{ .path = "/attachments/1", .body = "tarball", .content_type = "application/octet-stream" },
        .{ .path = "/attachments/2", .body = "sums", .content_type = "text/plain" },
    });
    const dir = try h.path("out");
    try h.expectRun(0, &.{ "release", "download", "-R", "owner/repo", "-p", "*.tar.gz", "-D", dir });
    const got = try h.tmp.dir.readFileAlloc(std.testing.io, "out/smith-linux.tar.gz", h.arena.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("tarball", got);
    try std.testing.expectError(error.FileNotFound, h.tmp.dir.access(std.testing.io, "out/SHA256SUMS", .{}));
    try h.expectRun(1, &.{ "release", "download", "-R", "owner/repo", "-p", "*.tar.gz", "-D", dir });
    try h.expectErr("already exists");
    try h.expectRun(1, &.{ "release", "download", "-R", "owner/repo", "-p", "*.zip", "-D", dir });
    try h.expectErr("no assets to download");
}

test "delete needs --yes off a terminal, and can remove the tag" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{
        .{ .path = releases ++ "/tags/v1.0.0", .body = try releaseJson(&h) },
        .{ .method = .DELETE, .path = releases ++ "/9", .status = 204 },
        .{ .method = .DELETE, .path = "/api/v1/repos/owner/repo/tags/v1.0.0", .status = 204 },
    });
    try h.expectRun(1, &.{ "release", "delete", "v1.0.0", "-R", "owner/repo" });
    try h.expectErr("Pass --yes");
    try h.expectRun(0, &.{ "release", "delete", "v1.0.0", "-R", "owner/repo", "-y", "--cleanup-tag" });
    try h.expectErr("Deleted release v1.0.0");
    try h.expectErr("Deleted tag v1.0.0");
}

test "edit publishes a draft and renames it" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{
        .{ .path = releases ++ "/tags/v1.0.0", .body = try releaseJson(&h) },
        .{ .method = .PATCH, .path = releases ++ "/9", .body = try releaseJson(&h) },
    });
    try h.expectRun(0, &.{ "release", "edit", "v1.0.0", "-R", "owner/repo", "--publish", "-t", "Renamed" });
    try std.testing.expectEqualStrings("{\"name\":\"Renamed\",\"draft\":false}", h.mock.lastBody(.PATCH, releases ++ "/9").?);
    try h.expectRun(1, &.{ "release", "edit", "v1.0.0", "-R", "owner/repo", "--publish", "--draft" });
}
