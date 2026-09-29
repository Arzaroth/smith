const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const git = @import("../git.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");
const common = @import("common.zig");
const issue = @import("issue.zig");

const selector_usage = "[<number> | <url> | <branch>]";
const draft_prefix = "WIP: ";

pub const command: cli.Command = .{
    .name = "pr",
    .summary = "Work with pull requests.",
    .subs = &.{
        .{
            .name = "list",
            .summary = "List pull requests in a repository.",
            .flags = &.{
                .{ .long = "state", .short = 's', .value = "open|closed|merged|all", .help = "Filter by state (default open)" },
                .{ .long = "author", .short = 'A', .value = "login", .help = "Filter by author" },
                .{ .long = "label", .short = 'l', .value = "name", .help = "Filter by labels" },
                .{ .long = "base", .short = 'B', .value = "branch", .help = "Filter by base branch" },
                cli.limit_flag,
                cli.json_flag,
                cli.web_flag,
                cli.repo_flag,
            },
            .run = list,
        },
        .{
            .name = "view",
            .summary = "Show a pull request; without an argument, the one for the current branch.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{ .{ .long = "comments", .short = 'c', .help = "Show the comments" }, cli.json_flag, cli.web_flag, cli.repo_flag },
            .run = view,
        },
        .{
            .name = "diff",
            .summary = "Show the changes of a pull request.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{
                .{ .long = "patch", .help = "Show the commits as a patch series" },
                .{ .long = "name-only", .help = "Show only the names of changed files" },
                cli.repo_flag,
            },
            .run = diff,
        },
        .{
            .name = "create",
            .summary = "Open a pull request from the current branch.",
            .flags = &.{
                .{ .long = "title", .short = 't', .value = "string", .help = "Title" },
                common.body_flag,
                common.body_file_flag,
                .{ .long = "base", .short = 'B', .value = "branch", .help = "Branch to merge into (default: the repository's default branch)" },
                .{ .long = "head", .short = 'H', .value = "branch", .help = "Branch with the changes, OWNER:BRANCH for a fork (default: the current branch)" },
                .{ .long = "draft", .short = 'd', .help = "Mark as a draft (a \"WIP:\" title prefix)" },
                .{ .long = "fill", .short = 'f', .help = "Take the title and body from the commits" },
                .{ .long = "label", .short = 'l', .value = "name", .help = "Add labels by name" },
                .{ .long = "assignee", .short = 'a', .value = "login", .help = "Assign people by login" },
                .{ .long = "reviewer", .short = 'r', .value = "login", .help = "Request reviews by login" },
                cli.web_flag,
                cli.repo_flag,
            },
            .run = create,
        },
        .{
            .name = "checkout",
            .summary = "Check out a pull request's branch locally.",
            .usage = "<number> | <url>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{
                .{ .long = "branch", .short = 'b', .value = "string", .help = "Local branch name (default: the head branch's name)" },
                .{ .long = "force", .short = 'f', .help = "Reset the local branch to the pull request's head" },
                cli.repo_flag,
            },
            .run = checkout,
        },
        .{
            .name = "merge",
            .summary = "Merge a pull request.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{
                .{ .long = "merge", .short = 'm', .help = "Create a merge commit" },
                .{ .long = "squash", .short = 's', .help = "Squash the commits into one" },
                .{ .long = "rebase", .short = 'r', .help = "Rebase the commits onto the base branch" },
                .{ .long = "rebase-merge", .help = "Rebase, then create a merge commit" },
                .{ .long = "ff-only", .help = "Fast-forward only" },
                .{ .long = "delete-branch", .short = 'd', .help = "Delete the head branch, remotely and locally" },
                .{ .long = "auto", .help = "Merge once the checks succeed" },
                .{ .long = "subject", .short = 't', .value = "string", .help = "Subject of the merge commit" },
                common.body_flag,
                .{ .long = "admin", .help = "Merge even if the branch protection rules are not met" },
                cli.repo_flag,
            },
            .run = merge,
        },
        .{
            .name = "close",
            .summary = "Close a pull request without merging it.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{
                .{ .long = "comment", .short = 'c', .value = "string", .help = "Leave a comment when closing" },
                .{ .long = "delete-branch", .short = 'd', .help = "Delete the head branch" },
                cli.repo_flag,
            },
            .run = close,
        },
        .{
            .name = "reopen",
            .summary = "Reopen a closed pull request.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{ .{ .long = "comment", .short = 'c', .value = "string", .help = "Leave a comment when reopening" }, cli.repo_flag },
            .run = reopen,
        },
        .{
            .name = "comment",
            .summary = "Comment on a pull request.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{ common.body_flag, common.body_file_flag, cli.repo_flag },
            .run = commentCmd,
        },
        .{
            .name = "ready",
            .summary = "Mark a draft pull request as ready for review.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{ .{ .long = "undo", .help = "Turn it back into a draft" }, cli.repo_flag },
            .run = ready,
        },
        .{
            .name = "edit",
            .summary = "Edit a pull request's title, body, base, labels or assignees.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &(common.edit_flags ++ [_]cli.Flag{
                .{ .long = "base", .short = 'B', .value = "branch", .help = "Change the base branch" },
                cli.repo_flag,
            }),
            .run = edit,
        },
        .{
            .name = "checks",
            .summary = "Show the CI status of a pull request's head commit.",
            .usage = selector_usage,
            .max_args = 1,
            .flags = &.{
                .{ .long = "watch", .help = "Refresh until no check is pending" },
                .{ .long = "interval", .short = 'i', .value = "seconds", .help = "Refresh interval with --watch (default 10)" },
                cli.json_flag,
                cli.web_flag,
                cli.repo_flag,
            },
            .run = checks,
        },
    },
};

