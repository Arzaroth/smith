const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const labels = "/api/v1/repos/owner/repo/labels";
const milestones = "/api/v1/repos/owner/repo/milestones";
const milestone =
    \\{"id":4,"title":"v1.0","description":"First cut","state":"open","open_issues":1,"closed_issues":3,"due_on":"2026-10-31T23:59:59Z"}
;

test "label list, create with a normalised colour, edit, delete" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = labels, .body = fx.labels },
        .{ .method = .POST, .path = labels, .status = 201, .body = "{}" },
        .{ .method = .PATCH, .path = labels ++ "/2", .body = "{}" },
        .{ .method = .DELETE, .path = labels ++ "/1", .status = 204 },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "label", "list", "-R", "owner/repo" });
    try h.expectOut("bug\t\tee0701\nui\t\t00aabb\n");
    try h.expectRun(0, &.{ "label", "create", "perf", "-c", "#ABC123", "-d", "Slow things", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"name\":\"perf\",\"color\":\"#ABC123\",\"description\":\"Slow things\",\"exclusive\":false}", h.mock.lastBody(.POST, labels).?);
    try h.expectRun(1, &.{ "label", "create", "x", "-c", "red", "-R", "owner/repo" });
    try h.expectErr("six hex digits");
    try h.expectRun(0, &.{ "label", "edit", "UI", "-n", "frontend", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"name\":\"frontend\"}", h.mock.lastBody(.PATCH, labels ++ "/2").?);
    h.ctx.stdin_tty = true;
    h.ctx.stdout_tty = true;
    for ([_][]const u8{ "n\n", "\n" }) |answer| {
        h.ctx.stdin_data = answer;
        try h.expectRun(1, &.{ "label", "delete", "bug", "-R", "owner/repo" });
        try std.testing.expectEqual(@as(usize, 0), h.mock.count(.DELETE, labels ++ "/1"));
    }
    h.ctx.stdin_data = "y\n";
    try h.expectRun(0, &.{ "label", "delete", "bug", "-R", "owner/repo" });
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.DELETE, labels ++ "/1"));
    h.ctx.stdin_tty = false;
    h.ctx.stdout_tty = false;
    try h.expectRun(0, &.{ "label", "delete", "bug", "-y", "-R", "owner/repo" });
    try std.testing.expectEqual(@as(usize, 2), h.mock.count(.DELETE, labels ++ "/1"));
}

test "label clone creates what is missing and updates the rest with --force" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/tmpl/base/labels", .body = "[{\"id\":7,\"name\":\"bug\",\"color\":\"#000000\"},{\"id\":8,\"name\":\"docs\",\"color\":\"#111111\"}]" },
        .{ .path = labels, .body = fx.labels },
        .{ .method = .POST, .path = labels, .status = 201, .body = "{}" },
        .{ .method = .PATCH, .path = labels ++ "/1", .body = "{}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "label", "clone", "tmpl/base", "-R", "owner/repo" });
    try h.expectErr("1 created, 0 updated");
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, labels).?, "\"name\":\"docs\"") != null);
    try h.expectRun(0, &.{ "label", "clone", "tmpl/base", "-R", "owner/repo", "--force" });
    try h.expectErr("1 created, 1 updated");
}

test "milestone list, view by title, create with a due date, close, delete" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = milestones, .query = "state=all", .body = "[" ++ milestone ++ "]" },
        .{ .path = milestones ++ "/v1.0", .body = milestone },
        .{ .method = .POST, .path = milestones, .status = 201, .body = milestone },
        .{ .method = .PATCH, .path = milestones ++ "/v1.0", .body = milestone },
        .{ .method = .DELETE, .path = milestones ++ "/4", .status = 204 },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "milestone", "list", "-s", "all", "-R", "owner/repo" });
    try h.expectOut("v1.0\t3/4 closed (75%)\tdue 2026-10-31\topen\n");
    try h.expectRun(0, &.{ "milestone", "view", "v1.0", "-R", "owner/repo" });
    try h.expectOut("First cut");
    try h.expectRun(0, &.{ "milestone", "create", "v1.0", "--due", "2026-10-31", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"title\":\"v1.0\",\"description\":\"\",\"due_on\":\"2026-10-31T23:59:59Z\"}", h.mock.lastBody(.POST, milestones).?);
    try h.expectRun(1, &.{ "milestone", "create", "x", "--due", "next week", "-R", "owner/repo" });
    try h.expectRun(0, &.{ "milestone", "close", "v1.0", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"state\":\"closed\"}", h.mock.lastBody(.PATCH, milestones ++ "/v1.0").?);
    try h.expectRun(0, &.{ "milestone", "delete", "v1.0", "-y", "-R", "owner/repo" });
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.DELETE, milestones ++ "/4"));
}

test "issue create --milestone sends its id; an unknown one fails first" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = milestones ++ "/v1.0", .body = milestone },
        .{ .path = milestones ++ "/nope", .status = 404, .body = "{}" },
        .{ .method = .POST, .path = "/api/v1/repos/owner/repo/issues", .status = 201, .body = fx.issue_open },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "create", "-R", "owner/repo", "-t", "x", "-b", "y", "-m", "v1.0" });
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, "/api/v1/repos/owner/repo/issues").?, "\"milestone\":4") != null);
    try h.expectRun(1, &.{ "issue", "create", "-R", "owner/repo", "-t", "x", "-b", "y", "-m", "nope" });
    try h.expectErr("no milestone \"nope\"");
}

test "due dates are days in the local zone, whatever zone Forgejo answers in" {
    var h: Harness = undefined;
    const paris = "{\"id\":5,\"title\":\"winter\",\"state\":\"open\",\"open_issues\":0,\"closed_issues\":0,\"due_on\":\"2026-12-31T23:59:59+01:00\"}";
    const tokyo = "{\"id\":6,\"title\":\"summer\",\"state\":\"open\",\"open_issues\":0,\"closed_issues\":0,\"due_on\":\"2026-07-15T06:59:59+09:00\"}";
    try h.init(&.{
        .{ .path = milestones, .body = "[" ++ paris ++ "," ++ tokyo ++ "]" },
        .{ .method = .POST, .path = milestones, .status = 201, .body = paris },
    }, .{});
    defer h.deinit();
    try h.env.put("TZ", "CET-1CEST,M3.5.0,M10.5.0/3");
    try h.expectRun(0, &.{ "milestone", "create", "winter", "--due", "2026-12-31", "-R", "owner/repo" });
    try h.expectRun(0, &.{ "milestone", "create", "summer", "--due", "2026-07-14", "-R", "owner/repo" });
    var bodies: [2][]const u8 = undefined;
    var n: usize = 0;
    for (h.mock.requests.items) |r| if (r.method == .POST) {
        bodies[n] = r.body;
        n += 1;
    };
    try std.testing.expect(std.mem.indexOf(u8, bodies[0], "\"due_on\":\"2026-12-31T22:59:59Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bodies[1], "\"due_on\":\"2026-07-14T21:59:59Z\"") != null);
    try h.expectRun(0, &.{ "milestone", "list", "-R", "owner/repo" });
    try h.expectOut("winter\t0/0 closed (0%)\tdue 2026-12-31\topen\n");
    try h.expectOut("summer\t0/0 closed (0%)\tdue 2026-07-14\topen\n");
}
