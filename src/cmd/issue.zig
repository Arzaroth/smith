const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");
const common = @import("common.zig");

const number_usage = "<number>";

pub const command: cli.Command = .{
    .name = "issue",
    .summary = "Work with issues.",
    .subs = &.{
        .{
            .name = "list",
            .summary = "List issues in a repository.",
            .flags = &.{
                .{ .long = "state", .short = 's', .value = "open|closed|all", .help = "Filter by state (default open)" },
                .{ .long = "label", .short = 'l', .value = "name", .help = "Filter by labels" },
                .{ .long = "assignee", .short = 'a', .value = "login", .help = "Filter by assignee" },
                .{ .long = "author", .short = 'A', .value = "login", .help = "Filter by author" },
                .{ .long = "mention", .value = "login", .help = "Filter by mention" },
                .{ .long = "search", .short = 'S', .value = "query", .help = "Search the title and body" },
                cli.limit_flag,
                cli.json_flag,
                cli.web_flag,
                cli.repo_flag,
            },
            .run = list,
        },
        .{
            .name = "view",
            .summary = "Show an issue.",
            .usage = number_usage,
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ .{ .long = "comments", .short = 'c', .help = "Show the comments" }, cli.json_flag, cli.web_flag, cli.repo_flag },
            .run = view,
        },
        .{
            .name = "create",
            .summary = "Create an issue.",
            .flags = &.{
                .{ .long = "title", .short = 't', .value = "string", .help = "Title" },
                common.body_flag,
                common.body_file_flag,
                .{ .long = "label", .short = 'l', .value = "name", .help = "Add labels by name" },
                .{ .long = "assignee", .short = 'a', .value = "login", .help = "Assign people by login" },
                cli.web_flag,
                cli.repo_flag,
            },
            .run = create,
        },
        .{
            .name = "close",
            .summary = "Close an issue.",
            .usage = number_usage,
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ .{ .long = "comment", .short = 'c', .value = "string", .help = "Leave a comment when closing" }, cli.repo_flag },
            .run = close,
        },
        .{
            .name = "reopen",
            .summary = "Reopen an issue.",
            .usage = number_usage,
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ .{ .long = "comment", .short = 'c', .value = "string", .help = "Leave a comment when reopening" }, cli.repo_flag },
            .run = reopen,
        },
        .{
            .name = "comment",
            .summary = "Comment on an issue.",
            .usage = number_usage,
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ common.body_flag, common.body_file_flag, cli.repo_flag },
            .run = commentCmd,
        },
        .{
            .name = "edit",
            .summary = "Edit an issue's title, body, labels or assignees.",
            .usage = number_usage,
            .min_args = 1,
            .max_args = 1,
            .flags = &(common.edit_flags ++ [_]cli.Flag{cli.repo_flag}),
            .run = edit,
        },
    },
};

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    const state = args.get("state") orelse "open";
    if (!isOneOf(state, &.{ "open", "closed", "all" })) return ctx.fail("--state must be open, closed or all", .{});
    if (args.has("web")) {
        try ctx.openBrowser(try r.webUrl(ctx.alloc, "/issues?state={s}", .{state}));
        return 0;
    }
    const labels = try args.all(ctx.alloc, "label");
    const path = try common.query(ctx, try r.path(ctx.alloc, "/issues?type=issues", .{}), &.{
        .{ "state", state },
        .{ "labels", if (labels.len > 0) try std.mem.join(ctx.alloc, ",", labels) else null },
        .{ "q", args.get("search") },
        .{ "created_by", args.get("author") },
        .{ "assigned_by", args.get("assignee") },
        .{ "mentioned_by", args.get("mention") },
    });
    var client = try r.client(ctx);
    const values = try client.listValues(path, try args.int("limit", 30), null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const issues = try api.decodeAll(types.Issue, ctx, values);
    if (issues.len == 0) {
        try ctx.err.print("No issues match your search in {s}\n", .{try r.fullName(ctx.alloc)});
        return 0;
    }
    if (ctx.stdout_tty) try ctx.out.print("\nShowing {d} {s} issues in {s}\n\n", .{ issues.len, state, try r.fullName(ctx.alloc) });
    var table: term.Table = .{};
    for (issues) |i| {
        try table.add(ctx.alloc, &.{
            .{ .text = try term.num(ctx, i.number), .color = common.stateColor(i.state) },
            .{ .text = try term.fit(ctx, i.title, 70) },
            .{ .text = try common.joinLabels(ctx, i.labels), .color = .dim },
            .{ .text = i.state, .pipe = true },
            .{ .text = try term.when(ctx, i.updated_at), .color = .dim },
        });
    }
    try table.write(ctx);
    return 0;
}

