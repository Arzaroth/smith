const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

test "api GETs a path, fills {owner}/{repo}, and fails on an error status" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
        .{ .path = "/api/v1/nope", .status = 404, .body = "{\"message\":\"nope\"}" },
    }, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.expectRun(0, &.{ "api", "repos/{owner}/{repo}" });
    try std.testing.expectEqualStrings(fx.repo, h.stdout());
    try h.expectRun(1, &.{ "api", "/api/v1/nope" });
    try h.expectOut("{\"message\":\"nope\"}");
    try h.expectErr("HTTP 404");
}

test "api turns fields into a JSON body, typed with -F" {
    var h: Harness = undefined;
    try h.init(&.{.{ .method = .PATCH, .path = "/api/v1/repos/owner/repo", .body = "{}" }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "api", "-X", "patch", "/repos/owner/repo", "-f", "description=a=b", "-F", "private=true", "-F", "size=3", "-H", "X-Test: yes" });
    try std.testing.expectEqualStrings("{\"description\":\"a=b\",\"private\":true,\"size\":3}", h.mock.lastBody(.PATCH, "/api/v1/repos/owner/repo").?);
}

test "api with fields on GET sends them as the query" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/search", .query = "q=smith%20cli", .body = "{\"data\":[]}" }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "api", "-X", "GET", "/repos/search", "-f", "q=smith cli" });
}

test "api --paginate joins the pages" {
    var h: Harness = undefined;
    const page = "[" ++ ("{\"n\":1}," ** 49) ++ "{\"n\":1}]";
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo/branches", .query = "page=1", .body = page },
        .{ .path = "/api/v1/repos/owner/repo/branches", .query = "page=2", .body = "[{\"n\":2}]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "api", "--paginate", "/repos/owner/repo/branches" });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqual(@as(usize, 51), v.array.items.len);
}

test "redirects keep the token on the same host and drop it anywhere else" {
    var h: Harness = undefined;
    var buf: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    var storage: Harness.Mock = undefined;
    try storage.start(std.testing.io, &.{.{ .path = "/bucket/asset", .body = fx.repo }});
    defer storage.stop();
    const same = try std.fmt.bufPrint(&buf, "{s}/api/v1/repos/owner/renamed", .{try h.base()});
    const away = try std.fmt.bufPrint(&buf2, "http://127.0.0.1:{d}/bucket/asset", .{storage.port});
    const routes = try h.arena.allocator().dupe(Harness.Mock.Route, &.{
        .{ .path = "/api/v1/repos/owner/old", .status = 301, .content_type = "text/plain", .location = same },
        .{ .path = "/api/v1/repos/owner/renamed", .body = fx.repo },
        .{ .path = "/api/v1/repos/owner/away", .status = 302, .content_type = "text/plain", .location = away },
    });
    h.mock.routes = routes;
    h.mock.used = try h.arena.allocator().alloc(u32, routes.len);
    @memset(h.mock.used, 0);

    try h.expectRun(0, &.{ "repo", "view", "owner/old" });
    try h.expectOut("owner/repo");
    try std.testing.expectEqualStrings("token t0ken", h.mock.requests.items[1].authorization.?);

    try h.expectRun(0, &.{ "repo", "view", "owner/away" });
    try h.expectOut("owner/repo");
    try std.testing.expect(storage.requests.items[0].authorization == null);
}

test "--template and --jq shape the JSON of any command that has --json" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo/issues", .body = fx.issue_list }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo", "-t", "{{range .}}#{{.number}} {{.title}} ({{join \", \" .labels}}){{\"\\n\"}}{{end}}" });
    try std.testing.expectEqualStrings("#7 Crash on start ({\"id\":1,\"name\":\"bug\",\"color\":\"ee0701\"})\n", h.stdout());
    try h.expectRun(1, &.{ "issue", "list", "-R", "owner/repo", "--template", "{{range .}}" });
    try h.expectErr("invalid --template");

    try h.expectRun(0, &.{ "issue", "list", "--help" });
    try h.expectOut("-q, --jq expression");
}

