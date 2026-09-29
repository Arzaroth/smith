//! `ssh-key`, `gpg-key` and `org`: the account's keys and organizations.
const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const term = @import("../term.zig");
const search = @import("search.zig");

const hostname_flag: cli.Flag = .{ .long = "hostname", .value = "string", .help = "The Forgejo host (default: the default host)" };

pub const ssh_command: cli.Command = .{
    .name = "ssh-key",
    .summary = "Manage the SSH keys of your account.",
    .subs = &.{
        .{ .name = "list", .pages = true, .summary = "List your SSH keys.", .flags = &.{ cli.json_flag, hostname_flag }, .run = sshList },
        .{
            .name = "add",
            .summary = "Add an SSH public key (a file, or standard input).",
            .usage = "[<key-file>]",
            .max_args = 1,
            .flags = &.{ .{ .long = "title", .short = 't', .value = "string", .help = "Title (default: the key's comment)" }, .{ .long = "read-only", .help = "Deploy-style key without write access" }, hostname_flag },
            .run = sshAdd,
        },
        .{ .name = "delete", .summary = "Delete an SSH key.", .usage = "<id>", .min_args = 1, .max_args = 1, .flags = &.{ cli.yes_flag, hostname_flag }, .run = sshDelete },
    },
};

pub const gpg_command: cli.Command = .{
    .name = "gpg-key",
    .summary = "Manage the GPG keys of your account.",
    .subs = &.{
        .{ .name = "list", .pages = true, .summary = "List your GPG keys.", .flags = &.{ cli.json_flag, hostname_flag }, .run = gpgList },
        .{ .name = "add", .summary = "Add an armored GPG public key (a file, or standard input).", .usage = "[<key-file>]", .max_args = 1, .flags = &.{hostname_flag}, .run = gpgAdd },
        .{ .name = "delete", .summary = "Delete a GPG key.", .usage = "<id>", .min_args = 1, .max_args = 1, .flags = &.{ cli.yes_flag, hostname_flag }, .run = gpgDelete },
    },
};

pub const org_command: cli.Command = .{
    .name = "org",
    .summary = "List organizations.",
    .subs = &.{
        .{ .name = "list", .pages = true, .summary = "List your organizations, or a user's.", .usage = "[<user>]", .max_args = 1, .flags = &.{ cli.limit_flag, cli.json_flag, hostname_flag }, .run = orgList },
    },
};

fn keyText(ctx: *Ctx, args: *const cli.Args) ![]const u8 {
    const text = if (args.arg(0)) |path|
        Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(1024 * 1024)) catch |e| return ctx.fail("cannot read {s}: {t}", .{ path, e })
    else
        try ctx.readStdin();
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return ctx.fail("no key given", .{});
    return trimmed;
}

const SshKey = struct { id: i64, title: []const u8 = "", key: []const u8 = "", fingerprint: ?[]const u8 = null, read_only: bool = false, created_at: ?[]const u8 = null };

