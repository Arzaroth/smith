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

test "label list --json and an empty list, create with a random colour, edit of an unknown label" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = labels, .body = fx.labels },
        .{ .path = "/api/v1/repos/owner/bare/labels", .body = "[]" },
        .{ .method = .POST, .path = labels, .status = 201, .body = "{}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "label", "list", "-R", "owner/repo", "--json" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqualStrings("ui", v.array.items[1].object.get("name").?.string);
    try h.expectRun(0, &.{ "label", "list", "-R", "owner/bare" });
    try h.expectErr("No labels in owner/bare");
    try h.expectRun(0, &.{ "label", "create", "perf", "-R", "owner/repo" });
    const body = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.mock.lastBody(.POST, labels).?, .{});
    const colour = body.object.get("color").?.string;
    try std.testing.expectEqual(@as(usize, 7), colour.len);
    try std.testing.expectEqual(@as(u8, '#'), colour[0]);
    for (colour[1..]) |c| try std.testing.expect(std.ascii.isHex(c));
    try h.expectRun(1, &.{ "label", "edit", "nope", "-n", "x", "-R", "owner/repo" });
    try h.expectErr("no label named \"nope\" in owner/repo");
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

test "milestone list --json and an empty list, view --json, edit, reopen" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = milestones, .body = "[" ++ milestone ++ "]" },
        .{ .path = "/api/v1/repos/owner/bare/milestones", .query = "state=closed", .body = "[]" },
        .{ .path = milestones ++ "/v1.0", .body = milestone },
        .{ .method = .PATCH, .path = milestones ++ "/v1.0", .body = milestone },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "milestone", "list", "-R", "owner/repo", "--json" });
    const all = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqual(@as(i64, 4), all.array.items[0].object.get("id").?.integer);
    try h.expectRun(0, &.{ "milestone", "list", "-s", "closed", "-R", "owner/bare" });
    try h.expectErr("No closed milestones in owner/bare");
    try h.expectRun(0, &.{ "milestone", "view", "v1.0", "-R", "owner/repo", "--json" });
    const one = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqualStrings("First cut", one.object.get("description").?.string);
    try h.expectRun(0, &.{ "milestone", "edit", "v1.0", "-t", "v1.1", "-d", "Second cut", "--due", "2026-11-30", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"title\":\"v1.1\",\"description\":\"Second cut\",\"due_on\":\"2026-11-30T23:59:59Z\"}", h.mock.lastBody(.PATCH, milestones ++ "/v1.0").?);
    try h.expectErr("Updated milestone \"v1.0\"");
    try h.expectRun(0, &.{ "milestone", "reopen", "v1.0", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"state\":\"open\"}", h.mock.lastBody(.PATCH, milestones ++ "/v1.0").?);
    try h.expectErr("Reopened milestone \"v1.0\"");
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

/// A TZif v2 file with one standard time type, no transitions, and `footer`
/// as its POSIX rule: every date falls past the (absent) transitions.
fn zoneFile(h: *Harness, name: []const u8, footer: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(h.arena.allocator());
    const w = &out.writer;
    for (0..2) |_| {
        try w.writeAll("TZif2");
        try w.splatByteAll(0, 15);
        for ([_]u32{ 0, 0, 0, 0, 1, 4 }) |n| try w.writeInt(u32, n, .big);
        try w.writeInt(i32, 3600, .big);
        try w.writeAll(&.{ 0, 0 });
        try w.writeAll("CET\x00");
    }
    try w.print("\n{s}\n", .{footer});
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = out.written() });
    return h.path(name);
}

test "due dates follow a zone file's rule footer, and the local day, not the UTC one" {
    var h: Harness = undefined;
    const late = "{\"id\":7,\"title\":\"late\",\"state\":\"open\",\"open_issues\":0,\"closed_issues\":0,\"due_on\":\"2026-07-14T23:30:00Z\"}";
    try h.init(&.{
        .{ .path = milestones, .body = "[" ++ late ++ "]" },
        .{ .method = .POST, .path = milestones, .status = 201, .body = late },
    }, .{});
    defer h.deinit();
    const zone = try zoneFile(&h, "Paris", "CET-1CEST,M3.5.0,M10.5.0/3");
    try h.env.put("TZ", try std.fmt.allocPrint(h.arena.allocator(), ":{s}", .{zone}));
    try h.expectRun(0, &.{ "milestone", "list", "-R", "owner/repo" });
    try h.expectOut("late\t0/0 closed (0%)\tdue 2026-07-15\topen\n");
    try h.expectRun(0, &.{ "milestone", "create", "late", "--due", "2026-07-14", "-R", "owner/repo" });
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, milestones).?, "\"due_on\":\"2026-07-14T21:59:59Z\"") != null);

    try h.env.put("TZ", "<-02>2<-01>,M3.5.0/-1,M10.5.0/0");
    try h.expectRun(0, &.{ "milestone", "create", "late", "--due", "2026-10-24", "-R", "owner/repo" });
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, milestones).?, "\"due_on\":\"2026-10-25T01:59:59Z\"") != null);
    try h.env.put("TZ", "EST5EDT");
    try h.expectRun(0, &.{ "milestone", "create", "late", "--due", "2026-07-14", "-R", "owner/repo" });
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, milestones).?, "\"due_on\":\"2026-07-15T03:59:59Z\"") != null);

    try h.expectRun(1, &.{ "milestone", "create", "x", "--due", "2026-02-31", "-R", "owner/repo" });
    try h.expectErr("--due takes a date as YYYY-MM-DD");
    try h.env.put("TZ", "EST5");
    try h.expectRun(1, &.{ "milestone", "create", "x", "--due", "9999-12-31", "-R", "owner/repo" });
    try h.expectErr("out of range");
    try h.env.put("TZ", "AAA-9999999999999999");
    try h.expectRun(0, &.{ "milestone", "list", "-R", "owner/repo" });
}