const Found = struct {
    pr: types.PullRequest,
    value: std.json.Value,
};

/// A pull request by number, URL or branch; the current branch's when `sel` is null.
fn find(ctx: *Ctx, client: *api.Client, r: repo.Repo, sel: ?[]const u8) !Found {
    const branch = if (sel) |s| blk: {
        if (common.number(ctx, s)) |n| {
            const v = try client.getValue(try r.path(ctx.alloc, "/pulls/{d}", .{n}));
            return .{ .pr = try api.decode(types.PullRequest, ctx, v), .value = v };
        } else |_| {}
        break :blk s;
    } else try git.currentBranch(ctx) orelse return ctx.fail("not on a branch; name the pull request", .{});

    const values = try client.listValues(try r.path(ctx.alloc, "/pulls?state=open&sort=recentupdate", .{}), 500, null);
    for (values) |v| {
        const pr = try api.decode(types.PullRequest, ctx, v);
        if (std.mem.eql(u8, pr.head.ref, branch)) return .{ .pr = pr, .value = v };
    }
    return ctx.fail("no open pull request found for branch \"{s}\"", .{branch});
}

fn displayState(pr: types.PullRequest) []const u8 {
    if (pr.merged) return "merged";
    if (std.mem.eql(u8, pr.state, "open") and (pr.draft or std.mem.startsWith(u8, pr.title, draft_prefix))) return "draft";
    return pr.state;
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    const state = args.get("state") orelse "open";
    if (!issue.isOneOf(state, &.{ "open", "closed", "merged", "all" })) return ctx.fail("--state must be open, closed, merged or all", .{});
    if (args.has("web")) {
        try ctx.openBrowser(try r.webUrl(ctx.alloc, "/pulls?state={s}", .{if (std.mem.eql(u8, state, "merged")) "closed" else state}));
        return 0;
    }
    var client = try r.client(ctx);
    var path = try common.query(ctx, try r.path(ctx.alloc, "/pulls", .{}), &.{
        .{ "state", if (std.mem.eql(u8, state, "merged")) "closed" else state },
        .{ "poster", args.get("author") },
        .{ "base", args.get("base") },
        .{ "sort", "recentupdate" },
    });
    for (try common.labelIds(ctx, &client, r, try args.all(ctx.alloc, "label"))) |id| {
        path = try std.fmt.allocPrint(ctx.alloc, "{s}&labels={d}", .{ path, id });
    }
    const limit = try args.int("limit", 30);
    const want_merged = std.mem.eql(u8, state, "merged");
    const fetched = try client.listValues(path, if (want_merged) limit * 4 else limit, null);

    var values: std.ArrayList(std.json.Value) = .empty;
    var prs: std.ArrayList(types.PullRequest) = .empty;
    for (fetched) |v| {
        const pr = try api.decode(types.PullRequest, ctx, v);
        if (want_merged and !pr.merged) continue;
        if (prs.items.len >= limit) break;
        try values.append(ctx.alloc, v);
        try prs.append(ctx.alloc, pr);
    }
    if (args.has("json")) {
        try api.printJson(ctx, values.items);
        return 0;
    }
    if (prs.items.len == 0) {
        try ctx.err.print("No pull requests match your search in {s}\n", .{try r.fullName(ctx.alloc)});
        return 0;
    }
    if (ctx.stdout_tty) try ctx.out.print("\nShowing {d} {s} pull requests in {s}\n\n", .{ prs.items.len, state, try r.fullName(ctx.alloc) });
    var table: term.Table = .{};
    for (prs.items) |pr| {
        const st = displayState(pr);
        try table.add(ctx.alloc, &.{
            .{ .text = try std.fmt.allocPrint(ctx.alloc, "#{d}", .{pr.number}), .color = if (std.mem.eql(u8, st, "draft")) .dim else common.stateColor(st) },
            .{ .text = if (ctx.stdout_tty) try term.truncate(ctx.alloc, pr.title, 70) else pr.title },
            .{ .text = pr.head.ref, .color = .cyan },
            .{ .text = if (ctx.stdout_tty) try term.ago(ctx.alloc, ctx.now, pr.updated_at) else st, .color = .dim },
        });
    }
    try table.write(ctx);
    return 0;
}

