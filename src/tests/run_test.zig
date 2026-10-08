const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const runs = "/api/v1/repos/owner/repo/actions/runs";

test "list shows runs and passes the filters as Forgejo names them" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = runs, .body = fx.runs }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "run", "list", "-R", "owner/repo", "-b", "main", "-s", "failure", "-w", "ci.yml", "-L", "5" });
    try h.expectOut("success\tRun 40\tci.yml\tmain\tpush\t40\t1m 5s\t2026-09-29T11:00:00Z\n");
    try h.expectOut("failure\tRun 41\t");
    const target = h.mock.requests.items[0].target;
    for ([_][]const u8{ "ref=refs%2Fheads%2Fmain", "status=failure", "workflow_id=ci.yml", "limit=5" }) |want| {
        if (std.mem.indexOf(u8, target, want) == null) {
            std.debug.print("{s} lacks {s}\n", .{ target, want });
            return error.TestExpectedEqual;
        }
    }
}

test "view shows the run and its jobs; --exit-status reflects a failure" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs ++ "/41", .body = fx.run_failed },
        .{ .path = runs ++ "/41/jobs", .body = fx.jobs },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "run", "view", "41", "-R", "owner/repo" });
    try h.expectOut("X main ci.yml · 41");
    try h.expectOut("Triggered via push about 1 hour ago by alice · took 1m 5s · failure");
    try h.expectOut("✓ build (ID 500, success)");
    try h.expectOut("X test (ID 501, failure)");
    try h.expectRun(1, &.{ "run", "view", "41", "-R", "owner/repo", "--exit-status" });
}

test "view --log-failed prints only the failed job's log, prefixed with its name" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs ++ "/41", .body = fx.run_failed },
        .{ .path = runs ++ "/41/jobs", .body = fx.jobs },
        .{ .path = "/api/v1/repos/owner/repo/actions/jobs/501/logs", .body = "step one\nboom\n", .content_type = "text/plain" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "run", "view", "41", "-R", "owner/repo", "--log-failed" });
    try std.testing.expectEqualStrings("test\tstep one\ntest\tboom\n", h.stdout());
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.GET, "/api/v1/repos/owner/repo/actions/jobs/500/logs"));
}

test "view without an id takes the current branch's latest run" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs, .query = "ref=refs%2Fheads%2Ffeature", .body = fx.runs_feature },
        .{ .path = runs ++ "/42/jobs", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "feature" });
    try h.expectRun(0, &.{ "run", "view" });
    try h.expectOut("* feature ci.yml · 42");
}

test "watch polls until the run finishes" {
    var h: Harness = undefined;
    const done = comptime blk: {
        const s: []const u8 = fx.run_running;
        const i = std.mem.indexOf(u8, s, "\"running\"").?;
        break :blk s[0..i] ++ "\"success\"" ++ s[i + "\"running\"".len ..];
    };
    try h.init(&.{
        .{ .path = runs ++ "/42", .body = fx.run_running, .times = 2 },
        .{ .path = runs ++ "/42", .body = done },
        .{ .path = runs ++ "/42/jobs", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "run", "watch", "42", "-R", "owner/repo", "-i", "0", "--exit-status" });
    try h.expectErr("Run 42 finished: success");
    try std.testing.expectEqual(@as(usize, 3), h.mock.count(.GET, runs ++ "/42"));
}

test "watch stops on a run that needs approval or whose status is unknown" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs ++ "/43", .body = fx.run_blocked },
        .{ .path = runs ++ "/44", .body = fx.run_unknown },
        .{ .path = runs ++ "/43/jobs", .body = "[]" },
        .{ .path = runs ++ "/44/jobs", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(8, &.{ "run", "watch", "43", "-R", "owner/repo", "-i", "0" });
    try h.expectErr("needs approval");
    try h.expectRun(1, &.{ "run", "watch", "44", "-R", "owner/repo", "-i", "0" });
    try h.expectErr("does not know the status of run 44");
}

