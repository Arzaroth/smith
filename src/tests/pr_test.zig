const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

const pulls = "/api/v1/repos/owner/repo/pulls";

fn json(h: *Harness, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), body, .{});
}

test "list shows open pull requests with draft and branch" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls, .query = "state=open", .body = fx.pr_list_open }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "list", "-R", "owner/repo", "-A", "alice" });
    try h.expectOut("12\tAdd feature\tfeature\topen\t2026-09-29T11:30:00Z\n");
    try h.expectOut("13\tWIP: Fork change\tpatch-1\tdraft\t2026-09-29T11:30:00Z\n");
    try std.testing.expect(std.mem.indexOf(u8, h.mock.requests.items[0].target, "poster=alice") != null);
}

test "list --state merged asks for closed ones and keeps the merged" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls, .query = "state=closed", .body = fx.pr_list_closed }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "list", "-R", "owner/repo", "-s", "merged" });
    try h.expectOut("14\tOld change");
    try std.testing.expect(std.mem.indexOf(u8, h.stdout(), "15\t") == null);
}

test "view by number shows the fork head as owner:branch" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls ++ "/13", .body = fx.pr_fork }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "view", "13", "-R", "owner/repo" });
    try h.expectOut("WIP: Fork change #13");
    try h.expectOut("Draft · alice wants to merge into main from alice:patch-1 · +10 -2 · 3 files");
    try h.expectOut("Does things.");
}

test "view without an argument finds the current branch's pull request" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls, .body = fx.pr_list_open }}, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "feature" });
    try h.expectRun(0, &.{ "pr", "view" });
    try h.expectOut("Add feature #12");

    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "lonely" });
    try h.expectRun(1, &.{ "pr", "view" });
    try h.expectErr("no pull request found for branch \"lonely\" of owner");
}

test "diff prints the raw diff; --name-only lists files" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .path = pulls ++ "/12.diff", .body = "diff --git a/x b/x\n+added\n", .content_type = "text/plain" },
        .{ .path = pulls ++ "/12/files", .body = "[{\"filename\":\"src/a.zig\"},{\"filename\":\"README.md\"}]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "diff", "12", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("diff --git a/x b/x\n+added\n", h.stdout());
    try h.expectRun(0, &.{ "pr", "diff", "12", "-R", "owner/repo", "--name-only" });
    try std.testing.expectEqualStrings("src/a.zig\nREADME.md\n", h.stdout());
}

test "create sends head, base, draft title, and requests reviewers" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .POST, .path = pulls, .status = 201, .body = fx.pr_same },
        .{ .method = .POST, .path = pulls ++ "/12/requested_reviewers", .status = 201, .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "create", "-R", "owner/repo", "-H", "feature", "-B", "main", "-t", "Add feature", "-b", "Body", "-d", "-r", "bob,carol" });
    try h.expectOut("http://forge.test/owner/repo/pulls/12\n");
    const v = try json(&h, h.mock.lastBody(.POST, pulls).?);
    try std.testing.expectEqualStrings("feature", v.object.get("head").?.string);
    try std.testing.expectEqualStrings("main", v.object.get("base").?.string);
    try std.testing.expectEqualStrings("WIP: Add feature", v.object.get("title").?.string);
    try std.testing.expectEqualStrings("{\"reviewers\":[\"bob\",\"carol\"]}", h.mock.lastBody(.POST, pulls ++ "/12/requested_reviewers").?);
}

test "create --fill takes the title and body from the only commit, pushed to a fork" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
        .{ .method = .POST, .path = pulls, .status = 201, .body = fx.pr_fork },
    }, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    const fork = try std.fmt.allocPrint(h.arena.allocator(), "{s}/alice/repo.git", .{try h.base()});
    try h.git(&.{ "-C", "work", "remote", "add", "fork", fork });
    try h.git(&.{ "-C", "work", "update-ref", "refs/remotes/origin/main", "HEAD" });
    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "patch-1" });
    try h.git(&.{ "-C", "work", "commit", "-q", "--allow-empty", "-m", "Fix the frobnicator", "-m", "It was broken." });
    try h.git(&.{ "-C", "work", "update-ref", "refs/remotes/fork/patch-1", "HEAD" });
    try h.git(&.{ "-C", "work", "branch", "-q", "--set-upstream-to=fork/patch-1" });

    try h.expectRun(0, &.{ "pr", "create", "--fill" });
    const v = try json(&h, h.mock.lastBody(.POST, pulls).?);
    try std.testing.expectEqualStrings("alice:patch-1", v.object.get("head").?.string);
    try std.testing.expectEqualStrings("main", v.object.get("base").?.string);
    try std.testing.expectEqualStrings("Fix the frobnicator", v.object.get("title").?.string);
    try std.testing.expectEqualStrings("It was broken.", v.object.get("body").?.string);
}