fn view(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    if (args.has("web") and args.arg(0) != null) {
        if (common.number(ctx, args.arg(0).?)) |n| {
            try ctx.openBrowser(try r.webUrl(ctx.alloc, "/pulls/{d}", .{n}));
            return 0;
        } else |_| {}
    }
    const f = try find(ctx, &client, r, args.arg(0));
    const pr = f.pr;
    if (args.has("web")) {
        try ctx.openBrowser(pr.html_url);
        return 0;
    }
    if (args.has("json")) {
        try api.printJson(ctx, f.value);
        return 0;
    }
    const w = ctx.out;
    const st = displayState(pr);
    try term.paint(ctx, w, .bold, pr.title);
    try w.print(" #{d}\n", .{pr.number});
    try term.paint(ctx, w, common.stateColor(st), try common.capitalized(ctx, st));
    try w.print(" · {s} wants to merge into {s} from {s}", .{
        if (pr.user) |u| u.login else "ghost",
        pr.base.ref,
        if (pr.head.repo) |hr| (if (pr.base.repo != null and !std.mem.eql(u8, hr.full_name, pr.base.repo.?.full_name))
            try std.fmt.allocPrint(ctx.alloc, "{s}:{s}", .{ if (hr.owner) |o| o.login else hr.full_name, pr.head.ref })
        else
            pr.head.ref) else pr.head.ref,
    });
    if (pr.additions) |a| try w.print(" · +{d} -{d}", .{ a, pr.deletions orelse 0 });
    if (pr.changed_files) |c| try w.print(" · {d} file{s}", .{ c, if (c == 1) "" else "s" });
    try w.writeByte('\n');
    const labels = try common.joinLabels(ctx, pr.labels);
    if (labels.len > 0) try w.print("Labels: {s}\n", .{labels});
    const assignees = try common.joinUsers(ctx, pr.assignees);
    if (assignees.len > 0) try w.print("Assignees: {s}\n", .{assignees});
    const reviewers = try common.joinUsers(ctx, pr.requested_reviewers);
    if (reviewers.len > 0) try w.print("Reviewers: {s}\n", .{reviewers});
    if (std.mem.eql(u8, pr.state, "open") and !pr.mergeable) try term.paint(ctx, w, .yellow, "This branch has conflicts with the base branch\n");
    try w.writeByte('\n');
    try common.writeBody(ctx, pr.body);
    if (args.has("comments")) try common.writeComments(ctx, &client, r, pr.number);
    try w.writeByte('\n');
    try term.paint(ctx, w, .dim, try std.fmt.allocPrint(ctx.alloc, "View this pull request on Forgejo: {s}", .{pr.html_url}));
    try w.writeByte('\n');
    return 0;
}