test "watch keeps waiting on a run blocked only by its job order" {
    var h: Harness = undefined;
    const done = comptime blk: {
        const s: []const u8 = fx.run_running;
        const i = std.mem.indexOf(u8, s, "\"running\"").?;
        break :blk s[0..i] ++ "\"success\"" ++ s[i + "\"running\"".len ..];
    };
    const queued = comptime blk: {
        const s: []const u8 = fx.run_running;
        const i = std.mem.indexOf(u8, s, "\"running\"").?;
        break :blk s[0..i] ++ "\"blocked\"" ++ s[i + "\"running\"".len ..];
    };
    try h.init(&.{
        .{ .path = runs ++ "/42", .body = queued, .times = 2 },
        .{ .path = runs ++ "/42", .body = done },
        .{ .path = runs ++ "/42/jobs", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "run", "watch", "42", "-R", "owner/repo", "-i", "0" });
    try h.expectErr("Run 42 finished: success");
}

test "cancel posts for a running run and refuses a finished one" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs ++ "/42", .body = fx.run_running },
        .{ .path = runs ++ "/40", .body = fx.run_ok },
        .{ .method = .POST, .path = runs ++ "/42/cancel", .body = "" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "run", "cancel", "42", "-R", "owner/repo" });
    try h.expectErr("Cancelled run 42");
    try h.expectRun(1, &.{ "run", "cancel", "40", "-R", "owner/repo" });
    try h.expectErr("already finished (success)");
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.POST, runs ++ "/42/cancel"));
}

test "list --json, an empty list, status marks on a terminal, and --web" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs, .body = fx.runs },
        .{ .path = "/api/v1/repos/owner/idle/actions/runs", .body = "{\"total_count\":0,\"workflow_runs\":[]}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "run", "list", "-R", "owner/repo", "--json" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqual(@as(usize, 2), v.array.items.len);
    try std.testing.expectEqual(@as(i64, 40), v.array.items[0].object.get("id").?.integer);
    try h.expectRun(0, &.{ "run", "list", "-R", "owner/idle" });
    try h.expectErr("No runs found in owner/idle");

    h.ctx.stdout_tty = true;
    try h.expectRun(0, &.{ "run", "list", "-R", "owner/repo" });
    try h.expectOut("✓");
    try h.expectOut("X");
    try std.testing.expect(std.mem.indexOf(u8, h.stdout(), "success") == null);
    const before = h.mock.requests.items.len;
    try h.expectRun(0, &.{ "run", "list", "-R", "owner/repo", "--web" });
    try h.expectErr(try std.fmt.allocPrint(h.arena.allocator(), "Opening {s}/owner/repo/actions in your browser.", .{try h.base()}));
    try std.testing.expectEqual(before, h.mock.requests.items.len);
}

test "view --json keeps the exit status, --web opens the run, --log names a job without logs" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs ++ "/41", .body = fx.run_failed },
        .{ .path = runs ++ "/41/jobs", .body = fx.jobs },
        .{ .path = "/api/v1/repos/owner/repo/actions/jobs/500/logs", .status = 404, .body = "{}" },
        .{ .path = "/api/v1/repos/owner/repo/actions/jobs/501/logs", .body = "boom\n", .content_type = "text/plain" },
    }, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "run", "view", "41", "-R", "owner/repo", "--json", "--exit-status" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqualStrings("failure", v.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.GET, runs ++ "/41/jobs"));

    try h.expectRun(0, &.{ "run", "view", "41", "-R", "owner/repo", "--log" });
    try h.expectErr("! no logs for job build (HTTP 404)");
    try std.testing.expectEqualStrings("test\tboom\n", h.stdout());

    h.ctx.stdout_tty = true;
    try h.expectRun(0, &.{ "run", "view", "41", "-R", "owner/repo", "--web" });
    try h.expectErr("Opening http://forge.test/owner/repo/actions/runs/41 in your browser.");
}

test "download reads artifacts wrapped in an object" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = runs ++ "/41", .body = fx.run_failed },
        .{ .path = runs ++ "/41/artifacts", .body = "{\"total_count\":1,\"artifacts\":[{\"id\":2,\"name\":\"old\",\"expired\":true}]}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "run", "download", "41", "-R", "owner/repo", "-D", try h.path("out") });
    try h.expectErr("old has expired");
    try h.expectErr("no artifacts to download from run 41");
}
