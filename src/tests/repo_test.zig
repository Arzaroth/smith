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

test "sync reports a fork that is up to date or has diverged, and posts nothing" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const fork_json = try std.mem.replaceOwned(u8, h.arena.allocator(), fx.repo, "\"fork\":false", "\"fork\":true");
    try setRoutes(&h, &.{
        .{ .path = "/api/v1/repos/me/f", .body = fork_json },
        .{ .path = "/api/v1/repos/me/f/sync_fork", .body = "{\"allowed\":false,\"fork_commit\":\"aaa\",\"base_commit\":\"aaa\",\"commits_behind\":0}", .times = 1 },
        .{ .path = "/api/v1/repos/me/f/sync_fork", .body = "{\"allowed\":false,\"fork_commit\":\"aaa\",\"base_commit\":\"bbb\",\"commits_behind\":0}" },
    });
    try h.expectRun(0, &.{ "repo", "sync", "me/f" });
    try h.expectErr("already up to date");
    try h.expectRun(1, &.{ "repo", "sync", "me/f" });
    try h.expectErr("Forgejo cannot sync owner/repo main");
    try std.testing.expectEqual(@as(usize, 0), h.mock.count(.POST, "/api/v1/repos/me/f/sync_fork"));
}

test "list filters forks, sources, visibility and archived ones while it pages" {
    var h: Harness = undefined;
    const fork = comptime blk: {
        const s: []const u8 = fx.repo;
        const i = std.mem.indexOf(u8, s, "\"fork\":false").?;
        break :blk s[0..i] ++ "\"fork\":true" ++ s[i + "\"fork\":false".len ..];
    };
    try h.init(&.{.{ .path = "/api/v1/user/repos", .body = "[" ++ fx.repo ++ "," ++ fork ++ "]" }}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "repo", "list", "--fork" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.stdout(), "\n"));
    try h.expectOut("public, fork");
    try h.expectRun(0, &.{ "repo", "list", "--source" });
    try std.testing.expect(std.mem.indexOf(u8, h.stdout(), "fork") == null);
    try h.expectRun(0, &.{ "repo", "list", "--visibility", "private" });
    try h.expectErr("No repositories found");
    try h.expectRun(1, &.{ "repo", "list", "--fork", "--source" });
    try h.expectRun(1, &.{ "repo", "list", "--visibility", "secret" });
}

test "list filters archived ones, language, topics and internal, also for an organization" {
    var h: Harness = undefined;
    const archived = comptime blk: {
        const s: []const u8 = fx.repo;
        const i = std.mem.indexOf(u8, s, "\"archived\":false").?;
        break :blk s[0..i] ++ "\"archived\":true,\"internal\":true,\"language\":\"Zig\",\"topics\":[\"cli\",\"forge\"]" ++ s[i + "\"archived\":false".len ..];
    };
    try h.init(&.{
        .{ .path = "/api/v1/users/team/repos", .status = 404, .body = "{}" },
        .{ .path = "/api/v1/orgs/team/repos", .body = "[" ++ fx.repo ++ "," ++ archived ++ "]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "repo", "list", "team", "--archived" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.stdout(), "\n"));
    try h.expectOut("public, archived");
    try h.expectRun(0, &.{ "repo", "list", "team", "--no-archived" });
    try std.testing.expect(std.mem.indexOf(u8, h.stdout(), "archived") == null);
    try h.expectRun(0, &.{ "repo", "list", "team", "-l", "zig", "--topic", "CLI", "--visibility", "internal" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.stdout(), "\n"));
    try h.expectRun(0, &.{ "repo", "list", "team", "--topic", "cli", "--topic", "missing" });
    try h.expectErr("No repositories found");
    try h.expectRun(1, &.{ "repo", "list", "team", "--archived", "--no-archived" });
}

test "clone over ssh takes the ssh URL" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const cfg = try std.fmt.allocPrint(h.arena.allocator(), ".{{ .default_host = \"127.0.0.1:{d}\", .hosts = .{{ .{{ .name = \"127.0.0.1:{d}\", .scheme = \"http\", .git_protocol = .ssh, .user = \"me\", .token = \"t0ken\" }} }} }}\n", .{ h.mock.port, h.mock.port });
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/hosts.zon", .data = cfg });
    try h.git(&.{ "init", "-q", "--bare", "-b", "main", "origin.git" });
    const body = try std.fmt.allocPrint(h.arena.allocator(),
        \\{{"id":3,"name":"tool","full_name":"me/tool","html_url":"x","clone_url":"file:///nonexistent/tool.git","ssh_url":"{s}","fork":false}}
    , .{try h.path("origin.git")});
    try setRoutes(&h, &.{.{ .path = "/api/v1/repos/me/tool", .body = body }});
    try h.expectRun(0, &.{ "repo", "clone", "me/tool", "--", "-q" });
    const r = try std.process.run(h.arena.allocator(), std.testing.io, .{ .argv = &.{ "git", "-C", try h.path("tool"), "remote", "get-url", "origin" }, .environ_map = &h.env });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(h.arena.allocator(), "{s}\n", .{try h.path("origin.git")}), r.stdout);
}

test "view and list --json print the API objects" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo", .body = fx.repo },
        .{ .path = "/api/v1/user/repos", .body = "[" ++ fx.repo ++ "]" },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "repo", "view", "owner/repo", "--json" });
    const one = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqualStrings("owner/repo", one.object.get("full_name").?.string);
    try h.expectRun(0, &.{ "repo", "list", "--json" });
    const all = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.stdout(), .{});
    try std.testing.expectEqual(@as(usize, 1), all.array.items.len);
}