fn diff(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    if (args.has("name-only")) {
        const File = struct { filename: []const u8 };
        const files = try api.decodeAll(File, ctx, try client.listValues(try r.path(ctx.alloc, "/pulls/{d}/files", .{pr.number}), 10000, null));
        for (files) |f| try ctx.out.print("{s}\n", .{f.filename});
        return 0;
    }
    const kind = if (args.has("patch")) "patch" else "diff";
    const resp = try client.call(.GET, try r.path(ctx.alloc, "/pulls/{d}.{s}", .{ pr.number, kind }), .{ .accept = "text/plain" });
    if (!ctx.color) {
        try ctx.out.writeAll(resp.body);
        return 0;
    }
    var lines = std.mem.splitScalar(u8, resp.body, '\n');
    while (lines.next()) |line| {
        const color: term.Color = if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "diff "))
            .bold
        else if (std.mem.startsWith(u8, line, "@@"))
            .cyan
        else if (std.mem.startsWith(u8, line, "+"))
            .green
        else if (std.mem.startsWith(u8, line, "-"))
            .red
        else
            .none;
        try term.paint(ctx, ctx.out, color, line);
        if (lines.index != null) try ctx.out.writeByte('\n');
    }
    return 0;
}

/// The head to open a pull request from: `--head`, else the current branch,
/// prefixed with its owner when it is pushed to a fork.
fn headFor(ctx: *Ctx, args: *const cli.Args, r: repo.Repo) !struct { head: []const u8, branch: []const u8 } {
    if (args.get("head")) |h| {
        const branch = if (std.mem.indexOfScalar(u8, h, ':')) |i| h[i + 1 ..] else h;
        return .{ .head = h, .branch = branch };
    }
    const branch = try git.currentBranch(ctx) orelse return ctx.fail("not on a branch; pass --head", .{});
    const upstream = try git.capture(ctx, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }) orelse
        return ctx.fail("branch \"{s}\" is not pushed; run `git push -u origin {s}` first", .{ branch, branch });
    const slash = std.mem.indexOfScalar(u8, upstream, '/') orelse return .{ .head = branch, .branch = branch };
    const remote_name = upstream[0..slash];
    const remote_branch = upstream[slash + 1 ..];
    for (try git.remotes(ctx)) |rem| {
        if (!std.mem.eql(u8, rem.name, remote_name)) continue;
        const u = git.parseRemoteUrl(rem.url) orelse break;
        if (!std.ascii.eqlIgnoreCase(u.owner, r.owner))
            return .{ .head = try std.fmt.allocPrint(ctx.alloc, "{s}:{s}", .{ u.owner, remote_branch }), .branch = remote_branch };
    }
    return .{ .head = remote_branch, .branch = remote_branch };
}

const Fill = struct { title: []const u8, body: []const u8 };

