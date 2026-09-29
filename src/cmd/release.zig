const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");
const common = @import("common.zig");

const notes_flag: cli.Flag = .{ .long = "notes", .short = 'n', .value = "string", .help = "Release notes" };
const notes_file_flag: cli.Flag = .{ .long = "notes-file", .short = 'F', .value = "file", .help = "Read the release notes from a file (\"-\" for standard input)" };
const clobber_flag: cli.Flag = .{ .long = "clobber", .help = "Replace assets or files of the same name" };

pub const command: cli.Command = .{
    .name = "release",
    .summary = "Manage releases.",
    .subs = &.{
        .{
            .name = "list",
            .summary = "List releases in a repository.",
            .flags = &.{ cli.limit_flag, cli.json_flag, cli.repo_flag },
            .run = list,
        },
        .{
            .name = "view",
            .summary = "Show a release; without a tag, the latest one.",
            .usage = "[<tag>]",
            .max_args = 1,
            .flags = &.{ cli.web_flag, cli.json_flag, cli.repo_flag },
            .run = view,
        },
        .{
            .name = "create",
            .summary = "Create a release, uploading any files given as assets.",
            .usage = "<tag> [<files>...]",
            .min_args = 1,
            .max_args = 1000,
            .flags = &.{
                .{ .long = "title", .short = 't', .value = "string", .help = "Release title (default: the tag)" },
                notes_flag,
                notes_file_flag,
                .{ .long = "target", .value = "branch", .help = "Branch or commit to tag when the tag does not exist yet" },
                .{ .long = "draft", .short = 'd', .help = "Save as a draft" },
                .{ .long = "prerelease", .short = 'p', .help = "Mark as a pre-release" },
                cli.repo_flag,
            },
            .run = create,
        },
        .{
            .name = "edit",
            .summary = "Edit a release.",
            .usage = "<tag>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{
                .{ .long = "title", .short = 't', .value = "string", .help = "Release title" },
                notes_flag,
                notes_file_flag,
                .{ .long = "tag", .value = "string", .help = "Move the release to another tag" },
                .{ .long = "draft", .help = "Make it a draft" },
                .{ .long = "publish", .help = "Publish a draft" },
                .{ .long = "prerelease", .help = "Mark as a pre-release" },
                .{ .long = "latest", .help = "Mark as a full release, not a pre-release (Forgejo shows the newest as latest)" },
                cli.repo_flag,
            },
            .run = edit,
        },
        .{
            .name = "upload",
            .summary = "Upload assets to a release.",
            .usage = "<tag> <files>...",
            .min_args = 2,
            .max_args = 1000,
            .flags = &.{ clobber_flag, cli.repo_flag },
            .run = upload,
        },
        .{
            .name = "download",
            .summary = "Download a release's assets; without a tag, the latest release's.",
            .usage = "[<tag>]",
            .max_args = 1,
            .flags = &.{
                .{ .long = "pattern", .short = 'p', .value = "glob", .help = "Only assets matching the pattern (repeatable)" },
                .{ .long = "dir", .short = 'D', .value = "directory", .help = "Where to write the files (default: here)" },
                clobber_flag,
                cli.repo_flag,
            },
            .run = download,
        },
        .{
            .name = "delete",
            .summary = "Delete a release.",
            .usage = "<tag>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ .{ .long = "cleanup-tag", .help = "Delete the tag too" }, cli.yes_flag, cli.repo_flag },
            .run = delete,
        },
        .{
            .name = "delete-asset",
            .summary = "Delete an asset from a release.",
            .usage = "<tag> <asset-name>",
            .min_args = 2,
            .max_args = 2,
            .flags = &.{ cli.yes_flag, cli.repo_flag },
            .run = deleteAsset,
        },
    },
};

const Found = struct { release: types.Release, value: std.json.Value };

fn find(ctx: *Ctx, client: *api.Client, r: repo.Repo, tag: ?[]const u8) !Found {
    const path = if (tag) |t|
        try r.path(ctx.alloc, "/releases/tags/{s}", .{try api.escape(ctx.alloc, t)})
    else
        try r.path(ctx.alloc, "/releases/latest", .{});
    const resp = try client.raw(.GET, path, .{});
    if (resp.status == 404) {
        if (tag) |t| return ctx.fail("no release for tag {s} in {s}", .{ t, try r.fullName(ctx.alloc) });
        return ctx.fail("{s} has no releases", .{try r.fullName(ctx.alloc)});
    }
    if (!resp.ok()) return client.failStatus(.GET, path, resp);
    const v = try client.parseValue(resp.body);
    return .{ .release = try api.decode(types.Release, ctx, v), .value = v };
}

