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
    const a = comptime found("1");
    const b = comptime found("2");
    const c = comptime found("3");
    const d = comptime found("4");
    try h.init(&.{
        .{ .path = "/api/v1/repos/issues/search", .query = "type=issues&assigned=true", .body = "[" ++ a ++ "]" },
        .{ .path = "/api/v1/repos/issues/search", .query = "type=pulls&assigned=true", .body = "[" ++ b ++ "]" },
        .{ .path = "/api/v1/repos/issues/search", .query = "type=pulls&review_requested=true", .body = "[" ++ c ++ "]" },
        .{ .path = "/api/v1/repos/issues/search", .query = "type=issues&mentioned=true", .body = "[" ++ d ++ "]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{"status"});
    const out = h.stdout();
    const titles = [_][]const u8{ "Assigned issues", "Assigned pull requests", "Review requests", "Mentions" };
    for (titles, 0..) |t, i| {
        const start = std.mem.indexOf(u8, out, t).?;
        const end = if (i + 1 < titles.len) std.mem.indexOf(u8, out, titles[i + 1]).? else out.len;
        const want = try std.fmt.allocPrint(h.arena.allocator(), "team/app\t{d}\t", .{i + 1});
        try std.testing.expect(std.mem.indexOf(u8, out[start..end], want) != null);
    }
    try h.expectRun(0, &.{ "status", "--json" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqual(@as(i64, 3), v.object.get("review_requests").?.array.items[0].object.get("number").?.integer);
}

test "status says when a section is empty and needs a login" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/issues/search", .body = "[]" }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{"status"});
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, h.stdout(), "  Nothing here\n"));

    var anon: Harness = undefined;
    try anon.init(&.{}, .{ .token = null });
    defer anon.deinit();
    try anon.expectRun(4, &.{"status"});
    try anon.expectErr("status needs a login; run `smith auth login --hostname 127.0.0.1:");
    try std.testing.expectEqual(@as(usize, 0), anon.mock.requests.items.len);
}

fn found(comptime n: []const u8) []const u8 {
    return "{\"number\":" ++ n ++ ",\"title\":\"Item\",\"state\":\"open\",\"updated_at\":\"2026-09-29T10:00:00Z\",\"repository\":{\"full_name\":\"team/app\"}}";
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

test "ssh-key, gpg-key and org list: tables, --json, and keys to list or not" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/user/keys", .body = "[{\"id\":8,\"title\":\"laptop\"}]", .times = 2 },
        .{ .path = "/api/v1/user/keys", .body = "[]" },
        .{ .path = "/api/v1/user/gpg_keys", .body = "[{\"id\":9,\"key_id\":\"ABCD\",\"emails\":[{\"email\":\"me@example.com\"},{\"email\":\"me@work.test\"}],\"created_at\":\"2026-09-28T12:00:00Z\"}]", .times = 2 },
        .{ .path = "/api/v1/user/gpg_keys", .body = "[]" },
        .{ .method = .DELETE, .path = "/api/v1/user/gpg_keys/9", .status = 204 },
        .{ .path = "/api/v1/user/orgs", .body = "[{\"username\":\"team\"}]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "ssh-key", "list", "--json" });
    try h.expectOut("\"title\": \"laptop\"");
    try h.expectRun(0, &.{ "ssh-key", "list" });
    try h.expectOut("laptop");
    try h.expectRun(0, &.{ "ssh-key", "list" });
    try std.testing.expectEqualStrings("", h.stdout());
    try h.expectErr("No SSH keys");

    try h.expectRun(0, &.{ "gpg-key", "list", "--json" });
    try h.expectOut("\"key_id\": \"ABCD\"");
    try h.expectRun(0, &.{ "gpg-key", "list" });
    try std.testing.expectEqualStrings("9\tABCD\tme@example.com, me@work.test\t2026-09-28T12:00:00Z\n", h.stdout());
    try h.expectRun(0, &.{ "gpg-key", "list" });
    try h.expectErr("No GPG keys");

    try h.expectRun(1, &.{ "gpg-key", "delete", "x9", "-y" });
    try h.expectErr("invalid key id: x9");
    try h.expectRun(0, &.{ "gpg-key", "delete", "9", "-y" });
    try h.expectErr("Deleted GPG key 9");
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.DELETE, "/api/v1/user/gpg_keys/9"));

    try h.expectRun(0, &.{ "org", "list", "--json" });
    try h.expectOut("\"username\": \"team\"");
    try h.expectRun(0, &.{ "org", "list" });
    try std.testing.expectEqualStrings("team\t\t\n", h.stdout());
}
