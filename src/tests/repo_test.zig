const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

fn repoJson(h: *Harness, name: []const u8, clone_url: []const u8, parent: ?[]const u8) ![]const u8 {
    return std.fmt.allocPrint(h.arena.allocator(),
        \\{{"id":3,"name":"{s}","full_name":"me/{s}","html_url":"x","clone_url":"{s}","ssh_url":"git@x:me/{s}.git","fork":{s}{s}}}
    , .{ name, name, clone_url, name, if (parent != null) "true" else "false", if (parent) |p| try std.fmt.allocPrint(h.arena.allocator(), ",\"parent\":{s}", .{p}) else "" });
}

test "clone uses the https URL, names the directory after the repo, and adds upstream for a fork" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.git(&.{ "init", "-q", "--bare", "-b", "main", "origin.git" });
    try h.git(&.{ "init", "-q", "--bare", "-b", "main", "parent.git" });
    const parent = try std.fmt.allocPrint(h.arena.allocator(),
        \\{{"id":2,"name":"tool","full_name":"up/tool","html_url":"x","clone_url":"{s}","ssh_url":"git@x:up/tool.git"}}
    , .{try h.path("parent.git")});
    const body = try repoJson(&h, "tool", try h.path("origin.git"), parent);
    h.mock.routes = &.{.{ .path = "/api/v1/repos/me/tool", .body = body }};
    h.mock.used = try h.arena.allocator().alloc(u32, 1);
    h.mock.used[0] = 0;
    h.ctx.cwd = h.root;

    try h.expectRun(0, &.{ "repo", "clone", "tool", "--", "-q" });
    try h.expectErr("Added remote upstream for up/tool");
    try h.git(&.{ "-C", "tool", "remote", "get-url", "upstream" });
    var dir = try h.tmp.dir.openDir(std.testing.io, "tool/.git", .{});
    dir.close(std.testing.io);
}

test "clone of a bare name needs a known user" {
    var h: Harness = undefined;
    try h.init(&.{}, .{ .user = "" });
    defer h.deinit();
    const cfg = try std.fmt.allocPrint(h.arena.allocator(), ".{{ .hosts = .{{ .{{ .name = \"127.0.0.1:{d}\", .scheme = \"http\" }} }} }}\n", .{h.mock.port});
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/hosts.zon", .data = cfg });
    try h.expectRun(1, &.{ "repo", "clone", "tool" });
    try h.expectErr("use OWNER/REPO");
}

test "view shows the details; --web opens the page" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo", .body = fx.repo }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "repo", "view", "owner/repo" });
    try h.expectOut("A test repository");
    try h.expectOut("public · 3 stars · 1 forks · 2 open issues · 1 open pull requests");
    try h.expectOut("Default branch: main");
    try h.expectRun(0, &.{ "repo", "view", "owner/repo", "--web" });
    try std.testing.expectEqual(@as(usize, 1), h.mock.requests.items.len);
}

test "list falls back to the organization endpoint" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/users/team/repos", .status = 404, .body = "{}" },
        .{ .path = "/api/v1/orgs/team/repos", .body = "[" ++ fx.repo ++ "]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "repo", "list", "team" });
    try h.expectOut("owner/repo\tA test repository\tpublic\t2026-09-29T11:00:00Z");
}

test "the ssh host maps an ssh remote back to its web host" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo", .body = fx.repo }}, .{});
    defer h.deinit();
    const cfg = try std.fmt.allocPrint(h.arena.allocator(), ".{{ .hosts = .{{ .{{ .name = \"127.0.0.1:{d}\", .scheme = \"http\", .ssh_host = \"ssh.forge.test\" }} }} }}\n", .{h.mock.port});
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/hosts.zon", .data = cfg });
    try h.git(&.{ "init", "-q", "work" });
    try h.git(&.{ "-C", "work", "remote", "add", "origin", "ssh://git@ssh.forge.test:2222/owner/repo.git" });
    h.ctx.cwd = try h.path("work");
    try h.expectRun(0, &.{ "repo", "view" });
    try h.expectOut("owner/repo");
}

test "upstream wins over origin, and an unknown ssh host is refused" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo", .body = fx.repo }}, .{});
    defer h.deinit();
    try h.clone("work", "me", "repo");
    const up = try std.fmt.allocPrint(h.arena.allocator(), "{s}/owner/repo.git", .{try h.base()});
    try h.git(&.{ "-C", "work", "remote", "add", "upstream", up });
    try h.expectRun(0, &.{ "repo", "view" });
    try std.testing.expectEqualStrings("/api/v1/repos/owner/repo", h.mock.requests.items[0].target);

    try h.git(&.{ "init", "-q", "other" });
    try h.git(&.{ "-C", "other", "remote", "add", "origin", "git@elsewhere.test:o/r.git" });
    h.ctx.cwd = try h.path("other");
    try h.expectRun(1, &.{ "repo", "view" });
    try h.expectErr("no git remote points at a Forgejo host (checked: elsewhere.test (SSH host not configured))");
}