/// Title and body from the commits between the base and HEAD: one commit's
/// subject and body, or the branch name and a list of subjects.
fn fillFromCommits(ctx: *Ctx, r: repo.Repo, base: []const u8, branch: []const u8) !Fill {
    const remote = r.remote orelse "origin";
    const range = try std.fmt.allocPrint(ctx.alloc, "{s}/{s}..HEAD", .{ remote, base });
    const shas = try git.capture(ctx, &.{ "log", "--reverse", "--format=%H", range }) orelse "";
    var it = std.mem.tokenizeScalar(u8, shas, '\n');
    var count: usize = 0;
    var first: []const u8 = "";
    while (it.next()) |s| : (count += 1) {
        if (count == 0) first = s;
    }
    if (count == 1) {
        const subject = try git.capture(ctx, &.{ "log", "-1", "--format=%s", first }) orelse branch;
        const body = try git.capture(ctx, &.{ "log", "-1", "--format=%b", first }) orelse "";
        return .{ .title = subject, .body = body };
    }
    const subjects = try git.capture(ctx, &.{ "log", "--reverse", "--format=- %s", range }) orelse "";
    const title = try ctx.alloc.dupe(u8, branch);
    for (title) |*c| if (c.* == '-' or c.* == '_' or c.* == '/') {
        c.* = ' ';
    };
    return .{ .title = try common.capitalized(ctx, title), .body = subjects };
}

fn create(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const h = try headFor(ctx, args, r);
    const base = args.get("base") orelse blk: {
        const info = try api.decode(types.Repository, ctx, try client.getValue(try r.path(ctx.alloc, "", .{})));
        break :blk info.default_branch orelse "main";
    };
    if (args.has("web")) {
        try ctx.openBrowser(try r.webUrl(ctx.alloc, "/compare/{s}...{s}", .{ base, h.head }));
        return 0;
    }

    const fill: ?Fill = if (args.has("fill") or args.get("title") == null)
        try fillFromCommits(ctx, r, base, h.branch)
    else
        null;
    var title = if (args.has("fill") and args.get("title") == null) fill.?.title else try common.title(ctx, args, if (fill) |f| f.title else null);
    const body = if (try common.bodyFromFlags(ctx, args)) |b|
        b
    else if (args.has("fill") or !ctx.interactive())
        (if (fill) |f| f.body else "")
    else
        std.mem.trim(u8, try ctx.editText("PULL_REQUEST.md", if (fill) |f| f.body else ""), " \r\n\t");
    if (args.has("draft") and !std.mem.startsWith(u8, title, draft_prefix))
        title = try std.fmt.allocPrint(ctx.alloc, draft_prefix ++ "{s}", .{title});

    const labels = try common.labelIds(ctx, &client, r, try args.all(ctx.alloc, "label"));
    const v = try client.sendValue(.POST, try r.path(ctx.alloc, "/pulls", .{}), .{
        .head = h.head,
        .base = base,
        .title = title,
        .body = body,
        .labels = labels,
        .assignees = try args.all(ctx.alloc, "assignee"),
    });
    const pr = try api.decode(types.PullRequest, ctx, v);
    const reviewers = try args.all(ctx.alloc, "reviewer");
    if (reviewers.len > 0)
        _ = try client.sendValue(.POST, try r.path(ctx.alloc, "/pulls/{d}/requested_reviewers", .{pr.number}), .{ .reviewers = reviewers });
    try ctx.out.print("{s}\n", .{pr.html_url});
    return 0;
}

fn baseRemote(ctx: *Ctx, r: repo.Repo) ![]const u8 {
    if (r.remote) |rem| return rem;
    return try repo.remoteFor(ctx, r.host, r.owner, r.name) orelse
        ctx.fail("no git remote points at {s}/{s}; add one to check out its pull requests", .{ r.owner, r.name });
}

fn localBranchExists(ctx: *Ctx, name: []const u8) !bool {
    const ref = try std.fmt.allocPrint(ctx.alloc, "refs/heads/{s}", .{name});
    return try git.capture(ctx, &.{ "rev-parse", "--verify", "--quiet", ref }) != null;
}