fn kind(rel: types.Release) []const u8 {
    if (rel.draft) return "Draft";
    if (rel.prerelease) return "Pre-release";
    return "";
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const values = try client.listValues(try r.path(ctx.alloc, "/releases", .{}), try args.int("limit", 30), null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const releases = try api.decodeAll(types.Release, ctx, values);
    if (releases.len == 0) {
        try ctx.err.print("No releases in {s}\n", .{try r.fullName(ctx.alloc)});
        return 0;
    }
    var latest_marked = false;
    var table: term.Table = .{};
    for (releases) |rel| {
        var label = kind(rel);
        if (label.len == 0 and !latest_marked) {
            label = "Latest";
            latest_marked = true;
        }
        try table.add(ctx.alloc, &.{
            .{ .text = rel.name orelse rel.tag_name, .color = .bold },
            .{ .text = label, .color = if (std.mem.eql(u8, label, "Latest")) .green else .yellow },
            .{ .text = rel.tag_name, .color = .cyan },
            .{ .text = try term.when(ctx, rel.published_at orelse rel.created_at), .color = .dim },
        });
    }
    try table.write(ctx);
    return 0;
}

fn view(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const f = try find(ctx, &client, r, args.arg(0));
    const rel = f.release;
    if (args.has("web")) {
        try ctx.openBrowser(rel.html_url);
        return 0;
    }
    if (args.has("json")) {
        try api.printJson(ctx, f.value);
        return 0;
    }
    const w = ctx.out;
    try term.paint(ctx, w, .bold, rel.name orelse rel.tag_name);
    try w.writeByte('\n');
    if (kind(rel).len > 0) {
        try term.paint(ctx, w, .yellow, kind(rel));
        try w.writeAll(" · ");
    }
    try w.print("{s} released this {s} · tag {s}\n\n", .{
        if (rel.author) |a| a.login else "ghost",
        try term.ago(ctx.alloc, ctx.now, rel.published_at orelse rel.created_at),
        rel.tag_name,
    });
    try common.writeBody(ctx, rel.body);
    const assets = rel.assets orelse &.{};
    if (assets.len > 0) {
        try w.writeAll("\nASSETS\n");
        var table: term.Table = .{};
        for (assets) |a| try table.add(ctx.alloc, &.{
            .{ .text = a.name },
            .{ .text = try term.size(ctx.alloc, a.size), .color = .dim },
            .{ .text = try std.fmt.allocPrint(ctx.alloc, "{d} downloads", .{a.download_count}), .color = .dim },
        });
        try table.write(ctx);
    }
    try w.writeByte('\n');
    try term.paint(ctx, w, .dim, try std.fmt.allocPrint(ctx.alloc, "View on Forgejo: {s}", .{rel.html_url}));
    try w.writeByte('\n');
    return 0;
}

fn notes(ctx: *Ctx, args: *const cli.Args) !?[]const u8 {
    if (args.get("notes")) |n| return n;
    const path = args.get("notes-file") orelse return null;
    if (std.mem.eql(u8, path, "-")) return try ctx.readStdin();
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(16 * 1024 * 1024)) catch |e|
        ctx.fail("cannot read {s}: {t}", .{ path, e });
}

fn create(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const tag = args.arg(0).?;
    const files = args.positionals[1..];
    for (files) |path| {
        Io.Dir.cwd().access(ctx.io, path, .{}) catch return ctx.fail("cannot read {s}", .{path});
    }
    const Create = struct {
        tag_name: []const u8,
        name: []const u8,
        body: []const u8,
        draft: bool,
        prerelease: bool,
        target_commitish: ?[]const u8 = null,
    };
    const v = try client.sendValue(.POST, try r.path(ctx.alloc, "/releases", .{}), Create{
        .tag_name = tag,
        .name = args.get("title") orelse tag,
        .body = try notes(ctx, args) orelse "",
        .draft = args.has("draft"),
        .prerelease = args.has("prerelease"),
        .target_commitish = args.get("target"),
    });
    const rel = try api.decode(types.Release, ctx, v);
    for (files) |path| try uploadFile(ctx, &client, r, rel, path, false);
    try ctx.out.print("{s}\n", .{rel.html_url});
    return 0;
}

