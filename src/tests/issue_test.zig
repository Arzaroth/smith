const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const issues = "/api/v1/repos/owner/repo/issues";

test "list resolves the repository from the origin remote and filters" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = issues, .body = fx.issue_list }}, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");

    try h.expectRun(0, &.{ "issue", "list", "-l", "bug", "-A", "alice", "-s", "all" });
    try h.expectOut("7\tCrash on start\tbug\topen\t2026-09-29T09:00:00Z\n");
    const target = h.mock.requests.items[0].target;
    for ([_][]const u8{ "type=issues", "state=all", "labels=bug", "created_by=alice", "page=1", "limit=30" }) |want| {
        if (std.mem.indexOf(u8, target, want) == null) {
            std.debug.print("{s} lacks {s}\n", .{ target, want });
            return error.TestExpectedEqual;
        }
    }
}

test "list --json prints the API objects" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = issues, .body = fx.issue_list }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo", "--json" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqual(@as(i64, 7), v.array.items[0].object.get("number").?.integer);
}

test "list rejects an unknown state" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "issue", "list", "-R", "owner/repo", "-s", "sideways" });
    try h.expectErr("--state must be");
}

test "view shows the issue and its comments" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = issues ++ "/7", .body = fx.issue_open },
        .{ .path = issues ++ "/7/comments", .body = fx.comments },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "view", "#7", "-R", "owner/repo", "--comments" });
    try h.expectOut("Crash on start #7");
    try h.expectOut("Open · alice opened 1 day ago · 1 comment");
    try h.expectOut("Labels: bug");
    try h.expectOut("Assignees: bob");
    try h.expectOut("It crashes.");
    try h.expectOut("bob commented about 2 hours ago");
    try h.expectOut("Same here.");
}

test "view of a missing issue reports the API message" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = issues ++ "/99", .status = 404, .body = "{\"message\":\"issue does not exist\"}" }}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "issue", "view", "99", "-R", "owner/repo" });
    try h.expectErr("issue does not exist (HTTP 404");
}

test "create resolves label names and sends the issue" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo/labels", .body = fx.labels },
        .{ .path = "/api/v1/orgs/owner/labels", .status = 404, .body = "{}" },
        .{ .method = .POST, .path = issues, .status = 201, .body = fx.issue_open },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "create", "-R", "owner/repo", "-t", "Crash on start", "-b", "It crashes.", "-l", "UI,bug", "-a", "bob" });
    try h.expectOut("http://forge.test/owner/repo/issues/7");
    const body = h.mock.lastBody(.POST, issues).?;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), body, .{});
    try std.testing.expectEqualStrings("Crash on start", v.object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 2), v.object.get("labels").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 1), v.object.get("labels").?.array.items[1].integer);
    try std.testing.expectEqualStrings("bob", v.object.get("assignees").?.array.items[0].string);
}

test "create with an unknown label fails before posting" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo/labels", .body = fx.labels },
        .{ .path = "/api/v1/orgs/owner/labels", .status = 404, .body = "{}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "issue", "create", "-R", "owner/repo", "-t", "x", "-b", "y", "-l", "nope" });
    try h.expectErr("no label named \"nope\"");
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.POST, issues));
}

test "create without a title off a terminal fails" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "issue", "create", "-R", "owner/repo", "-b", "y" });
    try h.expectErr("--title and --body are required when not running interactively");
}

test "create reads the body from standard input" {
    var h: Harness = undefined;
    try h.init(&.{.{ .method = .POST, .path = issues, .status = 201, .body = fx.issue_open }}, .{});
    defer h.deinit();
    h.ctx.stdin_data = "from stdin";
    try h.expectRun(0, &.{ "issue", "create", "-R", "owner/repo", "-t", "x", "-F", "-" });
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, issues).?, "\"body\":\"from stdin\"") != null);
}

test "close comments first, then closes; closing twice is a no-op" {
    var h: Harness = undefined;
    const closed = comptime blk: {
        var s: []const u8 = fx.issue_open;
        s = s[0..std.mem.indexOf(u8, s, "\"state\":\"open\"").?] ++ "\"state\":\"closed\"" ++ s[std.mem.indexOf(u8, s, "\"state\":\"open\"").? + "\"state\":\"open\"".len ..];
        break :blk s;
    };
    try h.init(&.{
        .{ .path = issues ++ "/7", .body = fx.issue_open, .times = 1 },
        .{ .path = issues ++ "/7", .body = closed },
        .{ .method = .POST, .path = issues ++ "/7/comments", .status = 201, .body = fx.comment },
        .{ .method = .PATCH, .path = issues ++ "/7", .status = 201, .body = closed },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "close", "7", "-R", "owner/repo", "-c", "Fixed in main" });
    try h.expectErr("Closed issue #7 (Crash on start)");
    try std.testing.expectEqualStrings("{\"state\":\"closed\"}", h.mock.lastBody(.PATCH, issues ++ "/7").?);
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, issues ++ "/7/comments").?, "Fixed in main") != null);

    try h.expectRun(0, &.{ "issue", "close", "7", "-R", "owner/repo" });
    try h.expectErr("already closed");
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.PATCH, issues ++ "/7"));
}

test "comment refuses an empty body" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "issue", "comment", "7", "-R", "owner/repo", "-b", "  " });
    try h.expectErr("the comment is empty");
}

test "edit changes the title, adds a label and drops an assignee" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = issues ++ "/7", .body = fx.issue_open },
        .{ .method = .PATCH, .path = issues ++ "/7", .status = 201, .body = fx.issue_open },
        .{ .path = "/api/v1/repos/owner/repo/labels", .body = fx.labels },
        .{ .path = "/api/v1/orgs/owner/labels", .status = 404, .body = "{}" },
        .{ .method = .POST, .path = issues ++ "/7/labels", .body = fx.labels },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "edit", "7", "-R", "owner/repo", "-t", "New title", "--add-label", "ui", "--remove-assignee", "bob", "--add-assignee", "carol" });
    try std.testing.expectEqualStrings("{\"labels\":[2]}", h.mock.lastBody(.POST, issues ++ "/7/labels").?);
    var patches: usize = 0;
    for (h.mock.requests.items) |r| if (r.method == .PATCH) {
        patches += 1;
        if (patches == 1) try std.testing.expectEqualStrings("{\"title\":\"New title\"}", r.body);
        if (patches == 2) try std.testing.expectEqualStrings("{\"assignees\":[\"carol\"]}", r.body);
    };
    try std.testing.expectEqual(@as(usize, 2), patches);
}