fn checkout(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    const remote = try baseRemote(ctx, r);
    const headless = std.mem.startsWith(u8, pr.head.ref, "refs/");
    const branch = args.get("branch") orelse if (headless) try std.fmt.allocPrint(ctx.alloc, "pr-{d}", .{pr.number}) else pr.head.ref;
    const force = args.has("force");
    const exists = try localBranchExists(ctx, branch);
    const current = try git.currentBranch(ctx);
    const on_branch = current != null and std.mem.eql(u8, current.?, branch);

    const same_repo = !headless and if (pr.head.repo) |hr| (if (pr.base.repo) |br| hr.id == br.id else true) else false;
    if (same_repo) {
        const tracking = try std.fmt.allocPrint(ctx.alloc, "{s}/{s}", .{ remote, pr.head.ref });
        try git.run(ctx, &.{ "fetch", remote, try std.fmt.allocPrint(ctx.alloc, "+refs/heads/{s}:refs/remotes/{s}", .{ pr.head.ref, tracking }) });
        if (!exists) {
            try git.run(ctx, &.{ "switch", "-c", branch, "--track", tracking });
        } else if (force) {
            try git.run(ctx, &.{ "switch", "-C", branch, "--track", tracking });
        } else {
            if (!on_branch) try git.run(ctx, &.{ "switch", branch });
            try git.run(ctx, &.{ "merge", "--ff-only", tracking });
        }
    } else {
        const pull_ref = try std.fmt.allocPrint(ctx.alloc, "refs/pull/{d}/head", .{pr.number});
        if (on_branch) {
            try git.run(ctx, &.{ "fetch", remote, pull_ref });
            try git.run(ctx, &.{ if (force) "reset" else "merge", if (force) "--hard" else "--ff-only", "FETCH_HEAD" });
        } else {
            const spec = try std.fmt.allocPrint(ctx.alloc, "{s}{s}:refs/heads/{s}", .{ if (force) "+" else "", pull_ref, branch });
            try git.run(ctx, &.{ "fetch", remote, spec });
            try git.run(ctx, &.{ "switch", branch });
        }
    }
    return 0;
}

fn merge(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    if (pr.merged) return ctx.fail("pull request #{d} ({s}) is already merged", .{ pr.number, pr.title });
    if (!std.mem.eql(u8, pr.state, "open")) return ctx.fail("pull request #{d} ({s}) is closed", .{ pr.number, pr.title });

    const methods = [_][2][]const u8{ .{ "merge", "merge" }, .{ "squash", "squash" }, .{ "rebase", "rebase" }, .{ "rebase-merge", "rebase-merge" }, .{ "ff-only", "fast-forward-only" } };
    var method: ?[]const u8 = null;
    for (methods) |m| if (args.has(m[0])) {
        if (method != null) return ctx.fail("choose only one of --merge, --squash, --rebase, --rebase-merge and --ff-only", .{});
        method = m[1];
    };
    if (method == null) {
        const info = try api.decode(types.Repository, ctx, try client.getValue(try r.path(ctx.alloc, "", .{})));
        method = info.default_merge_style orelse "merge";
    }

    const Payload = struct {
        Do: []const u8,
        MergeTitleField: ?[]const u8 = null,
        MergeMessageField: ?[]const u8 = null,
        delete_branch_after_merge: bool,
        merge_when_checks_succeed: bool,
        force_merge: bool,
    };
    const auto = args.has("auto");
    const delete = args.has("delete-branch");
    const resp = try client.raw(.POST, try r.path(ctx.alloc, "/pulls/{d}/merge", .{pr.number}), .{
        .body = try std.json.Stringify.valueAlloc(ctx.alloc, Payload{
            .Do = method.?,
            .MergeTitleField = args.get("subject"),
            .MergeMessageField = args.get("body"),
            .delete_branch_after_merge = delete,
            .merge_when_checks_succeed = auto,
            .force_merge = args.has("admin"),
        }, .{ .emit_null_optional_fields = false }),
    });
    if (!resp.ok()) {
        const msg = api.errorMessage(ctx.alloc, resp.body);
        return switch (resp.status) {
            405 => ctx.fail("pull request #{d} is not mergeable: {s}", .{ pr.number, msg orelse "checks, reviews or conflicts are in the way" }),
            409 => ctx.fail("pull request #{d} changed while merging: {s}", .{ pr.number, msg orelse "try again" }),
            else => client.failStatus(.POST, "/pulls/merge", resp),
        };
    }
    if (auto) {
        try ctx.err.print("✓ Pull request #{d} ({s}) will be merged ({s}) once its checks succeed\n", .{ pr.number, pr.title, method.? });
        return 0;
    }
    try ctx.err.print("✓ Merged pull request #{d} ({s}) with {s}\n", .{ pr.number, pr.title, method.? });
    if (delete) try deleteLocalBranch(ctx, pr);
    return 0;
}