fn uploadFile(ctx: *Ctx, client: *api.Client, r: repo.Repo, rel: types.Release, path: []const u8, clobber: bool) !void {
    const name = std.fs.path.basename(path);
    var file = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |e| return ctx.fail("cannot read {s}: {t}", .{ path, e });
    defer file.close(ctx.io);
    const size = (file.stat(ctx.io) catch |e| return ctx.fail("cannot read {s}: {t}", .{ path, e })).size;
    for (rel.assets orelse &.{}) |a| if (std.mem.eql(u8, a.name, name)) {
        if (!clobber) return ctx.fail("{s} already has an asset named {s}; pass --clobber to replace it", .{ rel.tag_name, name });
        _ = try client.call(.DELETE, try r.path(ctx.alloc, "/releases/{d}/assets/{d}", .{ rel.id, a.id }), .{});
    };
    _ = try client.uploadFile(try r.path(ctx.alloc, "/releases/{d}/assets?name={s}", .{ rel.id, try api.escape(ctx.alloc, name) }), name, file, size);
    try ctx.err.print("✓ Uploaded {s} ({s})\n", .{ name, try term.size(ctx.alloc, @intCast(size)) });
}

fn upload(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const rel = (try find(ctx, &client, r, args.arg(0).?)).release;
    for (args.positionals[1..]) |path| try uploadFile(ctx, &client, r, rel, path, args.has("clobber"));
    return 0;
}

fn download(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const rel = (try find(ctx, &client, r, args.arg(0))).release;
    const patterns = try args.all(ctx.alloc, "pattern");
    const dir = args.get("dir") orelse ".";
    Io.Dir.cwd().createDirPath(ctx.io, dir) catch |e| return ctx.fail("cannot create {s}: {t}", .{ dir, e });
    var count: usize = 0;
    for (rel.assets orelse &.{}) |a| {
        if (patterns.len > 0) {
            for (patterns) |p| {
                if (term.glob(p, a.name)) break;
            } else continue;
        }
        const target = try std.fs.path.join(ctx.alloc, &.{ dir, try common.fileName(ctx, a.name) });
        const size = try client.download(a.browser_download_url, target, args.has("clobber"));
        try ctx.err.print("✓ Downloaded {s} ({s})\n", .{ target, try term.size(ctx.alloc, @intCast(size)) });
        count += 1;
    }
    if (count == 0) return ctx.fail("no assets to download in {s}", .{rel.tag_name});
    return 0;
}

fn edit(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const rel = (try find(ctx, &client, r, args.arg(0).?)).release;
    const Patch = struct {
        name: ?[]const u8 = null,
        body: ?[]const u8 = null,
        tag_name: ?[]const u8 = null,
        draft: ?bool = null,
        prerelease: ?bool = null,
    };
    if (args.has("draft") and args.has("publish")) return ctx.fail("choose one of --draft and --publish", .{});
    if (args.has("prerelease") and args.has("latest")) return ctx.fail("choose one of --prerelease and --latest", .{});
    const patch: Patch = .{
        .name = args.get("title"),
        .body = try notes(ctx, args),
        .tag_name = args.get("tag"),
        .draft = if (args.has("draft")) true else if (args.has("publish")) false else null,
        .prerelease = if (args.has("prerelease")) true else if (args.has("latest")) false else null,
    };
    const v = try client.sendValue(.PATCH, try r.path(ctx.alloc, "/releases/{d}", .{rel.id}), patch);
    try ctx.out.print("{s}\n", .{(try api.decode(types.Release, ctx, v)).html_url});
    return 0;
}

fn delete(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const tag = args.arg(0).?;
    const rel = (try find(ctx, &client, r, tag)).release;
    const question = try std.fmt.allocPrint(ctx.alloc, "Delete release {s} in {s}?", .{ tag, try r.fullName(ctx.alloc) });
    if (!try ctx.confirm(question, args.has("yes"))) return 1;
    _ = try client.call(.DELETE, try r.path(ctx.alloc, "/releases/{d}", .{rel.id}), .{});
    try ctx.err.print("✓ Deleted release {s}\n", .{tag});
    if (args.has("cleanup-tag")) {
        _ = try client.call(.DELETE, try r.path(ctx.alloc, "/tags/{s}", .{try api.escape(ctx.alloc, tag)}), .{});
        try ctx.err.print("✓ Deleted tag {s}\n", .{tag});
    }
    return 0;
}

fn deleteAsset(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const rel = (try find(ctx, &client, r, args.arg(0).?)).release;
    const name = args.arg(1).?;
    const asset = for (rel.assets orelse &.{}) |a| {
        if (std.mem.eql(u8, a.name, name)) break a;
    } else return ctx.fail("release {s} has no asset named {s}", .{ rel.tag_name, name });
    if (!try ctx.confirm(try std.fmt.allocPrint(ctx.alloc, "Delete {s} from release {s}?", .{ name, rel.tag_name }), args.has("yes"))) return 1;
    _ = try client.call(.DELETE, try r.path(ctx.alloc, "/releases/{d}/assets/{d}", .{ rel.id, asset.id }), .{});
    try ctx.err.print("✓ Deleted {s} from {s}\n", .{ name, rel.tag_name });
    return 0;
}
