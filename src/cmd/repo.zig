const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const config = @import("../config.zig");
const api = @import("../api.zig");
const git = @import("../git.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");

pub const command: cli.Command = .{
    .name = "repo",
    .summary = "Work with repositories.",
    .subs = &.{
        .{
            .name = "clone",
            .summary = "Clone a repository locally; a fork gets an `upstream` remote.",
            .usage = "<repository> [<directory>] [-- <gitflags>...]",
            .min_args = 1,
            .max_args = 2,
            .passthrough = true,
            .flags = &.{.{ .long = "upstream-remote-name", .short = 'u', .value = "string", .help = "Name of the remote pointing at a fork's parent (default upstream)" }},
            .run = clone,
        },
        .{
            .name = "view",
            .pages = true,
            .summary = "Show a repository's description and details.",
            .usage = "[<repository>]",
            .max_args = 1,
            .flags = &.{ cli.web_flag, cli.json_flag, cli.repo_flag },
            .run = view,
        },
        .{
            .name = "create",
            .summary = "Create a repository; with --source, from a local clone.",
            .usage = "[<name> | <owner>/<name>]",
            .max_args = 1,
            .flags = &.{
                .{ .long = "public", .help = "Make it public" },
                .{ .long = "private", .help = "Make it private" },
                .{ .long = "description", .short = 'd', .value = "string", .help = "Description" },
                .{ .long = "homepage", .value = "url", .help = "Website" },
                .{ .long = "add-readme", .help = "Start with a README" },
                .{ .long = "gitignore", .short = 'g', .value = "template", .help = "Start with a .gitignore template, e.g. Go" },
                .{ .long = "license", .short = 'l', .value = "name", .help = "Start with a licence, e.g. MIT" },
                .{ .long = "default-branch", .value = "name", .help = "Default branch name" },
                .{ .long = "clone", .short = 'c', .help = "Clone it afterwards" },
                .{ .long = "source", .short = 's', .value = "path", .help = "Local repository to create it from" },
                .{ .long = "remote", .short = 'r', .value = "name", .help = "Remote to add for --source (default origin)" },
                .{ .long = "push", .help = "Push --source's current branch" },
                .{ .long = "hostname", .value = "string", .help = "The Forgejo host (default: the default host)" },
            },
            .run = create,
        },
        .{
            .name = "fork",
            .summary = "Fork a repository; inside its clone, --remote points origin at the fork.",
            .usage = "[<repository>]",
            .max_args = 1,
            .flags = &.{
                .{ .long = "clone", .help = "Clone the fork" },
                .{ .long = "remote", .help = "In a clone: rename origin to upstream and add the fork as origin" },
                .{ .long = "org", .value = "name", .help = "Fork into an organization" },
                .{ .long = "fork-name", .value = "name", .help = "Name of the fork" },
                cli.repo_flag,
            },
            .run = fork,
        },
        .{
            .name = "edit",
            .summary = "Change a repository's settings.",
            .usage = "[<repository>]",
            .max_args = 1,
            .flags = &(edit_flags ++ [_]cli.Flag{cli.repo_flag}),
            .run = edit,
        },
        .{
            .name = "sync",
            .summary = "Update a fork from its parent, or a pull mirror from its source.",
            .usage = "[<repository>]",
            .max_args = 1,
            .flags = &.{ .{ .long = "branch", .short = 'b', .value = "name", .help = "Branch to sync (default: the default branch)" }, cli.repo_flag },
            .run = sync,
        },
        .{ .name = "archive", .summary = "Archive a repository.", .usage = "[<repository>]", .max_args = 1, .flags = &.{ cli.yes_flag, cli.repo_flag }, .run = archive },
        .{ .name = "unarchive", .summary = "Unarchive a repository.", .usage = "[<repository>]", .max_args = 1, .flags = &.{ cli.yes_flag, cli.repo_flag }, .run = unarchive },
        .{
            .name = "delete",
            .summary = "Delete a repository.",
            .usage = "[<repository>]",
            .max_args = 1,
            .flags = &.{ cli.yes_flag, cli.repo_flag },
            .run = delete,
        },
        .{
            .name = "set-default",
            .summary = "Choose which remote's repository commands act on in this clone.",
            .usage = "[<repository>]",
            .max_args = 1,
            .flags = &.{ .{ .long = "view", .short = 'v', .help = "Show the current choice" }, .{ .long = "unset", .short = 'u', .help = "Forget the choice" } },
            .run = setDefault,
        },
        .{
            .name = "list",
            .pages = true,
            .summary = "List the repositories of a user or organization.",
            .usage = "[<owner>]",
            .max_args = 1,
            .flags = &.{ cli.limit_flag, cli.json_flag, .{ .long = "hostname", .value = "string", .help = "The Forgejo host to list from" } },
            .run = list,
        },
    },
};

