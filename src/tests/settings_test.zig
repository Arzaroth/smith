const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

test "config set, get, list and unset; unknown keys and values are refused" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "config", "set", "editor", "nano -w" });
    try h.expectRun(0, &.{ "config", "set", "git_protocol", "https" });
    try h.expectRun(0, &.{ "config", "get", "editor" });
    try std.testing.expectEqualStrings("nano -w\n", h.stdout());
    try h.expectRun(0, &.{ "config", "list" });
    try std.testing.expectEqualStrings("git_protocol=https\neditor=nano -w\nbrowser=\npager=\nprompt=enabled\n", h.stdout());
    try h.expectRun(1, &.{ "config", "set", "spinner", "off" });
    try h.expectErr("unknown key");
    try h.expectRun(1, &.{ "config", "set", "git_protocol", "ftp" });
    try h.expectRun(0, &.{ "config", "unset", "editor" });
    try h.expectRun(0, &.{ "config", "get", "editor" });
    try std.testing.expectEqualStrings("\n", h.stdout());
}

test "the browser preference is used for --web" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    _ = h.env.swapRemove("SMITH_BROWSER");
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "browser", .data = "#!/bin/sh\necho \"$1\" > \"$(dirname \"$0\")/opened\"\n", .flags = .{ .permissions = .fromMode(0o755) } });
    try h.expectRun(0, &.{ "config", "set", "browser", try h.path("browser") });
    try h.expectRun(0, &.{ "issue", "view", "7", "-R", "owner/repo", "--web" });
    var tries: usize = 0;
    const opened = while (true) : (tries += 1) {
        if (h.tmp.dir.readFileAlloc(std.testing.io, "opened", h.arena.allocator(), .limited(256))) |o| {
            if (o.len > 0) break o;
        } else |_| {}
        if (tries > 200) return error.BrowserNeverRan;
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    };
    try std.testing.expect(std.mem.endsWith(u8, opened, "/owner/repo/issues/7\n"));
}

test "aliases expand with placeholders, append the rest, and cannot shadow commands" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .path = "/api/v1/repos/owner/repo/issues", .query = "labels=bug", .body = fx.issue_list },
        .{ .path = "/api/v1/repos/owner/repo/pulls/12", .body = fx.pr_same },
    }, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "alias", "set", "bugs", "issue list --label $1" });
    try h.expectRun(0, &.{ "bugs", "bug", "-R", "owner/repo" });
    try h.expectOut("7\tCrash on start");
    try h.expectRun(0, &.{ "alias", "set", "pv", "pr view" });
    try h.expectRun(0, &.{ "pv", "12", "-R", "owner/repo" });
    try h.expectOut("Add feature #12");
    try h.expectRun(1, &.{ "alias", "set", "pr", "issue list" });
    try h.expectErr("is a smith command");
    try h.expectRun(1, &.{ "alias", "set", "x", "frobnicate now" });
    try h.expectErr("prefix the expansion with !");
    try h.expectRun(0, &.{ "alias", "list" });
    try std.testing.expectEqualStrings("bugs:\tissue list --label $1\npv:\tpr view\n", h.stdout());
    try h.expectRun(0, &.{ "alias", "delete", "pv" });
    try h.expectRun(1, &.{ "pv", "12" });
    try h.expectErr("unknown command \"pv\"");
}

test "a ! alias runs with sh and passes its arguments" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const target = try h.path("said");
    const script = try std.fmt.allocPrint(h.arena.allocator(), "!echo \"$1-$2\" > {s}; exit 3", .{target});
    try h.expectRun(0, &.{ "alias", "set", "say", script });
    try h.expectRun(3, &.{ "say", "a", "b" });
    try std.testing.expectEqualStrings("a-b\n", try h.tmp.dir.readFileAlloc(std.testing.io, "said", h.arena.allocator(), .limited(64)));
}

test "alias set refuses empty expansions and open quotes, and replaces only with --clobber" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(1, &.{ "alias", "set", "e", "" });
    try h.expectErr("the expansion of e is empty");
    try h.expectRun(1, &.{ "alias", "set", "e", "!" });
    try h.expectRun(1, &.{ "alias", "set", "q", "issue list --label 'bug" });
    try h.expectErr("unterminated quote");
    try h.expectRun(0, &.{ "alias", "set", "co", "pr checkout" });
    try h.expectRun(1, &.{ "alias", "set", "co", "pr view" });
    try h.expectErr("pass --clobber");
    try h.expectRun(0, &.{ "alias", "set", "co", "pr view", "--clobber" });
    try h.expectRun(0, &.{ "alias", "set", "hi", "echo hi", "--shell" });
    try h.expectRun(0, &.{ "alias", "list" });
    try std.testing.expectEqualStrings("co:\tpr view\nhi:\t!echo hi\n", h.stdout());
}