/// After a merge with --delete-branch: move off the head branch and delete it.
fn deleteLocalBranch(ctx: *Ctx, pr: types.PullRequest) !void {
    if (try git.capture(ctx, &.{ "rev-parse", "--git-dir" }) == null) return;
    if (!try localBranchExists(ctx, pr.head.ref)) return;
    if (try git.currentBranch(ctx)) |cur| if (std.mem.eql(u8, cur, pr.head.ref)) {
        if (!try localBranchExists(ctx, pr.base.ref)) return;
        try git.run(ctx, &.{ "switch", pr.base.ref });
    };
    try git.run(ctx, &.{ "branch", "-D", "--", pr.head.ref });
    try ctx.err.print("✓ Deleted local branch {s}\n", .{pr.head.ref});
}

fn setState(ctx: *Ctx, args: *const cli.Args, state: []const u8, verb: []const u8) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    if (pr.merged) return ctx.fail("pull request #{d} ({s}) is merged", .{ pr.number, pr.title });
    if (std.mem.eql(u8, pr.state, state)) {
        try ctx.err.print("! Pull request #{d} ({s}) is already {s}\n", .{ pr.number, pr.title, state });
        return 0;
    }
    if (args.get("comment")) |c| _ = try common.comment(ctx, &client, r, pr.number, c);
    try client.sendNoContent(.PATCH, try r.path(ctx.alloc, "/pulls/{d}", .{pr.number}), .{ .state = state });
    try ctx.err.print("✓ {s} pull request #{d} ({s})\n", .{ verb, pr.number, pr.title });
    if (args.has("delete-branch")) {
        const same_repo = if (pr.head.repo) |hr| (if (pr.base.repo) |br| hr.id == br.id else false) else false;
        if (same_repo) {
            _ = try client.call(.DELETE, try r.path(ctx.alloc, "/branches/{s}", .{try api.escape(ctx.alloc, pr.head.ref)}), .{});
            try ctx.err.print("✓ Deleted branch {s}\n", .{pr.head.ref});
        }
        try deleteLocalBranch(ctx, pr);
    }
    return 0;
}

fn close(ctx: *Ctx, args: *const cli.Args) !u8 {
    return setState(ctx, args, "closed", "Closed");
}

fn reopen(ctx: *Ctx, args: *const cli.Args) !u8 {
    return setState(ctx, args, "open", "Reopened");
}

fn commentCmd(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    const body = try common.bodyOrEditor(ctx, args, "COMMENT.md", "");
    _ = try common.comment(ctx, &client, r, pr.number, body);
    try ctx.out.print("{s}\n", .{pr.html_url});
    return 0;
}

fn ready(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    const is_draft = std.mem.startsWith(u8, pr.title, draft_prefix);
    const undo = args.has("undo");
    if (undo == is_draft) {
        try ctx.err.print("! Pull request #{d} is already {s}\n", .{ pr.number, if (undo) "a draft" else "ready for review" });
        return 0;
    }
    const title = if (undo)
        try std.fmt.allocPrint(ctx.alloc, draft_prefix ++ "{s}", .{pr.title})
    else
        pr.title[draft_prefix.len..];
    try client.sendNoContent(.PATCH, try r.path(ctx.alloc, "/pulls/{d}", .{pr.number}), .{ .title = title });
    try ctx.err.print("✓ Pull request #{d} is {s}\n", .{ pr.number, if (undo) "a draft again" else "marked as ready for review" });
    return 0;
}

