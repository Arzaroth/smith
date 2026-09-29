//! Pieces shared by the issue and pull request commands, which Forgejo
//! backs with the same issue endpoints for comments, labels and state.
const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");

pub const body_flag: cli.Flag = .{ .long = "body", .short = 'b', .value = "string", .help = "Body text" };
pub const body_file_flag: cli.Flag = .{ .long = "body-file", .short = 'F', .value = "file", .help = "Read the body from a file (\"-\" for standard input)" };

/// A pull request or issue number from `12`, `#12`, or a web URL ending in
/// `/12`; null for anything else, a branch like `fix/42` included.
pub fn parseNumber(s: []const u8) ?i64 {
    var t = s;
    if (std.mem.indexOf(u8, s, "://") != null) {
        t = std.mem.trimEnd(u8, s, "/");
        t = t[(std.mem.lastIndexOfScalar(u8, t, '/') orelse return null) + 1 ..];
    } else if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

pub fn number(ctx: *Ctx, s: []const u8) !i64 {
    return parseNumber(s) orelse ctx.fail("invalid number: {s}", .{s});
}

/// The body from `--body` or `--body-file`, or null when neither was given.
pub fn bodyFromFlags(ctx: *Ctx, args: *const cli.Args) !?[]const u8 {
    if (args.get("body")) |b| return b;
    const path = args.get("body-file") orelse return null;
    if (std.mem.eql(u8, path, "-")) return try ctx.readStdin();
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(16 * 1024 * 1024)) catch |e|
        ctx.fail("cannot read {s}: {t}", .{ path, e });
}

/// The body from the flags, else from the editor on a terminal, else empty.
pub fn bodyOrEditor(ctx: *Ctx, args: *const cli.Args, name: []const u8, initial: []const u8) ![]const u8 {
    if (try bodyFromFlags(ctx, args)) |b| return b;
    if (!ctx.interactive()) return initial;
    return std.mem.trim(u8, try ctx.editText(name, initial), " \r\n\t");
}

pub fn title(ctx: *Ctx, args: *const cli.Args, default: ?[]const u8) ![]const u8 {
    if (args.get("title")) |t| return t;
    if (ctx.interactive()) {
        const label = if (default) |d| try std.fmt.allocPrint(ctx.alloc, "Title ({s}):", .{d}) else "Title:";
        const t = try ctx.prompt(label);
        if (t.len > 0) return t;
    }
    return default orelse ctx.fail("--title is required when not running interactively", .{});
}

/// Resolves label names to ids, looking at the repository's labels and, for
/// an organization, its labels too.
pub fn labelIds(ctx: *Ctx, client: *api.Client, r: repo.Repo, names: []const []const u8) ![]const i64 {
    if (names.len == 0) return &.{};
    var known: std.ArrayList(types.Label) = .empty;
    try known.appendSlice(ctx.alloc, try api.decodeAll(types.Label, ctx, try client.listValues(try r.path(ctx.alloc, "/labels", .{}), 500, null)));
    const org_path = try std.fmt.allocPrint(ctx.alloc, "/orgs/{s}/labels?limit=1", .{r.owner});
    if ((try client.raw(.GET, org_path, .{})).ok()) {
        const all = try client.listValues(try std.fmt.allocPrint(ctx.alloc, "/orgs/{s}/labels", .{r.owner}), 500, null);
        try known.appendSlice(ctx.alloc, try api.decodeAll(types.Label, ctx, all));
    }
    const ids = try ctx.alloc.alloc(i64, names.len);
    for (names, ids) |n, *id| {
        id.* = for (known.items) |l| {
            if (std.ascii.eqlIgnoreCase(l.name, n)) break l.id;
        } else return ctx.fail("no label named \"{s}\" in {s}/{s}", .{ n, r.owner, r.name });
    }
    return ids;
}

pub fn joinLabels(ctx: *Ctx, labels: ?[]const types.Label) ![]const u8 {
    const ls = labels orelse return "";
    var names: std.ArrayList([]const u8) = .empty;
    for (ls) |l| try names.append(ctx.alloc, l.name);
    return term.clean(ctx.alloc, try std.mem.join(ctx.alloc, ", ", names.items), false);
}

pub fn joinUsers(ctx: *Ctx, users: ?[]const types.User) ![]const u8 {
    const us = users orelse return "";
    var names: std.ArrayList([]const u8) = .empty;
    for (us) |u| try names.append(ctx.alloc, u.login);
    return term.clean(ctx.alloc, try std.mem.join(ctx.alloc, ", ", names.items), false);
}

pub fn stateColor(state: []const u8) term.Color {
    if (std.mem.eql(u8, state, "open")) return .green;
    if (std.mem.eql(u8, state, "merged")) return .magenta;
    return .red;
}