/// The repository named by a positional argument (`REPO`, `OWNER/REPO` or
/// `HOST/OWNER/REPO`), or the current one.
fn target(ctx: *Ctx, args: *const cli.Args, spec_arg: ?[]const u8) !repo.Repo {
    const s = spec_arg orelse return repo.resolve(ctx, args);
    const cfg = try config.load(ctx);
    if (std.mem.indexOfScalar(u8, s, '/') == null) {
        const host = try repo.hostFor(ctx, cfg, null);
        const owner = host.user orelse return ctx.fail("cannot tell whose \"{s}\" this is; use OWNER/REPO", .{s});
        return .{ .host = host, .owner = owner, .name = s };
    }
    const spec = repo.parseSpec(s) orelse return ctx.fail("expected [HOST/]OWNER/REPO, got \"{s}\"", .{s});
    return .{ .host = try repo.hostFor(ctx, cfg, spec.host), .owner = spec.owner, .name = spec.name };
}

fn cloneUrl(r: types.Repository, protocol: config.Protocol) ?[]const u8 {
    return switch (protocol) {
        .ssh => r.ssh_url orelse r.clone_url,
        .https => r.clone_url orelse r.ssh_url,
    };
}

fn clone(ctx: *Ctx, args: *const cli.Args) !u8 {
    const t = try target(ctx, args, args.arg(0));
    var client = try t.client(ctx);
    const info = try api.decode(types.Repository, ctx, try client.getValue(try t.path(ctx.alloc, "", .{})));
    const url = cloneUrl(info, t.host.git_protocol) orelse return ctx.fail("{s} has no clone URL", .{info.full_name});
    const dir = args.arg(1) orelse try cloneDir(ctx, info.name);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.alloc, "clone");
    try argv.appendSlice(ctx.alloc, args.passthrough);
    try argv.appendSlice(ctx.alloc, &.{ "--", url, dir });
    try git.run(ctx, argv.items);

    if (info.fork) if (info.parent) |parent| {
        const name = args.get("upstream-remote-name") orelse "upstream";
        const parent_url = cloneUrl(parent.*, t.host.git_protocol) orelse return 0;
        try git.run(ctx, &.{ "-C", dir, "remote", "add", "-f", "--", name, parent_url });
        try ctx.err.print("✓ Added remote {s} for {s}\n", .{ name, parent.full_name });
    };
    return 0;
}