fn sshList(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    const values = try c.listValues("/user/keys", 1000, null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    var table: term.Table = .{};
    for (try api.decodeAll(SshKey, ctx, values)) |k| try table.add(ctx.alloc, &.{
        .{ .text = try std.fmt.allocPrint(ctx.alloc, "{d}", .{k.id}), .color = .dim },
        .{ .text = k.title, .color = .bold },
        .{ .text = k.fingerprint orelse "" },
        .{ .text = if (k.read_only) "read-only" else "", .color = .dim },
        .{ .text = try term.when(ctx, k.created_at), .color = .dim },
    });
    if (table.rows.items.len == 0) {
        try ctx.err.writeAll("No SSH keys\n");
        return 0;
    }
    try table.write(ctx);
    return 0;
}

fn sshAdd(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    const key = try keyText(ctx, args);
    var fields = std.mem.tokenizeAny(u8, key, " \t");
    _ = fields.next();
    _ = fields.next();
    const comment = fields.rest();
    const title = args.get("title") orelse if (comment.len > 0) comment else "smith";
    const added = try api.decode(SshKey, ctx, try c.sendValue(.POST, "/user/keys", .{ .key = key, .title = title, .read_only = args.has("read-only") }));
    try ctx.err.print("✓ Added SSH key \"{s}\" (id {d})\n", .{ added.title, added.id });
    return 0;
}

fn deleteKey(ctx: *Ctx, args: *const cli.Args, comptime kind: []const u8, comptime path: []const u8) !u8 {
    var c = try search.client(ctx, args);
    const id = args.arg(0).?;
    _ = std.fmt.parseInt(i64, id, 10) catch return ctx.fail("invalid key id: {s}", .{id});
    if (!try ctx.confirm(try std.fmt.allocPrint(ctx.alloc, "Delete " ++ kind ++ " key {s}?", .{id}), args.has("yes"))) return 1;
    _ = try c.call(.DELETE, try std.fmt.allocPrint(ctx.alloc, path ++ "/{s}", .{id}), .{});
    try ctx.err.print("✓ Deleted " ++ kind ++ " key {s}\n", .{id});
    return 0;
}

fn sshDelete(ctx: *Ctx, args: *const cli.Args) !u8 {
    return deleteKey(ctx, args, "SSH", "/user/keys");
}

const GpgKey = struct { id: i64, key_id: []const u8 = "", emails: ?[]const struct { email: []const u8 } = null, created_at: ?[]const u8 = null, expires_at: ?[]const u8 = null };

fn gpgList(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    const values = try c.listValues("/user/gpg_keys", 1000, null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    var table: term.Table = .{};
    for (try api.decodeAll(GpgKey, ctx, values)) |k| {
        var emails: std.ArrayList([]const u8) = .empty;
        for (k.emails orelse &.{}) |e| try emails.append(ctx.alloc, e.email);
        try table.add(ctx.alloc, &.{
            .{ .text = try std.fmt.allocPrint(ctx.alloc, "{d}", .{k.id}), .color = .dim },
            .{ .text = k.key_id, .color = .bold },
            .{ .text = try std.mem.join(ctx.alloc, ", ", emails.items) },
            .{ .text = try term.when(ctx, k.created_at), .color = .dim },
        });
    }
    if (table.rows.items.len == 0) {
        try ctx.err.writeAll("No GPG keys\n");
        return 0;
    }
    try table.write(ctx);
    return 0;
}

fn gpgAdd(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    const added = try api.decode(GpgKey, ctx, try c.sendValue(.POST, "/user/gpg_keys", .{ .armored_public_key = try keyText(ctx, args) }));
    try ctx.err.print("✓ Added GPG key {s} (id {d})\n", .{ added.key_id, added.id });
    return 0;
}

fn gpgDelete(ctx: *Ctx, args: *const cli.Args) !u8 {
    return deleteKey(ctx, args, "GPG", "/user/gpg_keys");
}

fn orgList(ctx: *Ctx, args: *const cli.Args) !u8 {
    var c = try search.client(ctx, args);
    const path = if (args.arg(0)) |u| try std.fmt.allocPrint(ctx.alloc, "/users/{s}/orgs", .{try api.escape(ctx.alloc, u)}) else "/user/orgs";
    const values = try c.listValues(path, try args.int("limit", 30), null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const Org = struct { name: []const u8 = "", username: []const u8 = "", full_name: ?[]const u8 = null, description: ?[]const u8 = null, visibility: ?[]const u8 = null };
    var table: term.Table = .{};
    for (try api.decodeAll(Org, ctx, values)) |o| try table.add(ctx.alloc, &.{
        .{ .text = if (o.username.len > 0) o.username else o.name, .color = .bold },
        .{ .text = try term.fit(ctx, o.description orelse o.full_name orelse "", 50) },
        .{ .text = o.visibility orelse "", .color = .dim },
    });
    if (table.rows.items.len == 0) {
        try ctx.err.writeAll("No organizations\n");
        return 0;
    }
    try table.write(ctx);
    return 0;
}
