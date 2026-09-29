//! `secret` and `variable`: Forgejo Actions settings for a repository, an
//! organization (`--org`) or the user (`--user`).
const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const config = @import("../config.zig");
const repo = @import("../repo.zig");
const term = @import("../term.zig");

const scope_flags = [_]cli.Flag{
    .{ .long = "org", .short = 'o', .value = "name", .help = "An organization's instead of the repository's" },
    .{ .long = "user", .short = 'u', .help = "Your own instead of the repository's" },
    cli.repo_flag,
};
const body_flag: cli.Flag = .{ .long = "body", .short = 'b', .value = "value", .help = "The value; other local users can see it in the process list, so prefer standard input or the prompt" };

pub const secret_command: cli.Command = .{
    .name = "secret",
    .summary = "Manage Forgejo Actions secrets.",
    .subs = &.{
        .{ .name = "list", .summary = "List secrets (their names; values cannot be read back).", .flags = &(scope_flags ++ [_]cli.Flag{cli.json_flag}), .run = secretList },
        .{ .name = "set", .summary = "Create or replace a secret.", .usage = "<name>", .min_args = 1, .max_args = 1, .flags = &(scope_flags ++ [_]cli.Flag{body_flag}), .run = secretSet },
        .{ .name = "delete", .summary = "Delete a secret.", .usage = "<name>", .min_args = 1, .max_args = 1, .flags = &scope_flags, .run = secretDelete },
    },
};

pub const variable_command: cli.Command = .{
    .name = "variable",
    .summary = "Manage Forgejo Actions variables.",
    .subs = &.{
        .{ .name = "list", .summary = "List variables and their values.", .flags = &(scope_flags ++ [_]cli.Flag{cli.json_flag}), .run = variableList },
        .{ .name = "get", .summary = "Print a variable's value.", .usage = "<name>", .min_args = 1, .max_args = 1, .flags = &scope_flags, .run = variableGet },
        .{ .name = "set", .summary = "Create or update a variable.", .usage = "<name>", .min_args = 1, .max_args = 1, .flags = &(scope_flags ++ [_]cli.Flag{body_flag}), .run = variableSet },
        .{ .name = "delete", .summary = "Delete a variable.", .usage = "<name>", .min_args = 1, .max_args = 1, .flags = &scope_flags, .run = variableDelete },
    },
};

const Scope = struct {
    client: api.Client,
    /// `/repos/o/r/actions`, `/orgs/o/actions` or `/user/actions`.
    base: []const u8,
    label: []const u8,
    user: bool,
};

fn scope(ctx: *Ctx, args: *const cli.Args) !Scope {
    if (args.get("org") != null and args.has("user")) return ctx.fail("choose one of --org and --user", .{});
    if (args.get("org") != null or args.has("user")) {
        const cfg = try config.load(ctx);
        const host = if (args.get("repo")) |r| try repo.hostFor(ctx, cfg, (repo.parseSpec(r) orelse return ctx.fail("expected [HOST/]OWNER/REPO, got \"{s}\"", .{r})).host) else try repo.hostFor(ctx, cfg, null);
        if (args.get("org")) |o| return .{
            .client = try api.Client.init(ctx, host),
            .base = try std.fmt.allocPrint(ctx.alloc, "/orgs/{s}/actions", .{try api.escape(ctx.alloc, o)}),
            .label = try std.fmt.allocPrint(ctx.alloc, "organization {s}", .{o}),
            .user = false,
        };
        return .{ .client = try api.Client.init(ctx, host), .base = "/user/actions", .label = "your account", .user = true };
    }
    const r = try repo.resolve(ctx, args);
    return .{ .client = try r.client(ctx), .base = try r.path(ctx.alloc, "/actions", .{}), .label = try r.fullName(ctx.alloc), .user = false };
}

/// The value from `--body`, stdin, or a prompt without echo on a terminal.
fn value(ctx: *Ctx, args: *const cli.Args, name: []const u8, secret: bool) ![]const u8 {
    if (args.get("body")) |b| return b;
    if (ctx.stdin_tty) {
        const label = try std.fmt.allocPrint(ctx.alloc, "Value for {s}:", .{name});
        return if (secret) ctx.promptSecret(label) else ctx.prompt(label);
    }
    return std.mem.trimEnd(u8, try ctx.readStdin(), "\r\n");
}