fn view(ctx: *Ctx, args: *const cli.Args) !u8 {
    const t = try target(ctx, args, args.arg(0));
    if (args.has("web")) {
        try ctx.openBrowser(try t.webUrl(ctx.alloc, "", .{}));
        return 0;
    }
    var client = try t.client(ctx);
    const v = try client.getValue(try t.path(ctx.alloc, "", .{}));
    if (args.has("json")) {
        try api.printJson(ctx, v);
        return 0;
    }
    const r = try api.decode(types.Repository, ctx, v);
    const w = ctx.out;
    try term.paint(ctx, w, .bold, r.full_name);
    try w.writeByte('\n');
    if (r.description) |d| if (d.len > 0) try w.print("{s}\n", .{d});
    try w.writeByte('\n');
    try w.print("{s}", .{if (r.private) "private" else "public"});
    if (r.fork) if (r.parent) |p| try w.print(" · fork of {s}", .{p.full_name});
    if (r.archived) try w.writeAll(" · archived");
    try w.print(" · {d} stars · {d} forks · {d} open issues · {d} open pull requests\n", .{ r.stars_count, r.forks_count, r.open_issues_count, r.open_pr_counter });
    if (r.default_branch) |b| try w.print("Default branch: {s}\n", .{b});
    if (r.ssh_url) |u| try w.print("SSH:   {s}\n", .{u});
    if (r.clone_url) |u| try w.print("HTTPS: {s}\n", .{u});
    try term.paint(ctx, w, .dim, r.html_url);
    try w.writeByte('\n');
    return 0;
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const cfg = try config.load(ctx);
    const host = try repo.hostFor(ctx, cfg, args.get("hostname"));
    var client = try api.Client.init(ctx, host);
    const limit = try args.int("limit", 30);

    const values = if (args.arg(0)) |owner| blk: {
        const user_path = try std.fmt.allocPrint(ctx.alloc, "/users/{s}/repos", .{try api.escape(ctx.alloc, owner)});
        const probe = try client.raw(.GET, try std.fmt.allocPrint(ctx.alloc, "{s}?limit=1", .{user_path}), .{});
        if (probe.status == 404) {
            break :blk try client.listValues(try std.fmt.allocPrint(ctx.alloc, "/orgs/{s}/repos", .{try api.escape(ctx.alloc, owner)}), limit, null);
        }
        break :blk try client.listValues(user_path, limit, null);
    } else try client.listValues("/user/repos", limit, null);

    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const repos = try api.decodeAll(types.Repository, ctx, values);
    if (repos.len == 0) {
        try ctx.err.writeAll("No repositories found\n");
        return 0;
    }
    var table: term.Table = .{};
    for (repos) |r| {
        const kind = if (r.private) "private" else if (r.fork) "fork" else if (r.archived) "archived" else "public";
        try table.add(ctx.alloc, &.{
            .{ .text = r.full_name, .color = .bold },
            .{ .text = try term.fit(ctx, r.description orelse "", 50) },
            .{ .text = kind, .color = .dim },
            .{ .text = try term.when(ctx, r.updated_at), .color = .dim },
        });
    }
    try table.write(ctx);
    return 0;
}