fn edit(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    const Patch = struct { title: ?[]const u8 = null, body: ?[]const u8 = null, base: ?[]const u8 = null };
    const patch: Patch = .{ .title = args.get("title"), .body = try common.bodyFromFlags(ctx, args), .base = args.get("base") };
    if (patch.title != null or patch.body != null or patch.base != null)
        try client.sendNoContent(.PATCH, try r.path(ctx.alloc, "/pulls/{d}", .{pr.number}), patch);
    try common.editLabelsAndAssignees(ctx, &client, r, args, pr.number, pr.assignees);
    try ctx.out.print("{s}\n", .{pr.html_url});
    return 0;
}

pub const Tally = struct {
    failing: usize = 0,
    passing: usize = 0,
    pending: usize = 0,
    skipped: usize = 0,

    pub fn of(statuses: []const types.CommitStatus) Tally {
        var t: Tally = .{};
        for (statuses) |s| switch (classify(s.status)) {
            .fail => t.failing += 1,
            .pass => t.passing += 1,
            .pending => t.pending += 1,
            .skip => t.skipped += 1,
        };
        return t;
    }
};

pub const Outcome = enum { pass, fail, pending, skip };

pub fn classify(status: []const u8) Outcome {
    if (std.mem.eql(u8, status, "success")) return .pass;
    if (std.mem.eql(u8, status, "failure") or std.mem.eql(u8, status, "error")) return .fail;
    if (std.mem.eql(u8, status, "skipped") or std.mem.eql(u8, status, "warning")) return .skip;
    return .pending;
}

pub fn outcomeCell(o: Outcome) term.Cell {
    return switch (o) {
        .pass => .{ .text = "✓", .color = .green },
        .fail => .{ .text = "X", .color = .red },
        .pending => .{ .text = "*", .color = .yellow },
        .skip => .{ .text = "-", .color = .dim },
    };
}

fn absoluteUrl(ctx: *Ctx, r: repo.Repo, url: ?[]const u8) ![]const u8 {
    const u = url orelse return "";
    if (std.mem.startsWith(u8, u, "/")) return std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ try r.host.webBase(ctx.alloc), u });
    return u;
}

fn checks(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const pr = (try find(ctx, &client, r, args.arg(0))).pr;
    if (args.has("web")) {
        try ctx.openBrowser(try std.fmt.allocPrint(ctx.alloc, "{s}/checks", .{pr.html_url}));
        return 0;
    }
    const interval = try args.int("interval", 10);
    const watch = args.has("watch");
    const path = try r.path(ctx.alloc, "/commits/{s}/status", .{pr.head.sha});
    var first = true;
    while (true) {
        const v = try client.getValue(path);
        if (args.has("json") and !watch) {
            try api.printJson(ctx, v);
            return 0;
        }
        const combined = try api.decode(types.CombinedStatus, ctx, v);
        const statuses = combined.statuses orelse &.{};
        if (statuses.len == 0) return ctx.fail("no checks reported on the \"{s}\" branch", .{pr.head.ref});
        const tally = Tally.of(statuses);

        if (watch and ctx.stdout_tty and !first) try ctx.out.writeAll("\x1b[H\x1b[2J");
        first = false;
        const summary = if (tally.failing > 0)
            "Some checks were not successful"
        else if (tally.pending > 0)
            "Some checks are still pending"
        else
            "All checks were successful";
        try term.paint(ctx, ctx.out, .bold, summary);
        try ctx.out.print("\n{d} failing, {d} successful, {d} skipped, and {d} pending checks\n\n", .{ tally.failing, tally.passing, tally.skipped, tally.pending });
        var table: term.Table = .{};
        for (statuses) |s| {
            const o = classify(s.status);
            try table.add(ctx.alloc, &.{
                if (ctx.stdout_tty) outcomeCell(o) else .{ .text = s.status },
                .{ .text = s.context },
                .{ .text = s.description orelse "", .color = .dim },
                .{ .text = try absoluteUrl(ctx, r, s.target_url), .color = .dim },
            });
        }
        try table.write(ctx);

        if (!watch or tally.pending == 0) {
            if (tally.failing > 0) return 1;
            if (tally.pending > 0) return 8;
            return 0;
        }
        try ctx.out.flush();
        try ctx.io.sleep(.fromSeconds(interval), .awake);
    }
}