test "clone HOST:OWNER/REPO picks the host by its SSH name, HOST/OWNER/REPO by its web name" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.git(&.{ "init", "-q", "--bare", "-b", "main", "origin.git" });
    const body = try repoJson(&h, "tool", try h.path("origin.git"), null);
    const routes = try h.arena.allocator().dupe(Harness.Mock.Route, &.{.{ .path = "/api/v1/repos/team/tool", .body = body }});
    h.mock.routes = routes;
    h.mock.used = try h.arena.allocator().alloc(u32, 1);
    h.mock.used[0] = 0;
    const cfg = try std.fmt.allocPrint(h.arena.allocator(), ".{{ .hosts = .{{ .{{ .name = \"127.0.0.1:{d}\", .scheme = \"http\", .git_protocol = .https, .ssh_host = \"ssh.forge.test\" }} }} }}\n", .{h.mock.port});
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/hosts.zon", .data = cfg });
    h.ctx.cwd = h.root;

    try h.expectRun(0, &.{ "repo", "clone", "ssh.forge.test:team/tool", "a", "--", "-q" });
    const web = try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}/team/tool", .{h.mock.port});
    try h.expectRun(0, &.{ "repo", "clone", web, "b", "--", "-q" });
    try std.testing.expectEqual(@as(usize, 2), h.mock.count(.GET, "/api/v1/repos/team/tool"));
    try h.git(&.{ "-C", "a", "rev-parse", "--git-dir" });
    try h.git(&.{ "-C", "b", "rev-parse", "--git-dir" });
}

fn created(h: *Harness, name: []const u8, clone_url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(h.arena.allocator(),
        \\{{"id":5,"name":"{s}","full_name":"me/{s}","owner":{{"login":"me"}},"html_url":"http://forge.test/me/{s}","clone_url":"{s}","ssh_url":"git@x:me/{s}.git"}}
    , .{ name, name, name, clone_url, name });
}

fn setRoutes(h: *Harness, routes: []const Harness.Mock.Route) !void {
    h.mock.routes = try h.arena.allocator().dupe(Harness.Mock.Route, routes);
    h.mock.used = try h.arena.allocator().alloc(u32, routes.len);
    @memset(h.mock.used, 0);
}

test "create needs a visibility off a terminal and sends the options" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{
        .{ .method = .POST, .path = "/api/v1/user/repos", .status = 201, .body = try created(&h, "tool", "x") },
        .{ .method = .POST, .path = "/api/v1/orgs/team/repos", .status = 201, .body = try created(&h, "tool", "x") },
    });
    try h.expectRun(1, &.{ "repo", "create", "tool" });
    try h.expectErr("choose --public or --private");
    try h.expectRun(0, &.{ "repo", "create", "tool", "--private", "-d", "A tool", "--license", "MIT" });
    try h.expectOut("http://forge.test/me/tool\n");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.mock.lastBody(.POST, "/api/v1/user/repos").?, .{});
    try std.testing.expect(v.object.get("private").?.bool);
    try std.testing.expect(v.object.get("auto_init").?.bool);
    try std.testing.expectEqualStrings("MIT", v.object.get("license").?.string);
    try h.expectRun(0, &.{ "repo", "create", "team/tool", "--public" });
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.POST, "/api/v1/orgs/team/repos"));
}

test "create --source adds the remote and pushes" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.git(&.{ "init", "-q", "--bare", "-b", "main", "remote.git" });
    try setRoutes(&h, &.{.{ .method = .POST, .path = "/api/v1/user/repos", .status = 201, .body = try created(&h, "proj", try h.path("remote.git")) }});
    try h.git(&.{ "init", "-q", "-b", "main", "proj" });
    try h.git(&.{ "-C", "proj", "commit", "-q", "--allow-empty", "-m", "first" });
    try h.expectRun(0, &.{ "repo", "create", "--source", try h.path("proj"), "--public", "--push" });
    try h.git(&.{ "-C", "remote.git", "rev-parse", "--verify", "refs/heads/main" });
    try h.expectErr("Added remote origin");
}

test "fork --remote renames origin to upstream and adds the fork as origin" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{.{ .method = .POST, .path = "/api/v1/repos/owner/repo/forks", .status = 202, .body = try created(&h, "repo", "https://forge.test/me/repo.git") }});
    try h.clone("work", "owner", "repo");
    try h.expectRun(0, &.{ "repo", "fork", "--remote", "--org", "team" });
    try std.testing.expectEqualStrings("{\"organization\":\"team\"}", h.mock.lastBody(.POST, "/api/v1/repos/owner/repo/forks").?);
    try h.git(&.{ "-C", "work", "remote", "get-url", "upstream" });
    try h.expectErr("Renamed remote origin to upstream");
    const r = try std.process.run(h.arena.allocator(), std.testing.io, .{ .argv = &.{ "git", "-C", try h.path("work"), "remote", "get-url", "origin" }, .environ_map = &h.env });
    try std.testing.expectEqualStrings("https://forge.test/me/repo.git\n", r.stdout);
}