fn view(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    const n = try common.number(ctx, args.arg(0).?);
    if (args.has("web")) {
        try ctx.openBrowser(try r.webUrl(ctx.alloc, "/issues/{d}", .{n}));
        return 0;
    }
    var client = try r.client(ctx);
    const v = try client.getValue(try r.path(ctx.alloc, "/issues/{d}", .{n}));
    if (args.has("json")) {
        try api.printJson(ctx, v);
        return 0;
    }
    const i = try api.decode(types.Issue, ctx, v);
    const w = ctx.out;
    try term.paint(ctx, w, .bold, i.title);
    try w.print(" #{d}\n", .{i.number});
    try term.paint(ctx, w, common.stateColor(i.state), try common.capitalized(ctx, i.state));
    try w.print(" · {s} opened {s} · {d} comment{s}\n", .{
        if (i.user) |u| u.login else "ghost",
        try term.ago(ctx.alloc, ctx.now, i.created_at),
        i.comments,
        if (i.comments == 1) "" else "s",
    });
    const labels = try common.joinLabels(ctx, i.labels);
    if (labels.len > 0) try w.print("Labels: {s}\n", .{labels});
    const assignees = try common.joinUsers(ctx, i.assignees);
    if (assignees.len > 0) try w.print("Assignees: {s}\n", .{assignees});
    try w.writeByte('\n');
    try common.writeBody(ctx, i.body);
    if (args.has("comments")) try common.writeComments(ctx, &client, r, n);
    try w.writeByte('\n');
    try term.paint(ctx, w, .dim, try std.fmt.allocPrint(ctx.alloc, "View this issue on Forgejo: {s}", .{i.html_url}));
    try w.writeByte('\n');
    return 0;
}

fn create(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    if (args.has("web")) {
        const url = try common.query(ctx, try r.webUrl(ctx.alloc, "/issues/new", .{}), &.{
            .{ "title", args.get("title") },
            .{ "body", try common.bodyFromFlags(ctx, args) },
        });
        try ctx.openBrowser(url);
        return 0;
    }
    if (!ctx.interactive() and (args.get("title") == null or (args.get("body") == null and args.get("body-file") == null)))
        return ctx.fail("--title and --body are required when not running interactively", .{});
    const t = try common.title(ctx, args, null);
    const body = try common.bodyOrEditor(ctx, args, "ISSUE.md", "");
    var client = try r.client(ctx);
    const labels = try common.labelIds(ctx, &client, r, try args.all(ctx.alloc, "label"));
    const assignees = try args.all(ctx.alloc, "assignee");
    const v = try client.sendValue(.POST, try r.path(ctx.alloc, "/issues", .{}), .{
        .title = t,
        .body = body,
        .labels = labels,
        .assignees = assignees,
    });
    const i = try api.decode(types.Issue, ctx, v);
    try ctx.out.print("{s}\n", .{i.html_url});
    return 0;
}

fn setState(ctx: *Ctx, args: *const cli.Args, state: []const u8, verb: []const u8) !u8 {
    const r = try repo.resolve(ctx, args);
    const n = try common.number(ctx, args.arg(0).?);
    var client = try r.client(ctx);
    const i = try api.decode(types.Issue, ctx, try client.getValue(try r.path(ctx.alloc, "/issues/{d}", .{n})));
    if (std.mem.eql(u8, i.state, state)) {
        try ctx.err.print("! Issue #{d} ({s}) is already {s}\n", .{ n, i.title, state });
        return 0;
    }
    if (args.get("comment")) |c| _ = try common.comment(ctx, &client, r, n, c);
    try client.sendNoContent(.PATCH, try r.path(ctx.alloc, "/issues/{d}", .{n}), .{ .state = state });
    try ctx.err.print("✓ {s} issue #{d} ({s})\n", .{ verb, n, i.title });
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
    const n = try common.number(ctx, args.arg(0).?);
    const body = try common.bodyOrEditor(ctx, args, "COMMENT.md", "");
    var client = try r.client(ctx);
    _ = try common.comment(ctx, &client, r, n, body);
    try ctx.out.print("{s}\n", .{try r.webUrl(ctx.alloc, "/issues/{d}", .{n})});
    return 0;
}

fn edit(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    const n = try common.number(ctx, args.arg(0).?);
    var client = try r.client(ctx);
    const i = try api.decode(types.Issue, ctx, try client.getValue(try r.path(ctx.alloc, "/issues/{d}", .{n})));
    const Patch = struct { title: ?[]const u8 = null, body: ?[]const u8 = null };
    const patch: Patch = .{ .title = args.get("title"), .body = try common.bodyFromFlags(ctx, args) };
    if (patch.title != null or patch.body != null)
        try client.sendNoContent(.PATCH, try r.path(ctx.alloc, "/issues/{d}", .{n}), patch);
    try common.editLabelsAndAssignees(ctx, &client, r, args, n, i.assignees);
    try ctx.out.print("{s}\n", .{i.html_url});
    return 0;
}

pub fn isOneOf(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}