test "create refuses an unpushed branch" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "local-only" });
    try h.expectRun(1, &.{ "pr", "create", "-t", "x", "-b", "y" });
    try h.expectErr("is not pushed under its own name; run `git push -u origin local-only` first");
}

test "merge uses the repository's default style unless told otherwise" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
        .{ .method = .POST, .path = pulls ++ "/12/merge", .body = "", .times = 1 },
        .{ .method = .POST, .path = pulls ++ "/12/merge", .status = 201, .body = "", .times = 1 },
        .{ .method = .POST, .path = pulls ++ "/12/merge", .body = "" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "merge", "12", "-R", "owner/repo" });
    try h.expectErr("Merged pull request #12 (Add feature) with squash");
    var v = try json(&h, h.mock.lastBody(.POST, pulls ++ "/12/merge").?);
    try std.testing.expectEqualStrings("squash", v.object.get("Do").?.string);

    try h.expectRun(0, &.{ "pr", "merge", "12", "-R", "owner/repo", "--rebase", "--auto", "-d" });
    try h.expectErr("will be merged (rebase) once its checks succeed");
    v = try json(&h, h.mock.lastBody(.POST, pulls ++ "/12/merge").?);
    try std.testing.expectEqualStrings("rebase", v.object.get("Do").?.string);
    try std.testing.expect(v.object.get("merge_when_checks_succeed").?.bool);
    try std.testing.expect(v.object.get("delete_branch_after_merge").?.bool);

    try h.expectRun(0, &.{ "pr", "merge", "12", "-R", "owner/repo", "--auto" });
    try h.expectErr("Merged pull request #12");
    try h.expectRun(1, &.{ "pr", "merge", "12", "-R", "owner/repo", "--rebase", "--squash" });
    try h.expectErr("choose only one");
}

test "merge explains a 405 and refuses a merged pull request" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .path = pulls ++ "/14", .body = fx.pr_merged },
        .{ .method = .POST, .path = pulls ++ "/12/merge", .status = 405, .body = "{\"message\":\"Not all required status checks successful\"}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "pr", "merge", "12", "-R", "owner/repo", "--merge" });
    try h.expectErr("is not mergeable: Not all required status checks successful");
    try h.expectRun(1, &.{ "pr", "merge", "14", "-R", "owner/repo" });
    try h.expectErr("is already merged");
}

test "ready drops the WIP prefix and --undo puts it back" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/13", .body = fx.pr_fork },
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .method = .PATCH, .path = pulls ++ "/13", .status = 201, .body = fx.pr_fork },
        .{ .method = .PATCH, .path = pulls ++ "/12", .status = 201, .body = fx.pr_same },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "ready", "13", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("{\"title\":\"Fork change\"}", h.mock.lastBody(.PATCH, pulls ++ "/13").?);
    try h.expectRun(0, &.{ "pr", "ready", "12", "-R", "owner/repo", "--undo" });
    try std.testing.expectEqualStrings("{\"title\":\"WIP: Add feature\"}", h.mock.lastBody(.PATCH, pulls ++ "/12").?);
    try h.expectRun(0, &.{ "pr", "ready", "12", "-R", "owner/repo" });
    try h.expectErr("already ready for review");
}

test "close --delete-branch deletes a same-repository head" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .method = .PATCH, .path = pulls ++ "/12", .status = 201, .body = fx.pr_closed },
        .{ .method = .DELETE, .path = "/api/v1/repos/owner/repo/branches/feature", .status = 204 },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "close", "12", "-R", "owner/repo", "-d" });
    try h.expectErr("Closed pull request #12");
    try h.expectErr("Deleted branch feature");
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.DELETE, "/api/v1/repos/owner/repo/branches/feature"));
}

test "checks summarises statuses and exits 1 on failure, 8 while pending, 0 when green" {
    var h: Harness = undefined;
    const status = "/api/v1/repos/owner/repo/commits/abc123/status";
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .path = status, .body = fx.status_mixed, .times = 2 },
        .{ .path = status, .body = fx.status_pending, .times = 1 },
        .{ .path = status, .body = fx.status_green },
    }, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "pr", "checks", "12", "-R", "owner/repo" });
    const link = try std.fmt.allocPrint(h.arena.allocator(), "failure\tci / test\tFailing after 2m\t{s}/owner/repo/actions/runs/1/jobs/1\n", .{try h.base()});
    try std.testing.expect(std.mem.startsWith(u8, h.stdout(), "success\tci / build\t"));
    try h.expectOut(link);

    h.ctx.stdout_tty = true;
    try h.expectRun(1, &.{ "pr", "checks", "12", "-R", "owner/repo" });
    try h.expectOut("Some checks were not successful");
    try h.expectOut("1 failing, 1 successful, 0 skipped, and 1 pending checks");
    try h.expectRun(8, &.{ "pr", "checks", "12", "-R", "owner/repo" });
    try h.expectOut("Some checks are still pending");
    try h.expectRun(0, &.{ "pr", "checks", "12", "-R", "owner/repo" });
    try h.expectOut("All checks were successful");
}