test "aliases with a missing argument, or broken in config.zon, fail without crashing" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "alias", "set", "rl", "release list -R $1" });
    try h.expectRun(1, &.{"rl"});
    try h.expectErr("not enough arguments for alias rl");
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/config.zon", .data = ".{ .aliases = .{ .{ .name = \"z\", .expansion = \"\" }, .{ .name = \"y\", .expansion = \"pr 'x\" } } }\n" });
    try h.expectRun(1, &.{"z"});
    try h.expectErr("alias z expands to nothing");
    try h.expectRun(1, &.{"y"});
    try h.expectErr("alias y has an unterminated quote");
}

test "a broken config.zon is ignored by other commands and named by the ones that edit it" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config/config.zon", .data = "{{\n" });
    try h.expectRun(0, &.{ "completion", "bash" });
    try h.expectErr("preferences and aliases are ignored");
    try h.expectRun(1, &.{ "config", "set", "editor", "vim" });
    try h.expectErr("fix or delete it");
}

test "config -h sets git_protocol for one logged-in host only" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const host = try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}", .{h.mock.port});
    try h.expectRun(0, &.{ "config", "get", "-h", host, "git_protocol" });
    try std.testing.expectEqualStrings("https\n", h.stdout());
    try h.expectRun(0, &.{ "config", "set", "-h", host, "git_protocol", "ssh" });
    try h.expectRun(0, &.{ "config", "list", "-h", host });
    try std.testing.expectEqualStrings("git_protocol=ssh\n", h.stdout());
    try h.expectRun(0, &.{ "config", "get", "git_protocol" });
    try std.testing.expectEqualStrings("ssh\n", h.stdout());
    try h.expectRun(1, &.{ "config", "set", "-h", host, "editor", "vim" });
    try h.expectErr("only git_protocol can be set per host");
    try h.expectRun(1, &.{ "config", "get", "-h", "elsewhere.example", "git_protocol" });
    try h.expectErr("not logged in to elsewhere.example");
    try h.expectRun(0, &.{ "config", "get", "--help" });
    try h.expectOut("-h, --host host");
}

test "prompt disabled makes a terminal behave like a script" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    h.ctx.stdin_tty = true;
    h.ctx.stdout_tty = true;
    try h.expectRun(1, &.{ "config", "set", "prompt", "off" });
    try h.expectErr("prompt must be enabled or disabled");
    try h.expectRun(0, &.{ "config", "set", "prompt", "disabled" });
    try h.expectRun(1, &.{ "issue", "create", "-R", "owner/repo", "-b", "x" });
    try h.expectErr("--title and --body are required when not running interactively");
    try h.expectRun(0, &.{ "config", "unset", "prompt" });
    try h.env.put("SMITH_PROMPT_DISABLED", "1");
    try h.expectRun(1, &.{ "repo", "delete", "owner/repo" });
    try h.expectErr("pass --yes");
}

test "lists go through the pager on a terminal" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo/issues", .body = fx.issue_list, .times = 2 }}, .{});
    defer h.deinit();
    const paged = try h.path("paged");
    try h.env.put("SMITH_PAGER", try std.fmt.allocPrint(h.arena.allocator(), "cat > '{s}'", .{paged}));
    h.ctx.stdout_tty = true;
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    try std.testing.expectEqualStrings("", h.stdout());
    const got = try h.tmp.dir.readFileAlloc(std.testing.io, "paged", h.arena.allocator(), .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, got, "Crash on start") != null);
    h.ctx.stdout_tty = false;
    try h.expectRun(0, &.{ "issue", "list", "-R", "owner/repo" });
    try h.expectOut("Crash on start");
}

test "alias import, set from standard input, and delete --all" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{ "alias", "set", "co", "pr checkout" });
    h.ctx.stdin_data = "# from gh\nco: pr view\nbugs: 'issue list --label bug'\n";
    try h.expectRun(1, &.{ "alias", "import", "-" });
    try h.expectErr("alias co already exists");
    h.ctx.stdin_data = "# from gh\nco: pr view\nbugs: 'issue list --label bug'\n";
    try h.expectRun(0, &.{ "alias", "import", "--clobber" });
    h.ctx.stdin_data = "nope: frobnicate\n";
    try h.expectRun(1, &.{ "alias", "import" });
    try h.expectErr("\"frobnicate\" is not a smith command");
    h.ctx.stdin_data = "co:\n  nested: x\n";
    try h.expectRun(1, &.{ "alias", "import" });
    try h.expectErr("is not a YAML map");
    h.ctx.stdin_data = "release list -L $1\n";
    try h.expectRun(0, &.{ "alias", "set", "rl", "-" });
    try h.expectRun(0, &.{ "alias", "list" });
    try std.testing.expectEqualStrings("co:\tpr view\nbugs:\tissue list --label bug\nrl:\trelease list -L $1\n", h.stdout());
    try h.expectRun(1, &.{ "alias", "delete" });
    try h.expectRun(0, &.{ "alias", "delete", "--all" });
    try h.expectErr("Deleted 3 aliases");
    try h.expectRun(0, &.{ "alias", "list" });
    try std.testing.expectEqualStrings("", h.stdout());
}