test "create asks for the name and visibility on a terminal and sets the homepage" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try setRoutes(&h, &.{
        .{ .method = .POST, .path = "/api/v1/user/repos", .status = 201, .body = try created(&h, "tool", "x") },
        .{ .method = .PATCH, .path = "/api/v1/repos/me/tool", .body = try created(&h, "tool", "x") },
    });
    h.ctx.stdin_tty = true;
    h.ctx.stdout_tty = true;
    h.ctx.stdin_data = "tool\npublic\n";
    try h.expectRun(0, &.{ "repo", "create", "--homepage", "https://tool.example" });
    try h.expectErr("Visibility (public/private):");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.mock.lastBody(.POST, "/api/v1/user/repos").?, .{});
    try std.testing.expectEqualStrings("tool", v.object.get("name").?.string);
    try std.testing.expect(!v.object.get("private").?.bool);
    try std.testing.expectEqualStrings("{\"website\":\"https://tool.example\"}", h.mock.lastBody(.PATCH, "/api/v1/repos/me/tool").?);
    h.ctx.stdin_data = "tool\nprivate\n";
    try h.expectRun(0, &.{ "repo", "create" });
    const w = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), h.mock.lastBody(.POST, "/api/v1/user/repos").?, .{});
    try std.testing.expect(w.object.get("private").?.bool);
}

test "fork --clone clones the fork and adds the parent as upstream" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.git(&.{ "init", "-q", "--bare", "-b", "main", "fork.git" });
    try h.git(&.{ "init", "-q", "--bare", "-b", "main", "parent.git" });
    const parent = try std.fmt.allocPrint(h.arena.allocator(),
        \\{{"id":1,"name":"repo","full_name":"owner/repo","html_url":"x","clone_url":"{s}"}}
    , .{try h.path("parent.git")});
    try setRoutes(&h, &.{
        .{ .method = .POST, .path = "/api/v1/repos/owner/repo/forks", .status = 202, .body = try created(&h, "repo", try h.path("fork.git")) },
        .{ .path = "/api/v1/repos/owner/repo", .body = parent },
    });
    try h.expectRun(0, &.{ "repo", "fork", "owner/repo", "--clone" });
    try h.expectErr("Created fork me/repo");
    try h.expectErr("Added remote upstream for owner/repo");
    const r = try std.process.run(h.arena.allocator(), std.testing.io, .{ .argv = &.{ "git", "-C", try h.path("repo"), "remote", "get-url", "upstream" }, .environ_map = &h.env });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(h.arena.allocator(), "{s}\n", .{try h.path("parent.git")}), r.stdout);
}

test "unarchive patches the repository back" {
    var h: Harness = undefined;
    try h.init(&.{.{ .method = .PATCH, .path = "/api/v1/repos/owner/repo", .body = fx.repo }}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "repo", "unarchive", "owner/repo" });
    try h.expectErr("Pass --yes");
    try h.expectRun(0, &.{ "repo", "unarchive", "owner/repo", "-y" });
    try std.testing.expectEqualStrings("{\"archived\":false}", h.mock.lastBody(.PATCH, "/api/v1/repos/owner/repo").?);
    try h.expectErr("Unarchived owner/repo");
}

test "set-default --view names a default remote that is gone, and ignores marks other than base" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "config", "remote.origin.smith-resolved", "other" });
    try h.expectRun(1, &.{ "repo", "set-default", "--view" });
    try h.expectErr("no default repository set");
    try h.git(&.{ "-C", "work", "config", "remote.gone.smith-resolved", "base" });
    try h.expectRun(1, &.{ "repo", "set-default", "--view" });
    try h.expectErr("the default remote gone no longer exists");
}

test "a command with no host configured says how to add one" {
    var h: Harness = undefined;
    try h.init(&.{}, .{ .config = false });
    defer h.deinit();
    try h.expectRun(1, &.{ "repo", "view", "-R", "owner/repo" });
    try h.expectErr("no Forgejo host configured");
}

test "the remote for a repository named with -R is found by its URL" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo/pulls/13", .body = fx.pr_fork },
        .{ .method = .PATCH, .path = "/api/v1/repos/owner/repo/pulls/13", .status = 201, .body = fx.pr_fork },
    }, .{});
    defer h.deinit();
    try h.clone("work", "owner", "repo");
    try h.git(&.{ "-C", "work", "remote", "add", "aaa", "https://elsewhere.test/owner/repo.git" });
    try h.git(&.{ "-C", "work", "commit", "-q", "--allow-empty", "-m", "start" });
    try h.git(&.{ "-C", "work", "branch", "pr-13" });
    try h.git(&.{ "-C", "work", "config", "branch.pr-13.smith-pr", "13" });
    try h.expectRun(0, &.{ "pr", "close", "13", "-R", "owner/repo", "--delete-branch" });
    try h.expectErr("Closed pull request #13");
    try h.expectErr("Deleted local branch pr-13");
}