test "checks --watch polls until nothing is pending" {
    var h: Harness = undefined;
    const status = "/api/v1/repos/owner/repo/commits/abc123/status";
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .path = status, .body = fx.status_pending, .times = 1 },
        .{ .path = status, .body = fx.status_green },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "checks", "12", "-R", "owner/repo", "--watch", "-i", "0" });
    try std.testing.expectEqual(@as(usize, 2), h.mock.count(.GET, status));
}

/// A bare repository standing in for the forge's git side: `main`, a
/// `feature` branch, and `refs/pull/13/head` for a fork's pull request.
fn forgeRepo(h: *Harness) !void {
    try h.git(&.{ "init", "-q", "-b", "main", "seed" });
    try h.git(&.{ "-C", "seed", "commit", "-q", "--allow-empty", "-m", "init" });
    try h.git(&.{ "-C", "seed", "switch", "-q", "-c", "feature" });
    try h.git(&.{ "-C", "seed", "commit", "-q", "--allow-empty", "-m", "feature work" });
    try h.git(&.{ "-C", "seed", "switch", "-q", "-c", "fork-work", "main" });
    try h.git(&.{ "-C", "seed", "commit", "-q", "--allow-empty", "-m", "fork work" });
    try h.git(&.{ "-C", "seed", "switch", "-q", "main" });
    try h.git(&.{ "clone", "-q", "--bare", "seed", "forge.git" });
    try h.git(&.{ "-C", "forge.git", "update-ref", "refs/pull/13/head", "refs/heads/fork-work" });
    try h.git(&.{ "-C", "forge.git", "update-ref", "-d", "refs/heads/fork-work" });

    const url = try std.fmt.allocPrint(h.arena.allocator(), "{s}/owner/repo.git", .{try h.base()});
    try h.git(&.{ "clone", "-q", try h.path("forge.git"), "work" });
    try h.git(&.{ "-C", "work", "remote", "set-url", "origin", url });
    const rewrite = try std.fmt.allocPrint(h.arena.allocator(), "url.{s}.insteadOf", .{try h.path("forge.git")});
    try h.git(&.{ "-C", "work", "config", rewrite, url });
    h.ctx.cwd = try h.path("work");
}

fn head(h: *Harness) ![]const u8 {
    const r = try std.process.run(h.arena.allocator(), std.testing.io, .{ .argv = &.{ "git", "-C", h.ctx.cwd.?, "log", "-1", "--format=%s" }, .environ_map = &h.env });
    return std.mem.trim(u8, r.stdout, "\n");
}

test "checkout of a same-repository branch tracks the remote branch" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls ++ "/12", .body = fx.pr_same }}, .{});
    defer h.deinit();
    try forgeRepo(&h);
    try h.expectRun(0, &.{ "pr", "checkout", "12" });
    try std.testing.expectEqualStrings("feature work", try head(&h));
    try h.git(&.{ "-C", "work", "rev-parse", "--abbrev-ref", "feature@{upstream}" });
    try h.expectRun(0, &.{ "pr", "checkout", "12" });
}

test "checkout of a fork's pull request fetches its pull ref" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls ++ "/13", .body = fx.pr_fork }}, .{});
    defer h.deinit();
    try forgeRepo(&h);
    try h.expectRun(0, &.{ "pr", "checkout", "13", "-b", "review-13" });
    try std.testing.expectEqualStrings("fork work", try head(&h));
    try h.expectRun(0, &.{ "pr", "checkout", "13", "-b", "review-13" });
}

test "create refuses a branch whose upstream is another branch, like origin/main" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "update-ref", "refs/remotes/origin/main", "HEAD" });
    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "feat", "--track", "origin/main" });
    try h.expectRun(1, &.{ "pr", "create", "-t", "x", "-b", "y", "--base", "dev" });
    try h.expectErr("run `git push -u origin feat` first");
    try std.testing.expectEqual(@as(usize, 0), h.mock.requests.items.len);
}

