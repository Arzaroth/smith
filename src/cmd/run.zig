const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const git = @import("../git.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");
const common = @import("common.zig");
const pr = @import("pr.zig");

const id_usage = "[<run-id>]";
const interval_flag: cli.Flag = .{ .long = "interval", .short = 'i', .value = "seconds", .help = "Refresh interval (default 3)" };
const exit_status_flag: cli.Flag = .{ .long = "exit-status", .help = "Exit with a non-zero status if the run failed" };

pub const command: cli.Command = .{
    .name = "run",
    .summary = "Work with Forgejo Actions workflow runs.",
    .subs = &.{
        .{
            .name = "list",
            .summary = "List recent workflow runs.",
            .flags = &.{
                .{ .long = "branch", .short = 'b', .value = "string", .help = "Filter by branch" },
                .{ .long = "status", .short = 's', .value = "string", .help = "Filter by status: waiting, running, success, failure, cancelled, skipped, blocked" },
                .{ .long = "event", .short = 'e', .value = "string", .help = "Filter by triggering event, e.g. push or pull_request" },
                .{ .long = "workflow", .short = 'w', .value = "file", .help = "Filter by workflow file, e.g. ci.yml" },
                .{ .long = "commit", .short = 'c', .value = "sha", .help = "Filter by commit" },
                cli.limit_flag,
                cli.json_flag,
                .{ .long = "web", .help = "Open the Actions page in the browser" },
                cli.repo_flag,
            },
            .run = list,
        },
        .{
            .name = "view",
            .summary = "Show a run and its jobs; without an id, the latest run of the current branch.",
            .usage = id_usage,
            .max_args = 1,
            .flags = &.{
                .{ .long = "log", .help = "Print the logs of the run's jobs" },
                .{ .long = "log-failed", .help = "Print the logs of the failed jobs only" },
                .{ .long = "job", .short = 'j', .value = "id", .help = "Limit --log to one job" },
                exit_status_flag,
                cli.json_flag,
                cli.web_flag,
                cli.repo_flag,
            },
            .run = view,
        },
        .{
            .name = "watch",
            .summary = "Follow a run until it finishes; without an id, the latest run of the current branch.",
            .usage = id_usage,
            .max_args = 1,
            .flags = &.{ interval_flag, exit_status_flag, cli.repo_flag },
            .run = watch,
        },
        .{
            .name = "cancel",
            .summary = "Cancel a workflow run.",
            .usage = "<run-id>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{cli.repo_flag},
            .run = cancel,
        },
    },
};

pub fn outcome(status: []const u8) pr.Outcome {
    if (std.mem.eql(u8, status, "success")) return .pass;
    if (std.mem.eql(u8, status, "failure") or std.mem.eql(u8, status, "cancelled")) return .fail;
    if (std.mem.eql(u8, status, "skipped")) return .skip;
    return .pending;
}

fn statusCell(ctx: *const Ctx, status: []const u8) term.Cell {
    if (!ctx.stdout_tty) return .{ .text = status };
    return pr.outcomeCell(outcome(status));
}