fn secretList(ctx: *Ctx, args: *const cli.Args) !u8 {
    var s = try scope(ctx, args);
    if (s.user) return ctx.fail("Forgejo's API cannot list your own secrets, only set and delete them", .{});
    const values = try s.client.listValues(try std.fmt.allocPrint(ctx.alloc, "{s}/secrets", .{s.base}), 1000, null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const Secret = struct { name: []const u8, created_at: ?[]const u8 = null };
    const secrets = try api.decodeAll(Secret, ctx, values);
    if (secrets.len == 0) {
        try ctx.err.print("No secrets in {s}\n", .{s.label});
        return 0;
    }
    var table: term.Table = .{};
    for (secrets) |x| try table.add(ctx.alloc, &.{ .{ .text = x.name, .color = .bold }, .{ .text = try term.when(ctx, x.created_at), .color = .dim } });
    try table.write(ctx);
    return 0;
}

fn secretSet(ctx: *Ctx, args: *const cli.Args) !u8 {
    var s = try scope(ctx, args);
    const name = args.arg(0).?;
    const data = try value(ctx, args, name, true);
    try s.client.sendNoContent(.PUT, try std.fmt.allocPrint(ctx.alloc, "{s}/secrets/{s}", .{ s.base, try api.escape(ctx.alloc, name) }), .{ .data = data });
    try ctx.err.print("✓ Set secret {s} for {s}\n", .{ name, s.label });
    return 0;
}

fn secretDelete(ctx: *Ctx, args: *const cli.Args) !u8 {
    var s = try scope(ctx, args);
    const name = args.arg(0).?;
    _ = try s.client.call(.DELETE, try std.fmt.allocPrint(ctx.alloc, "{s}/secrets/{s}", .{ s.base, try api.escape(ctx.alloc, name) }), .{});
    try ctx.err.print("✓ Deleted secret {s} from {s}\n", .{ name, s.label });
    return 0;
}

const Variable = struct { name: []const u8, data: []const u8 = "" };

fn variableList(ctx: *Ctx, args: *const cli.Args) !u8 {
    var s = try scope(ctx, args);
    const values = try s.client.listValues(try std.fmt.allocPrint(ctx.alloc, "{s}/variables", .{s.base}), 1000, null);
    if (args.has("json")) {
        try api.printJson(ctx, values);
        return 0;
    }
    const vars = try api.decodeAll(Variable, ctx, values);
    if (vars.len == 0) {
        try ctx.err.print("No variables in {s}\n", .{s.label});
        return 0;
    }
    var table: term.Table = .{};
    for (vars) |v| try table.add(ctx.alloc, &.{ .{ .text = v.name, .color = .bold }, .{ .text = v.data } });
    try table.write(ctx);
    return 0;
}

fn variablePath(ctx: *Ctx, s: Scope, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "{s}/variables/{s}", .{ s.base, try api.escape(ctx.alloc, name) });
}

fn variableGet(ctx: *Ctx, args: *const cli.Args) !u8 {
    var s = try scope(ctx, args);
    const v = try api.decode(Variable, ctx, try s.client.getValue(try variablePath(ctx, s, args.arg(0).?)));
    try ctx.out.print("{s}\n", .{v.data});
    return 0;
}

fn variableSet(ctx: *Ctx, args: *const cli.Args) !u8 {
    var s = try scope(ctx, args);
    const name = args.arg(0).?;
    const data = try value(ctx, args, name, false);
    const path = try variablePath(ctx, s, name);
    const body = try std.json.Stringify.valueAlloc(ctx.alloc, .{ .name = name, .value = data }, .{});
    const updated = try s.client.raw(.PUT, path, .{ .body = body });
    if (updated.status == 404) {
        _ = try s.client.call(.POST, path, .{ .body = try std.json.Stringify.valueAlloc(ctx.alloc, .{ .value = data }, .{}) });
        try ctx.err.print("✓ Created variable {s} for {s}\n", .{ name, s.label });
        return 0;
    }
    if (!updated.ok()) return s.client.failStatus(.PUT, path, updated);
    try ctx.err.print("✓ Updated variable {s} for {s}\n", .{ name, s.label });
    return 0;
}

fn variableDelete(ctx: *Ctx, args: *const cli.Args) !u8 {
    var s = try scope(ctx, args);
    const name = args.arg(0).?;
    _ = try s.client.call(.DELETE, try variablePath(ctx, s, name), .{});
    try ctx.err.print("✓ Deleted variable {s} from {s}\n", .{ name, s.label });
    return 0;
}