test "create off a terminal needs --title and --body, or --fill" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "pr", "create", "-R", "owner/repo", "-H", "feature", "-B", "main", "-t", "only a title" });
    try h.expectErr("--title and --body (or --fill) are required when not running interactively");
    try std.testing.expectEqual(@as(usize, 0), h.mock.requests.items.len);
}

/// A fork's pull request whose head branch is called `main`.
const pr_fork_main = blk: {
    const s: []const u8 = fx.pr_fork;
    const i = std.mem.indexOf(u8, s, "\"ref\":\"patch-1\"").?;
    break :blk s[0..i] ++ "\"ref\":\"main\"" ++ s[i + "\"ref\":\"patch-1\"".len ..];
};

test "checkout of a fork's main never touches our main" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls ++ "/13", .body = pr_fork_main }}, .{});
    defer h.deinit();
    try forgeRepo(&h);
    try h.expectRun(0, &.{ "pr", "checkout", "13" });
    try h.expectErr("a local branch named main already exists; using pr-13");
    try std.testing.expectEqualStrings("fork work", try head(&h));
    try h.git(&.{ "-C", "work", "switch", "-q", "main" });
    try std.testing.expectEqualStrings("init", try head(&h));
}

test "merge -d deletes the pull request's own branch and leaves a same-named stranger alone" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .path = pulls ++ "/13", .body = pr_fork_main },
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
        .{ .method = .POST, .path = pulls ++ "/12/merge", .body = "" },
        .{ .method = .POST, .path = pulls ++ "/13/merge", .body = "" },
    }, .{});
    defer h.deinit();
    try forgeRepo(&h);
    try h.expectRun(0, &.{ "pr", "checkout", "12" });
    try h.expectRun(0, &.{ "pr", "merge", "12", "-d" });
    try h.expectErr("Deleted local branch feature");
    try std.testing.expectEqualStrings("init", try head(&h));
    try std.testing.expectError(error.GitFailed, h.git(&.{ "-C", "work", "rev-parse", "--verify", "--quiet", "refs/heads/feature" }));

    try h.expectRun(0, &.{ "pr", "merge", "13", "-d" });
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "Deleted local branch") == null);
    try h.git(&.{ "-C", "work", "rev-parse", "--verify", "--quiet", "refs/heads/main" });
}

test "checkout again fast-forwards to new commits on the head" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls ++ "/12", .body = fx.pr_same }}, .{});
    defer h.deinit();
    try forgeRepo(&h);
    try h.expectRun(0, &.{ "pr", "checkout", "12" });
    try h.git(&.{ "-C", "seed", "switch", "-q", "feature" });
    try h.git(&.{ "-C", "seed", "commit", "-q", "--allow-empty", "-m", "more work" });
    try h.git(&.{ "-C", "seed", "push", "-q", try h.path("forge.git"), "feature" });
    try h.expectRun(0, &.{ "pr", "checkout", "12" });
    try std.testing.expectEqualStrings("more work", try head(&h));
}

test "a headless pull request is checked out as pr-N from its pull ref" {
    var h: Harness = undefined;
    const headless = comptime blk: {
        const s: []const u8 = fx.pr_same;
        const i = std.mem.indexOf(u8, s, "\"ref\":\"feature\"").?;
        break :blk s[0..i] ++ "\"ref\":\"refs/pull/13/head\"" ++ s[i + "\"ref\":\"feature\"".len ..];
    };
    const body = try std.mem.replaceOwned(u8, h_alloc(), headless, "\"number\":12", "\"number\":13");
    try h.init(&.{.{ .path = pulls ++ "/13", .body = body }}, .{});
    defer h.deinit();
    try forgeRepo(&h);
    try h.expectRun(0, &.{ "pr", "checkout", "13" });
    try std.testing.expectEqualStrings("fork work", try head(&h));
    try h.git(&.{ "-C", "work", "rev-parse", "--verify", "--quiet", "refs/heads/pr-13" });
}

fn h_alloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