fn runsPath(ctx: *Ctx, r: repo.Repo, args: *const cli.Args) ![]const u8 {
    const branch = if (args.get("branch")) |b| try std.fmt.allocPrint(ctx.alloc, "refs/heads/{s}", .{b}) else null;
    return common.query(ctx, try r.path(ctx.alloc, "/actions/runs", .{}), &.{
        .{ "ref", branch },
        .{ "status", args.get("status") },
        .{ "event", args.get("event") },
        .{ "workflow_id", args.get("workflow") },
        .{ "head_sha", args.get("commit") },
    });
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    if (args.has("web")) {
        try ctx.openBrowser(try r.webUrl(ctx.alloc, "/actions", .{}));
        return 0;
    }
    var client = try r.client(ctx);
    const values = try client.listValues(try runsPath(ctx, r, args), try args.int("limit", 20), "workflow_runs");
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const runs = try api.decodeAll(types.ActionRun, ctx, values);
    if (runs.len == 0) {
        try ctx.err.print("No runs found in {s}\n", .{try r.fullName(ctx.alloc)});
        return 0;
    }
    var table: term.Table = .{};
    for (runs) |run| {
        try table.add(ctx.alloc, &.{
            statusCell(ctx, run.status),
            .{ .text = if (ctx.stdout_tty) try term.truncate(ctx.alloc, run.title, 60) else run.title },
            .{ .text = run.workflow_id },
            .{ .text = run.prettyref, .color = .cyan },
            .{ .text = if (run.event.len > 0) run.event else run.trigger_event, .color = .dim },
            .{ .text = try std.fmt.allocPrint(ctx.alloc, "{d}", .{run.id}), .color = .dim },
            .{ .text = try term.duration(ctx.alloc, run.started, run.stopped), .color = .dim },
            .{ .text = try term.ago(ctx.alloc, ctx.now, run.created), .color = .dim },
        });
    }
    try table.write(ctx);
    return 0;
}

const Fetched = struct {
    run: types.ActionRun,
    value: std.json.Value,
};

/// A run by id, or the latest run of the current branch.
fn pick(ctx: *Ctx, client: *api.Client, r: repo.Repo, id_arg: ?[]const u8) !Fetched {
    if (id_arg) |s| {
        const id = std.fmt.parseInt(i64, std.mem.trimStart(u8, s, "#"), 10) catch return ctx.fail("invalid run id: {s}", .{s});
        const v = try client.getValue(try r.path(ctx.alloc, "/actions/runs/{d}", .{id}));
        return .{ .run = try api.decode(types.ActionRun, ctx, v), .value = v };
    }
    const branch = try git.currentBranch(ctx) orelse return ctx.fail("not on a branch; give a run id", .{});
    const path = try common.query(ctx, try r.path(ctx.alloc, "/actions/runs", .{}), &.{.{ "ref", try std.fmt.allocPrint(ctx.alloc, "refs/heads/{s}", .{branch}) }});
    const values = try client.listValues(path, 1, "workflow_runs");
    if (values.len == 0) return ctx.fail("no runs found for branch \"{s}\"", .{branch});
    return .{ .run = try api.decode(types.ActionRun, ctx, values[0]), .value = values[0] };
}

fn jobs(ctx: *Ctx, client: *api.Client, r: repo.Repo, run_id: i64) ![]const types.ActionRunJob {
    const v = try client.getValue(try r.path(ctx.alloc, "/actions/runs/{d}/jobs", .{run_id}));
    return switch (v) {
        .array => |a| api.decodeAll(types.ActionRunJob, ctx, a.items),
        else => &.{},
    };
}

fn writeRun(ctx: *Ctx, run: types.ActionRun, js: []const types.ActionRunJob) !void {
    const w = ctx.out;
    try term.paint(ctx, w, pr.outcomeCell(outcome(run.status)).color, pr.outcomeCell(outcome(run.status)).text);
    try w.print(" {s} {s} · {d}\n", .{ run.prettyref, run.workflow_id, run.id });
    try term.paint(ctx, w, .bold, run.title);
    try w.writeByte('\n');
    try w.print("Triggered via {s} {s}", .{ if (run.event.len > 0) run.event else run.trigger_event, try term.ago(ctx.alloc, ctx.now, run.created) });
    if (run.trigger_user) |u| try w.print(" by {s}", .{u.login});
    const took = try term.duration(ctx.alloc, run.started, run.stopped);
    if (took.len > 0) try w.print(" · took {s}", .{took});
    try w.print(" · {s}\n\nJOBS\n", .{run.status});
    for (js) |j| {
        const cell = pr.outcomeCell(outcome(j.status));
        try term.paint(ctx, w, cell.color, cell.text);
        try w.print(" {s} ", .{j.name});
        try term.paint(ctx, w, .dim, try std.fmt.allocPrint(ctx.alloc, "(ID {d}, {s})", .{ j.id, j.status }));
        try w.writeByte('\n');
    }
}