pub fn capitalized(ctx: *Ctx, s: []const u8) ![]const u8 {
    if (s.len == 0) return s;
    const out = try ctx.alloc.dupe(u8, s);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub fn writeBody(ctx: *Ctx, body: ?[]const u8) !void {
    const b = std.mem.trim(u8, body orelse "", " \r\n\t");
    if (b.len == 0) {
        try term.paint(ctx, ctx.out, .dim, "No description provided");
        try ctx.out.writeByte('\n');
    } else {
        try ctx.out.print("{s}\n", .{try term.clean(ctx.alloc, b, true)});
    }
}

pub fn writeComments(ctx: *Ctx, client: *api.Client, r: repo.Repo, n: i64) !void {
    // This endpoint returns every comment at once and ignores page/limit.
    const v = try client.getValue(try r.path(ctx.alloc, "/issues/{d}/comments", .{n}));
    const values: []const std.json.Value = if (v == .array) v.array.items else &.{};
    const comments = try api.decodeAll(types.Comment, ctx, values);
    for (comments) |c| {
        try ctx.out.writeByte('\n');
        try term.paint(ctx, ctx.out, .bold, if (c.user) |u| u.login else "ghost");
        try ctx.out.print(" commented {s}\n", .{try term.ago(ctx.alloc, ctx.now, c.created_at)});
        try ctx.out.print("{s}\n", .{try term.clean(ctx.alloc, std.mem.trim(u8, c.body, " \r\n\t"), true)});
    }
}

pub fn comment(ctx: *Ctx, client: *api.Client, r: repo.Repo, n: i64, body: []const u8) !types.Comment {
    if (std.mem.trim(u8, body, " \r\n\t").len == 0) return ctx.fail("the comment is empty", .{});
    const v = try client.sendValue(.POST, try r.path(ctx.alloc, "/issues/{d}/comments", .{n}), .{ .body = body });
    return api.decode(types.Comment, ctx, v);
}

/// Adds and removes labels and assignees on an issue or pull request.
pub fn editLabelsAndAssignees(ctx: *Ctx, client: *api.Client, r: repo.Repo, args: *const cli.Args, n: i64, current: ?[]const types.User) !void {
    const add_labels = try args.all(ctx.alloc, "add-label");
    if (add_labels.len > 0) {
        const ids = try labelIds(ctx, client, r, add_labels);
        _ = try client.sendValue(.POST, try r.path(ctx.alloc, "/issues/{d}/labels", .{n}), .{ .labels = ids });
    }
    const remove_labels = try args.all(ctx.alloc, "remove-label");
    if (remove_labels.len > 0) {
        for (try labelIds(ctx, client, r, remove_labels)) |id| {
            _ = try client.call(.DELETE, try r.path(ctx.alloc, "/issues/{d}/labels/{d}", .{ n, id }), .{});
        }
    }
    const add = try args.all(ctx.alloc, "add-assignee");
    const remove = try args.all(ctx.alloc, "remove-assignee");
    if (add.len == 0 and remove.len == 0) return;
    var logins: std.ArrayList([]const u8) = .empty;
    if (current) |us| for (us) |u| {
        if (!contains(remove, u.login)) try logins.append(ctx.alloc, u.login);
    };
    for (add) |a| if (!contains(logins.items, a)) try logins.append(ctx.alloc, a);
    try client.sendNoContent(.PATCH, try r.path(ctx.alloc, "/issues/{d}", .{n}), .{ .assignees = logins.items });
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
    return false;
}

pub const edit_flags = [_]cli.Flag{
    .{ .long = "title", .short = 't', .value = "string", .help = "Set the title" },
    body_flag,
    body_file_flag,
    .{ .long = "add-label", .value = "name", .help = "Add labels by name" },
    .{ .long = "remove-label", .value = "name", .help = "Remove labels by name" },
    .{ .long = "add-assignee", .value = "login", .help = "Add assignees by login" },
    .{ .long = "remove-assignee", .value = "login", .help = "Remove assignees by login" },
};

pub fn query(ctx: *Ctx, base: []const u8, params: []const [2]?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.alloc, base);
    var sep: u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) '&' else '?';
    for (params) |p| {
        const v = p[1] orelse continue;
        try out.print(ctx.alloc, "{c}{s}={s}", .{ sep, p[0].?, try api.escape(ctx.alloc, v) });
        sep = '&';
    }
    return out.toOwnedSlice(ctx.alloc);
}

pub const milestone_flag: cli.Flag = .{ .long = "milestone", .short = 'm', .value = "title", .help = "Milestone, by title or id" };

/// A milestone's id from its title or id.
pub fn milestoneId(ctx: *Ctx, client: *api.Client, r: repo.Repo, name: ?[]const u8) !?i64 {
    const n = name orelse return null;
    const resp = try client.raw(.GET, try r.path(ctx.alloc, "/milestones/{s}", .{try api.escape(ctx.alloc, n)}), .{});
    if (resp.status == 404) return ctx.fail("no milestone \"{s}\" in {s}/{s}", .{ n, r.owner, r.name });
    if (!resp.ok()) return client.failStatus(.GET, "/milestones", resp);
    return (try api.decode(types.Milestone, ctx, try client.parseValue(resp.body))).id;
}