/// The directory a clone lands in when none is given: the repository's name,
/// which comes from the server and must stay a plain name here.
fn cloneDir(ctx: *Ctx, name: []const u8) ![]const u8 {
    _ = try git.safeName(ctx, "directory", name);
    if (std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return ctx.fail("refusing directory \"{s}\" from the server; name one", .{name});
    return name;
}

const toggles = [_][2][]const u8{
    .{ "issues", "has_issues" },
    .{ "wiki", "has_wiki" },
    .{ "pull-requests", "has_pull_requests" },
    .{ "actions", "has_actions" },
    .{ "releases", "has_releases" },
    .{ "projects", "has_projects" },
    .{ "packages", "has_packages" },
};

const edit_flags = [_]cli.Flag{
    .{ .long = "description", .short = 'd', .value = "string", .help = "Description" },
    .{ .long = "homepage", .value = "url", .help = "Website" },
    .{ .long = "default-branch", .value = "name", .help = "Default branch" },
    .{ .long = "visibility", .value = "public|private", .help = "Visibility" },
    .{ .long = "merge-style", .value = "style", .help = "Default merge style: merge, rebase, rebase-merge, squash, fast-forward-only" },
    .{ .long = "delete-branch-on-merge", .help = "Delete head branches after merging by default" },
    .{ .long = "template", .help = "Make it a template repository" },
} ++ blk: {
    var flags: [toggles.len * 2]cli.Flag = undefined;
    for (toggles, 0..) |t, i| {
        flags[i * 2] = .{ .long = "enable-" ++ t[0], .help = "Turn " ++ t[0] ++ " on" };
        flags[i * 2 + 1] = .{ .long = "disable-" ++ t[0], .help = "Turn " ++ t[0] ++ " off" };
    }
    break :blk flags;
};

fn create(ctx: *Ctx, args: *const cli.Args) !u8 {
    const cfg = try config.load(ctx);
    const host = try repo.hostFor(ctx, cfg, args.get("hostname"));
    var client = try api.Client.init(ctx, host);
    const source = args.get("source");
    const spec = args.arg(0) orelse if (source) |s| std.fs.path.basename(s) else (if (ctx.interactive()) try ctx.prompt("Repository name:") else return ctx.fail("name the repository", .{}));
    const slash = std.mem.indexOfScalar(u8, spec, '/');
    const org = if (slash) |i| spec[0..i] else null;
    const name = if (slash) |i| spec[i + 1 ..] else spec;
    if (name.len == 0) return ctx.fail("name the repository", .{});

    if (args.has("public") and args.has("private")) return ctx.fail("choose one of --public and --private", .{});
    const private = if (args.has("private")) true else if (args.has("public")) false else if (ctx.interactive()) blk: {
        const v = try ctx.prompt("Visibility (public/private):");
        break :blk !std.mem.startsWith(u8, v, "pu");
    } else return ctx.fail("choose --public or --private", .{});

    const Create = struct {
        name: []const u8,
        description: []const u8,
        private: bool,
        auto_init: bool,
        readme: ?[]const u8 = null,
        gitignores: ?[]const u8 = null,
        license: ?[]const u8 = null,
        default_branch: ?[]const u8 = null,
    };
    const init_files = args.has("add-readme") or args.get("gitignore") != null or args.get("license") != null;
    const body: Create = .{
        .name = name,
        .description = args.get("description") orelse "",
        .private = private,
        .auto_init = init_files,
        .readme = if (init_files) "Default" else null,
        .gitignores = args.get("gitignore"),
        .license = args.get("license"),
        .default_branch = args.get("default-branch"),
    };
    const me = host.user;
    const path = if (org != null and (me == null or !std.ascii.eqlIgnoreCase(org.?, me.?)))
        try std.fmt.allocPrint(ctx.alloc, "/orgs/{s}/repos", .{try api.escape(ctx.alloc, org.?)})
    else
        "/user/repos";
    const created = try api.decode(types.Repository, ctx, try client.sendValue(.POST, path, body));
    if (args.get("homepage")) |w| {
        const owner = if (created.owner) |o| o.login else org orelse me orelse "";
        _ = try client.sendValue(.PATCH, try std.fmt.allocPrint(ctx.alloc, "/repos/{s}/{s}", .{ owner, created.name }), .{ .website = w });
    }
    try ctx.err.print("✓ Created repository {s}\n", .{created.full_name});
    try ctx.out.print("{s}\n", .{created.html_url});

    const url = cloneUrl(created, host.git_protocol) orelse return 0;
    if (source) |src| {
        const remote = args.get("remote") orelse "origin";
        try git.run(ctx, &.{ "-C", src, "remote", "add", "--", remote, url });
        try ctx.err.print("✓ Added remote {s}\n", .{remote});
        if (args.has("push")) try git.run(ctx, &.{ "-C", src, "push", "-u", "--", remote, "HEAD" });
    } else if (args.has("clone")) {
        try git.run(ctx, &.{ "clone", "--", url, try cloneDir(ctx, created.name) });
    }
    return 0;
}

fn fork(ctx: *Ctx, args: *const cli.Args) !u8 {
    const in_clone = args.arg(0) == null and args.get("repo") == null;
    const t = try target(ctx, args, args.arg(0));
    var client = try t.client(ctx);
    const Fork = struct { organization: ?[]const u8 = null, name: ?[]const u8 = null };
    const f = try api.decode(types.Repository, ctx, try client.sendValue(.POST, try t.path(ctx.alloc, "/forks", .{}), Fork{
        .organization = args.get("org"),
        .name = args.get("fork-name"),
    }));
    try ctx.err.print("✓ Created fork {s}\n", .{f.full_name});
    try ctx.out.print("{s}\n", .{f.html_url});
    const url = cloneUrl(f, t.host.git_protocol) orelse return 0;
    if (args.has("remote")) {
        if (!in_clone) return ctx.fail("--remote works inside a clone of the repository being forked", .{});
        const origin = t.remote orelse "origin";
        if (std.mem.eql(u8, origin, "origin")) {
            try git.run(ctx, &.{ "remote", "rename", "origin", "upstream" });
            try ctx.err.writeAll("✓ Renamed remote origin to upstream\n");
        }
        try git.run(ctx, &.{ "remote", "add", "--", "origin", url });
        try ctx.err.print("✓ Added remote origin for {s}\n", .{f.full_name});
    } else if (args.has("clone")) {
        const dir = try cloneDir(ctx, f.name);
        try git.run(ctx, &.{ "clone", "--", url, dir });
        const parent_url = cloneUrl(try api.decode(types.Repository, ctx, try client.getValue(try t.path(ctx.alloc, "", .{}))), t.host.git_protocol) orelse return 0;
        try git.run(ctx, &.{ "-C", dir, "remote", "add", "-f", "--", "upstream", parent_url });
        try ctx.err.print("✓ Added remote upstream for {s}/{s}\n", .{ t.owner, t.name });
    }
    return 0;
}

fn edit(ctx: *Ctx, args: *const cli.Args) !u8 {
    const t = try target(ctx, args, args.arg(0));
    var client = try t.client(ctx);
    var body: std.json.ObjectMap = .empty;
    const strings = [_][2][]const u8{ .{ "description", "description" }, .{ "homepage", "website" }, .{ "default-branch", "default_branch" }, .{ "merge-style", "default_merge_style" } };
    for (strings) |s| if (args.get(s[0])) |v| try body.put(ctx.alloc, s[1], .{ .string = v });
    if (args.get("visibility")) |v| {
        if (!std.mem.eql(u8, v, "public") and !std.mem.eql(u8, v, "private")) return ctx.fail("--visibility must be public or private", .{});
        try body.put(ctx.alloc, "private", .{ .bool = std.mem.eql(u8, v, "private") });
    }
    if (args.has("delete-branch-on-merge")) try body.put(ctx.alloc, "default_delete_branch_after_merge", .{ .bool = true });
    if (args.has("template")) try body.put(ctx.alloc, "template", .{ .bool = true });
    inline for (toggles) |tg| {
        if (args.has("enable-" ++ tg[0]) and args.has("disable-" ++ tg[0])) return ctx.fail("choose one of --enable-{s} and --disable-{s}", .{ tg[0], tg[0] });
        if (args.has("enable-" ++ tg[0])) try body.put(ctx.alloc, tg[1], .{ .bool = true });
        if (args.has("disable-" ++ tg[0])) try body.put(ctx.alloc, tg[1], .{ .bool = false });
    }
    if (body.count() == 0) return ctx.fail("nothing to change; see `smith repo edit --help`", .{});
    _ = try client.sendValue(.PATCH, try t.path(ctx.alloc, "", .{}), std.json.Value{ .object = body });
    try ctx.err.print("✓ Edited {s}\n", .{try t.fullName(ctx.alloc)});
    return 0;
}

fn sync(ctx: *Ctx, args: *const cli.Args) !u8 {
    const t = try target(ctx, args, args.arg(0));
    var client = try t.client(ctx);
    const info = try api.decode(types.Repository, ctx, try client.getValue(try t.path(ctx.alloc, "", .{})));
    if (info.mirror) {
        _ = try client.call(.POST, try t.path(ctx.alloc, "/mirror-sync", .{}), .{});
        try ctx.err.print("✓ Asked {s} to pull from its source\n", .{info.full_name});
        return 0;
    }
    if (!info.fork) return ctx.fail("{s} is neither a fork nor a mirror; nothing to sync from", .{info.full_name});
    const path = if (args.get("branch")) |b|
        try t.path(ctx.alloc, "/sync_fork/{s}", .{try api.escape(ctx.alloc, b)})
    else
        try t.path(ctx.alloc, "/sync_fork", .{});
    _ = try client.call(.POST, path, .{});
    try ctx.err.print("✓ Synced {s} {s} from {s}\n", .{ info.full_name, args.get("branch") orelse info.default_branch orelse "", if (info.parent) |p| p.full_name else "its parent" });
    return 0;
}

fn setArchived(ctx: *Ctx, args: *const cli.Args, archived: bool) !u8 {
    const t = try target(ctx, args, args.arg(0));
    var client = try t.client(ctx);
    const full = try t.fullName(ctx.alloc);
    const question = try std.fmt.allocPrint(ctx.alloc, "{s} {s}?", .{ if (archived) "Archive" else "Unarchive", full });
    if (!try ctx.confirm(question, args.has("yes"))) return 1;
    _ = try client.sendValue(.PATCH, try t.path(ctx.alloc, "", .{}), .{ .archived = archived });
    try ctx.err.print("✓ {s} {s}\n", .{ if (archived) "Archived" else "Unarchived", full });
    return 0;
}

fn archive(ctx: *Ctx, args: *const cli.Args) !u8 {
    return setArchived(ctx, args, true);
}

fn unarchive(ctx: *Ctx, args: *const cli.Args) !u8 {
    return setArchived(ctx, args, false);
}

fn delete(ctx: *Ctx, args: *const cli.Args) !u8 {
    const t = try target(ctx, args, args.arg(0));
    var client = try t.client(ctx);
    const full = try t.fullName(ctx.alloc);
    if (!args.has("yes")) {
        if (!ctx.interactive()) return ctx.fail("deleting {s} cannot be undone; pass --yes to confirm when not running interactively", .{full});
        const typed = try ctx.prompt(try std.fmt.allocPrint(ctx.alloc, "Type {s} to confirm deletion:", .{full}));
        if (!std.ascii.eqlIgnoreCase(typed, full)) return ctx.fail("names did not match; nothing deleted", .{});
    }
    _ = try client.call(.DELETE, try t.path(ctx.alloc, "", .{}), .{});
    try ctx.err.print("✓ Deleted repository {s}\n", .{full});
    return 0;
}

fn setDefault(ctx: *Ctx, args: *const cli.Args) !u8 {
    const current = try repo.defaultRemote(ctx);
    if (args.has("unset")) {
        if (current) |name| {
            _ = try git.capture(ctx, &.{ "config", "--unset", try std.fmt.allocPrint(ctx.alloc, "remote.{s}.smith-resolved", .{name}) });
            try ctx.err.print("✓ Unset the default repository (was remote {s})\n", .{name});
        }
        return 0;
    }
    if (args.has("view") or args.arg(0) == null) {
        const name = current orelse return ctx.fail("no default repository set; smith picks upstream, then origin", .{});
        for (try git.remotes(ctx)) |r| if (std.mem.eql(u8, r.name, name)) {
            const u = r.parse() orelse break;
            try ctx.out.print("{s}/{s}\n", .{ u.owner, u.repo });
            return 0;
        };
        return ctx.fail("the default remote {s} no longer exists", .{name});
    }
    const spec = repo.parseSpec(args.arg(0).?) orelse return ctx.fail("expected [HOST/]OWNER/REPO, got \"{s}\"", .{args.arg(0).?});
    const chosen = for (try git.remotes(ctx)) |r| {
        const u = r.parse() orelse continue;
        if (std.ascii.eqlIgnoreCase(u.owner, spec.owner) and std.ascii.eqlIgnoreCase(u.repo, spec.name)) break r.name;
    } else return ctx.fail("no remote of this clone points at {s}/{s}", .{ spec.owner, spec.name });
    if (current) |name| _ = try git.capture(ctx, &.{ "config", "--unset", try std.fmt.allocPrint(ctx.alloc, "remote.{s}.smith-resolved", .{name}) });
    _ = try git.capture(ctx, &.{ "config", try std.fmt.allocPrint(ctx.alloc, "remote.{s}.smith-resolved", .{chosen}), "base" });
    try ctx.err.print("✓ Set {s}/{s} (remote {s}) as the default repository\n", .{ spec.owner, spec.name, chosen });
    return 0;
}
