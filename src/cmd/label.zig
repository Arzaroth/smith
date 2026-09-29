const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");
const types = @import("../types.zig");

const color_flag: cli.Flag = .{ .long = "color", .short = 'c', .value = "rrggbb", .help = "Colour as six hex digits" };
const description_flag: cli.Flag = .{ .long = "description", .short = 'd', .value = "string", .help = "Description" };

pub const command: cli.Command = .{
    .name = "label",
    .summary = "Manage labels.",
    .subs = &.{
        .{ .name = "list", .pages = true, .summary = "List a repository's labels.", .flags = &.{ cli.json_flag, cli.repo_flag }, .run = list },
        .{
            .name = "create",
            .summary = "Create a label.",
            .usage = "<name>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ color_flag, description_flag, .{ .long = "exclusive", .help = "Scoped label: only one of its scope per issue" }, cli.repo_flag },
            .run = create,
        },
        .{
            .name = "edit",
            .summary = "Edit a label.",
            .usage = "<name>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ .{ .long = "name", .short = 'n', .value = "string", .help = "Rename it" }, color_flag, description_flag, cli.repo_flag },
            .run = edit,
        },
        .{
            .name = "delete",
            .summary = "Delete a label.",
            .usage = "<name>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ cli.yes_flag, cli.repo_flag },
            .run = delete,
        },
        .{
            .name = "clone",
            .summary = "Copy another repository's labels into this one.",
            .usage = "<source-repository>",
            .min_args = 1,
            .max_args = 1,
            .flags = &.{ .{ .long = "force", .short = 'f', .help = "Update labels that already exist" }, cli.repo_flag },
            .run = clone,
        },
    },
};

fn labels(ctx: *Ctx, client: *api.Client, r: repo.Repo) ![]const types.Label {
    return api.decodeAll(types.Label, ctx, try client.listValues(try r.path(ctx.alloc, "/labels", .{}), 10000, null));
}

fn byName(ctx: *Ctx, client: *api.Client, r: repo.Repo, name: []const u8) !types.Label {
    for (try labels(ctx, client, r)) |l| if (std.ascii.eqlIgnoreCase(l.name, name)) return l;
    return ctx.fail("no label named \"{s}\" in {s}", .{ name, try r.fullName(ctx.alloc) });
}

/// `#rrggbb` from `rrggbb` or `#rrggbb`.
fn color(ctx: *Ctx, c: []const u8) ![]const u8 {
    const hex = std.mem.trimStart(u8, c, "#");
    if (hex.len != 6) return ctx.fail("--color takes six hex digits, got \"{s}\"", .{c});
    for (hex) |ch| if (!std.ascii.isHex(ch)) return ctx.fail("--color takes six hex digits, got \"{s}\"", .{c});
    return std.fmt.allocPrint(ctx.alloc, "#{s}", .{hex});
}

fn list(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const values = try client.listValues(try r.path(ctx.alloc, "/labels", .{}), 10000, null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    var table: term.Table = .{};
    for (try api.decodeAll(types.Label, ctx, values)) |l| try table.add(ctx.alloc, &.{
        .{ .text = l.name, .color = .bold },
        .{ .text = l.description orelse "" },
        .{ .text = l.color orelse "", .color = .dim },
    });
    if (table.rows.items.len == 0) {
        try ctx.err.print("No labels in {s}\n", .{try r.fullName(ctx.alloc)});
        return 0;
    }
    try table.write(ctx);
    return 0;
}

fn create(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const name = args.arg(0).?;
    const Create = struct { name: []const u8, color: []const u8, description: []const u8, exclusive: bool };
    _ = try client.sendValue(.POST, try r.path(ctx.alloc, "/labels", .{}), Create{
        .name = name,
        .color = try color(ctx, args.get("color") orelse randomColor(ctx)),
        .description = args.get("description") orelse "",
        .exclusive = args.has("exclusive"),
    });
    try ctx.err.print("✓ Created label \"{s}\" in {s}\n", .{ name, try r.fullName(ctx.alloc) });
    return 0;
}

fn randomColor(ctx: *Ctx) []const u8 {
    var b: [3]u8 = undefined;
    ctx.io.random(&b);
    return std.fmt.allocPrint(ctx.alloc, "{x}", .{&b}) catch "ededed";
}

fn edit(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const l = try byName(ctx, &client, r, args.arg(0).?);
    const Patch = struct { name: ?[]const u8 = null, color: ?[]const u8 = null, description: ?[]const u8 = null };
    const patch: Patch = .{
        .name = args.get("name"),
        .color = if (args.get("color")) |c| try color(ctx, c) else null,
        .description = args.get("description"),
    };
    _ = try client.sendValue(.PATCH, try r.path(ctx.alloc, "/labels/{d}", .{l.id}), patch);
    try ctx.err.print("✓ Updated label \"{s}\"\n", .{patch.name orelse l.name});
    return 0;
}

fn delete(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    var client = try r.client(ctx);
    const l = try byName(ctx, &client, r, args.arg(0).?);
    if (!try ctx.confirm(try std.fmt.allocPrint(ctx.alloc, "Delete label \"{s}\" from {s}?", .{ l.name, try r.fullName(ctx.alloc) }), args.has("yes"))) return 1;
    _ = try client.call(.DELETE, try r.path(ctx.alloc, "/labels/{d}", .{l.id}), .{});
    try ctx.err.print("✓ Deleted label \"{s}\"\n", .{l.name});
    return 0;
}

fn clone(ctx: *Ctx, args: *const cli.Args) !u8 {
    const r = try repo.resolve(ctx, args);
    const spec = repo.parseSpec(args.arg(0).?) orelse return ctx.fail("expected [HOST/]OWNER/REPO, got \"{s}\"", .{args.arg(0).?});
    const cfg = try @import("../config.zig").load(ctx);
    const source: repo.Repo = .{ .host = try repo.hostFor(ctx, cfg, spec.host orelse r.host.name), .owner = spec.owner, .name = spec.name };
    var from = try source.client(ctx);
    var to = try r.client(ctx);
    const existing = try labels(ctx, &to, r);
    var created: usize = 0;
    var updated: usize = 0;
    for (try labels(ctx, &from, source)) |l| {
        const Body = struct { name: []const u8, color: []const u8, description: []const u8, exclusive: bool };
        const body: Body = .{ .name = l.name, .color = l.color orelse "#ededed", .description = l.description orelse "", .exclusive = l.exclusive };
        const match = for (existing) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, l.name)) break e;
        } else null;
        if (match) |e| {
            if (!args.has("force")) continue;
            _ = try to.sendValue(.PATCH, try r.path(ctx.alloc, "/labels/{d}", .{e.id}), body);
            updated += 1;
        } else {
            _ = try to.sendValue(.POST, try r.path(ctx.alloc, "/labels", .{}), body);
            created += 1;
        }
    }
    try ctx.err.print("✓ Cloned labels from {s}/{s}: {d} created, {d} updated\n", .{ source.owner, source.name, created, updated });
    return 0;
}