test "lookup by branch wants this repository's branch; fix/42 is a branch, not #42" {
    var h: Harness = undefined;
    const slash = comptime blk: {
        const s: []const u8 = fx.pr_same;
        const i = std.mem.indexOf(u8, s, "\"ref\":\"feature\"").?;
        break :blk s[0..i] ++ "\"ref\":\"fix/42\"" ++ s[i + "\"ref\":\"feature\"".len ..];
    };
    try h.init(&.{
        .{ .path = pulls, .query = "state=open", .body = "[" ++ pr_fork_main ++ "," ++ slash ++ "]" },
        .{ .path = pulls, .query = "state=closed", .body = "[]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "view", "fix/42", "-R", "owner/repo" });
    try h.expectOut("Add feature #12");
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.GET, pulls ++ "/42"));
    try h.expectRun(1, &.{ "pr", "view", "main", "-R", "owner/repo" });
    try h.expectErr("no pull request found for branch \"main\" of owner");
    try h.expectRun(0, &.{ "pr", "view", "alice:main", "-R", "owner/repo" });
    try h.expectOut("WIP: Fork change #13");
    try std.testing.expect(std.mem.indexOf(u8, h.stderr(), "invalid number") == null);
}

test "list --head filters on the head branch, OWNER:BRANCH for a fork" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = pulls, .body = fx.pr_list_open }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "list", "-R", "owner/repo", "-H", "alice:patch-1" });
    try std.testing.expectEqualStrings("13\tWIP: Fork change\tpatch-1\tdraft\t2026-09-29T11:30:00Z\n", h.stdout());
    try h.expectRun(0, &.{ "pr", "list", "-R", "owner/repo", "--head", "feature" });
    try std.testing.expectEqualStrings("12\tAdd feature\tfeature\topen\t2026-09-29T11:30:00Z\n", h.stdout());
}

test "review approves, requests changes with a body, and refuses two verdicts" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .method = .POST, .path = pulls ++ "/12/reviews", .body = "{}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "review", "12", "-R", "owner/repo", "-a" });
    try h.expectErr("Approved pull request #12");
    try std.testing.expectEqualStrings("{\"event\":\"APPROVED\",\"body\":\"\",\"commit_id\":\"abc123\"}", h.mock.lastBody(.POST, pulls ++ "/12/reviews").?);
    try h.expectRun(1, &.{ "pr", "review", "12", "-R", "owner/repo", "-r" });
    try h.expectErr("need a body");
    try h.expectRun(0, &.{ "pr", "review", "12", "-R", "owner/repo", "-r", "-b", "Please rename" });
    try std.testing.expect(std.mem.indexOf(u8, h.mock.lastBody(.POST, pulls ++ "/12/reviews").?, "\"event\":\"REQUEST_CHANGES\",\"body\":\"Please rename\"") != null);
    try h.expectRun(1, &.{ "pr", "review", "12", "-R", "owner/repo", "-a", "-c" });
    try h.expectErr("choose one of");
}

test "update merges or rebases the base in and explains a conflict" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = pulls ++ "/12", .body = fx.pr_same },
        .{ .method = .POST, .path = pulls ++ "/12/update", .query = "style=merge", .body = "" },
        .{ .method = .POST, .path = pulls ++ "/12/update", .query = "style=rebase", .status = 409, .body = "{\"message\":\"merge conflict\"}" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "pr", "update-branch", "12", "-R", "owner/repo" });
    try h.expectErr("Updated pull request #12 (Add feature) with main (merge)");
    try h.expectRun(1, &.{ "pr", "update-branch", "12", "-R", "owner/repo", "--rebase" });
    try h.expectErr("cannot be updated automatically: merge conflict");
}

test "status lists the current branch's, yours, and those waiting for your review" {
    var h: Harness = undefined;
    const requested = comptime blk: {
        const s: []const u8 = fx.pr_fork;
        const i = std.mem.indexOf(u8, s, "\"labels\":[]").?;
        break :blk s[0..i] ++ "\"requested_reviewers\":[{\"login\":\"me\"}],\"labels\":[]" ++ s[i + "\"labels\":[]".len ..];
    };
    const mine = comptime blk: {
        const s: []const u8 = fx.pr_same;
        const i = std.mem.indexOf(u8, s, "\"login\":\"alice\"").?;
        break :blk s[0..i] ++ "\"login\":\"me\"" ++ s[i + "\"login\":\"alice\"".len ..];
    };
    try h.init(&.{
        .{ .path = pulls, .body = "[" ++ mine ++ "," ++ requested ++ "," ++ comptime fx.pull("16", "Fork feature", "feature", "5", "open", "false") ++ "]" },
        .{ .path = "/api/v1/repos/owner/repo/commits/abc123/status", .body = fx.status_mixed },
    }, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "switch", "-q", "-c", "feature" });
    try h.expectRun(0, &.{ "pr", "status" });
    const out = h.stdout();
    const current = std.mem.indexOf(u8, out, "Current branch").?;
    const created = std.mem.indexOf(u8, out, "Created by you").?;
    const review = std.mem.indexOf(u8, out, "Requesting a code review from you").?;
    try std.testing.expect(std.mem.indexOf(u8, out[current..created], "#12  Add feature [feature]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[current..created], "1/3 checks failing") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[created..review], "#12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[review..], "#13  WIP: Fork change") != null);
}