test "edit sends only what changed; toggles cannot contradict" {
    var h: Harness = undefined;
    try h.init(&.{.{ .method = .PATCH, .path = "/api/v1/repos/owner/repo", .body = fx.repo }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "repo", "edit", "owner/repo", "--disable-wiki", "--enable-issues", "--visibility", "private", "-d", "New" });
    try std.testing.expectEqualStrings("{\"description\":\"New\",\"private\":true,\"has_issues\":true,\"has_wiki\":false}", h.mock.lastBody(.PATCH, "/api/v1/repos/owner/repo").?);
    try h.expectRun(1, &.{ "repo", "edit", "owner/repo", "--disable-wiki", "--enable-wiki" });
    try h.expectRun(1, &.{ "repo", "edit", "owner/repo" });
    try h.expectErr("nothing to change");
}

test "sync picks sync_fork for a fork and mirror-sync for a mirror" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const fork_json = try std.mem.replaceOwned(u8, h.arena.allocator(), fx.repo, "\"fork\":false", "\"fork\":true");
    const mirror_json = try std.mem.replaceOwned(u8, h.arena.allocator(), fx.repo, "\"fork\":false", "\"mirror\":true");
    try setRoutes(&h, &.{
        .{ .path = "/api/v1/repos/me/f", .body = fork_json },
        .{ .path = "/api/v1/repos/me/f/sync_fork/dev", .body = "{\"allowed\":true,\"commits_behind\":2}" },
        .{ .method = .POST, .path = "/api/v1/repos/me/f/sync_fork/dev", .body = "" },
        .{ .path = "/api/v1/repos/me/m", .body = mirror_json },
        .{ .method = .POST, .path = "/api/v1/repos/me/m/mirror-sync", .body = "" },
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
    });
    try h.expectRun(0, &.{ "repo", "sync", "me/f", "-b", "dev" });
    try h.expectRun(0, &.{ "repo", "sync", "me/m" });
    try h.expectErr("pull from its source");
    try h.expectRun(1, &.{ "repo", "sync", "owner/repo" });
    try h.expectErr("neither a fork nor a mirror");
}

test "archive and delete ask first; delete off a terminal needs --yes" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .method = .PATCH, .path = "/api/v1/repos/owner/repo", .body = fx.repo },
        .{ .method = .DELETE, .path = "/api/v1/repos/owner/repo", .status = 204 },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "repo", "archive", "owner/repo", "-y" });
    try std.testing.expectEqualStrings("{\"archived\":true}", h.mock.lastBody(.PATCH, "/api/v1/repos/owner/repo").?);
    try h.expectRun(1, &.{ "repo", "delete", "owner/repo" });
    try h.expectErr("pass --yes");
    h.ctx.stdin_tty = true;
    h.ctx.stdout_tty = true;
    h.ctx.stdin_data = "owner/wrong\n";
    try h.expectRun(1, &.{ "repo", "delete", "owner/repo" });
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.DELETE, "/api/v1/repos/owner/repo"));
    h.ctx.stdin_data = "owner/repo\n";
    try h.expectRun(0, &.{ "repo", "delete", "owner/repo" });
    try std.testing.expectEqual(@as(usize, 1), h.mock.count(.DELETE, "/api/v1/repos/owner/repo"));
}

test "set-default makes resolution prefer a remote over upstream" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/me/repo", .body = fx.repo },
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
    }, .{});
    defer h.deinit();
    try h.clone("work", "me", "repo");
    const up = try std.fmt.allocPrint(h.arena.allocator(), "{s}/owner/repo.git", .{try h.base()});
    try h.git(&.{ "-C", "work", "remote", "add", "upstream", up });
    try h.expectRun(0, &.{ "repo", "view" });
    try std.testing.expectEqualStrings("/api/v1/repos/owner/repo", h.mock.requests.items[0].target);

    try h.expectRun(0, &.{ "repo", "set-default", "me/repo" });
    try h.expectRun(0, &.{ "repo", "set-default", "--view" });
    try std.testing.expectEqualStrings("me/repo\n", h.stdout());
    try h.expectRun(0, &.{ "repo", "view" });
    try std.testing.expectEqualStrings("/api/v1/repos/me/repo", h.mock.requests.items[1].target);
    try h.expectRun(0, &.{ "repo", "set-default", "--unset" });
    try h.expectRun(1, &.{ "repo", "set-default", "nobody/else" });
}