fn exitFor(run: types.ActionRun, args: *const cli.Args) u8 {
    if (!args.has("exit-status")) return 0;
    return switch (outcome(run.status)) {
        .fail => 1,
        .pending => 8,
        else => 0,
    };
}

fn view(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const f = try pick(ctx, &client, r, args.arg(0));
    const run = f.run;
    if (args.has("web")) {
        try ctx.openBrowser(run.html_url);
        return 0;
    }
    if (args.has("json")) {
        try api.printJson(ctx, f.value);
        return exitFor(run, args);
    }
    const js = try jobs(ctx, &client, r, run.id);
    if (args.has("log") or args.has("log-failed")) {
        const only: ?i64 = if (args.get("job")) |j| std.fmt.parseInt(i64, j, 10) catch return ctx.fail("invalid job id: {s}", .{j}) else null;
        for (js) |j| {
            if (only) |o| if (o != j.id) continue;
            if (args.has("log-failed") and outcome(j.status) != .fail) continue;
            const resp = try client.raw(.GET, try r.path(ctx.alloc, "/actions/jobs/{d}/logs", .{j.id}), .{ .accept = "text/plain" });
            if (!resp.ok()) {
                try ctx.err.print("! no logs for job {s} (HTTP {d})\n", .{ j.name, resp.status });
                continue;
            }
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, resp.body, "\n"), '\n');
            while (lines.next()) |line| {
                try term.paint(ctx, ctx.out, .cyan, j.name);
                try ctx.out.print("\t{s}\n", .{line});
            }
        }
        return exitFor(run, args);
    }
    try writeRun(ctx, run, js);
    try ctx.out.writeByte('\n');
    try term.paint(ctx, ctx.out, .dim, try std.fmt.allocPrint(ctx.alloc, "View this run on Forgejo: {s}", .{run.html_url}));
    try ctx.out.writeByte('\n');
    return exitFor(run, args);
}

fn watch(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const first = try pick(ctx, &client, r, args.arg(0));
    const id = first.run.id;
    const interval = try args.int("interval", 3);
    var last: []const u8 = "";
    while (true) {
        const run = try api.decode(types.ActionRun, ctx, try client.getValue(try r.path(ctx.alloc, "/actions/runs/{d}", .{id})));
        const js = try jobs(ctx, &client, r, id);

        var snapshot: std.Io.Writer.Allocating = .init(ctx.alloc);
        const saved = ctx.out;
        ctx.out = &snapshot.writer;
        writeRun(ctx, run, js) catch |e| {
            ctx.out = saved;
            return e;
        };
        ctx.out = saved;
        const text = snapshot.written();
        if (!std.mem.eql(u8, text, last)) {
            if (ctx.stdout_tty and last.len > 0) try ctx.out.writeAll("\x1b[H\x1b[2J");
            try ctx.out.writeAll(text);
            if (!ctx.stdout_tty) try ctx.out.writeByte('\n');
            try ctx.out.flush();
            last = text;
        }
        if (outcome(run.status) != .pending) {
            try ctx.err.print("\nRun {d} finished: {s}\n", .{ id, run.status });
            return if (args.has("exit-status") and outcome(run.status) == .fail) 1 else 0;
        }
        try ctx.io.sleep(.fromSeconds(interval), .awake);
    }
}

fn cancel(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const run = (try pick(ctx, &client, r, args.arg(0))).run;
    if (outcome(run.status) != .pending) return ctx.fail("run {d} has already finished ({s})", .{ run.id, run.status });
    _ = try client.call(.POST, try r.path(ctx.alloc, "/actions/runs/{d}/cancel", .{run.id}), .{});
    try ctx.err.print("✓ Cancelled run {d}\n", .{run.id});
    return 0;
}
