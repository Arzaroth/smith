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
