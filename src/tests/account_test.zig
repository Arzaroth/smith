const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const found_issue =
    \\{"number":3,"title":"Broken","state":"open","updated_at":"2026-09-29T10:00:00Z","repository":{"full_name":"team/app"}}
;

test "search repos narrows to an owner by id; search issues and prs send the type" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/users/team", .body = "{\"id\":42,\"login\":\"team\"}" },
        .{ .path = "/api/v1/repos/search", .query = "uid=42", .body = "{\"ok\":true,\"data\":[" ++ fx.repo ++ "]}" },
        .{ .path = "/api/v1/repos/issues/search", .query = "type=pulls", .body = "[" ++ found_issue ++ "]" },
        .{ .path = "/api/v1/repos/issues/search", .query = "type=issues", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "search", "repos", "repo", "--owner", "team" });
    try h.expectOut("owner/repo\tA test repository\tpublic");
    try std.testing.expect(std.mem.indexOf(u8, h.mock.requests.items[1].target, "exclusive=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.mock.requests.items[1].target, "archived=false") != null);
    try h.expectRun(0, &.{ "search", "prs", "broken", "--state", "all" });
    try std.testing.expectEqualStrings("team/app\t3\tBroken\topen\t2026-09-29T10:00:00Z\n", h.stdout());
    try h.expectRun(0, &.{ "search", "issues", "nothing" });
    try h.expectErr("No issues matched");
}

test "status fills each section from its own search" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/issues/search", .query = "review_requested=true", .body = "[" ++ found_issue ++ "]" },
        .{ .path = "/api/v1/repos/issues/search", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{"status"});
    const out = h.stdout();
    const review = std.mem.indexOf(u8, out, "Review requests").?;
    const mentions = std.mem.indexOf(u8, out, "Mentions").?;
    try std.testing.expect(std.mem.indexOf(u8, out[review..mentions], "team/app\t3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..review], "Nothing here") != null);
    try h.expectRun(0, &.{ "status", "--json" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqual(@as(usize, 1), v.object.get("review_requests").?.array.items.len);
}

test "notifications: list unread, mark one or all as read" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/notifications", .query = "all=false", .body = "[{\"id\":5,\"unread\":true,\"updated_at\":\"2026-09-29T11:00:00Z\",\"repository\":{\"full_name\":\"o/r\"},\"subject\":{\"title\":\"New PR\",\"type\":\"Pull\"}}]" },
        .{ .method = .PATCH, .path = "/api/v1/notifications/threads/5", .status = 205, .body = "" },
        .{ .method = .PUT, .path = "/api/v1/notifications", .status = 205, .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "notification", "list" });
    try std.testing.expectEqualStrings("unread\t5\to/r\tPull\tNew PR\t2026-09-29T11:00:00Z\n", h.stdout());
    try h.expectRun(0, &.{ "notification", "read", "5" });
    for (h.mock.requests.items) |r| if (r.method == .PATCH) try std.testing.expect(std.mem.indexOf(u8, r.target, "to-status=read") != null);
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.PATCH, "/api/v1/notifications/threads/5"));
    try h.expectRun(0, &.{ "notification", "read", "--all" });
    try h.expectRun(1, &.{ "notification", "read" });
}

test "ssh-key add takes the title from the key's comment; gpg-key add sends the armor" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .POST, .path = "/api/v1/user/keys", .status = 201, .body = "{\"id\":8,\"title\":\"me@laptop\"}" },
        .{ .path = "/api/v1/user/keys", .body = "[{\"id\":8,\"title\":\"me@laptop\",\"fingerprint\":\"SHA256:abc\",\"created_at\":\"2026-09-28T12:00:00Z\"}]" },
        .{ .method = .DELETE, .path = "/api/v1/user/keys/8", .status = 204 },
        .{ .method = .POST, .path = "/api/v1/user/gpg_keys", .status = 201, .body = "{\"id\":9,\"key_id\":\"ABCD\"}" },
    }, .{});
    defer h.deinit();
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "id.pub", .data = "ssh-ed25519 AAAAC3Nza me@laptop\n" });
    try h.expectRun(0, &.{ "ssh-key", "add", try h.path("id.pub") });
    try std.testing.expectEqualStrings("{\"key\":\"ssh-ed25519 AAAAC3Nza me@laptop\",\"title\":\"me@laptop\",\"read_only\":false}", h.mock.lastBody(.POST, "/api/v1/user/keys").?);
    try h.expectRun(0, &.{ "ssh-key", "list" });
    try std.testing.expectEqualStrings("8\tme@laptop\tSHA256:abc\t\t2026-09-28T12:00:00Z\n", h.stdout());
    try h.expectRun(1, &.{ "ssh-key", "delete", "8" });
    try h.expectRun(0, &.{ "ssh-key", "delete", "8", "-y" });
    h.ctx.stdin_data = "-----BEGIN PGP PUBLIC KEY BLOCK-----\nx\n-----END PGP PUBLIC KEY BLOCK-----\n";
    try h.expectRun(0, &.{ "gpg-key", "add" });
    try h.expectErr("Added GPG key ABCD (id 9)");
}

test "org list shows yours, or a user's" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/user/orgs", .body = "[{\"username\":\"team\",\"description\":\"The team\",\"visibility\":\"public\"}]" },
        .{ .path = "/api/v1/users/alice/orgs", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "org", "list" });
    try std.testing.expectEqualStrings("team\tThe team\tpublic\n", h.stdout());
    try h.expectRun(0, &.{ "org", "list", "alice" });
    try h.expectErr("No organizations");
}