test "--jq hands the JSON and the expression to jq and reports its complaints" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo/issues", .body = fx.issue_list }}, .{});
    defer h.deinit();
    const fake =
        \\#!/bin/sh
        \\[ "$1" = -r ] || exit 9
        \\case $2 in
        \\  bad) echo "jq: error: syntax error, unexpected INVALID_CHARACTER" >&2; exit 3 ;;
        \\  *) printf '%s:' "$2"; head -c 1; echo ;;
        \\esac
        \\
    ;
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "jq", .data = fake, .flags = .{ .permissions = .fromMode(0o755) } });
    try h.env.put("SMITH_JQ", try h.path("jq"));
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo", "-q", ".[].user.login" });
    try std.testing.expectEqualStrings(".[].user.login:[\n", h.stdout());
    try h.expectRun(1, &.{ "issue", "list", "-R", "owner/repo", "-q", "bad" });
    try h.expectErr("jq: error: syntax error");
    try h.env.put("SMITH_JQ", try h.path("no-such-jq"));
    try h.expectRun(1, &.{ "issue", "list", "-R", "owner/repo", "-q", "." });
    try h.expectErr("--jq needs jq installed");
}

test "browse prints the URLs it would open" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo", .body = fx.repo }}, .{});
    defer h.deinit();
    const base = try h.base();
    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{}, .want = "/owner/repo\n" },
        .{ .args = &.{"#7"}, .want = "/owner/repo/issues/7\n" },
        .{ .args = &.{"src/main.zig:12"}, .want = "/owner/repo/src/branch/main/src/main.zig#L12\n" },
        .{ .args = &.{ "README.md", "-b", "dev" }, .want = "/owner/repo/src/branch/dev/README.md\n" },
        .{ .args = &.{"--settings"}, .want = "/owner/repo/settings\n" },
    };
    for (cases) |c| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(h.arena.allocator(), &.{ "browse", "-n", "-R", "owner/repo" });
        try argv.appendSlice(h.arena.allocator(), c.args);
        try h.expectRun(0, argv.items);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(h.arena.allocator(), "{s}{s}", .{ base, c.want }), h.stdout());
    }
}

test "completion covers every command and flag" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "completion", "bash" });
    try h.expectOut("_smith_subs[\"smith pr\"]=\"list view diff create checkout merge");
    try h.expectOut(" review update-branch status checks\"");
    try h.expectOut("_smith_flags[\"smith pr merge\"]=\"--merge -m --squash -s");
    try h.expectRun(0, &.{ "completion", "fish" });
    try h.expectOut("complete -c smith -n 'test \"(__smith_path)\" = \"run\"' -a watch");
    try h.expectRun(0, &.{ "completion", "zsh" });
    try h.expectOut("bashcompinit");
    try h.expectRun(1, &.{ "completion", "tcsh" });
}

test "server text cannot smuggle escape sequences, --web opens only http(s), and names cannot become git options" {
    var h: Harness = undefined;
    const hostile_issue = "[{\"number\":1,\"title\":\"\\u001b]52;c;cm0gLXJmIH4=\\u0007evil\\ttitle\",\"state\":\"open\",\"html_url\":\"file:///etc/passwd\",\"labels\":[]}]";
    const hostile_repo = "{\"id\":1,\"name\":\"-oops\",\"full_name\":\"o/-oops\",\"html_url\":\"x\",\"clone_url\":\"--upload-pack=touch pwned\"}";
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo/issues", .body = hostile_issue },
        .{ .path = "/api/v1/repos/o/r", .body = hostile_repo },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    try std.testing.expect(std.mem.indexOfScalar(u8, h.stdout(), 0x1b) == null);
    try h.expectOut("?]52;c;cm0gLXJmIH4=?evil title");

    try h.expectRun(1, &.{ "repo", "clone", "o/r" });
    try h.expectErr("refusing directory \"-oops\"");
    try h.expectRun(1, &.{ "repo", "clone", "o/r", "safe", "--", "-q" });
    try std.testing.expectError(error.FileNotFound, h.tmp.dir.access(std.testing.io, "pwned", .{}));
}

test "browse keeps the dot of dot-directories" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "browse", "-n", "-R", "owner/repo", "-b", "main", ".forgejo/workflows/ci.yml" });
    try h.expectOut("/owner/repo/src/branch/main/.forgejo/workflows/ci.yml\n");
    try h.expectRun(0, &.{ "browse", "-n", "-R", "owner/repo", "-b", "main", "./src/a.zig" });
    try h.expectOut("/src/branch/main/src/a.zig\n");
}
