const std = @import("std");
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");
const api = @import("../api.zig");
const config = @import("../config.zig");
const repo = @import("../repo.zig");
const git = @import("../git.zig");

pub const command: cli.Command = .{
    .name = "api",
    .summary = "Make an authenticated request to the Forgejo API.",
    .usage = "<endpoint>",
    .min_args = 1,
    .max_args = 1,
    .flags = &.{
        .{ .long = "method", .short = 'X', .value = "string", .help = "HTTP method (default GET, or POST with fields)" },
        .{ .long = "raw-field", .short = 'f', .value = "key=value", .help = "Add a string field" },
        .{ .long = "field", .short = 'F', .value = "key=value", .help = "Add a typed field: true, false, null, numbers, @file" },
        .{ .long = "header", .short = 'H', .value = "key:value", .help = "Add a request header" },
        .{ .long = "input", .value = "file", .help = "Send the file as the request body (\"-\" for standard input)" },
        .{ .long = "paginate", .help = "Fetch every page of a list and print one array" },
        .{ .long = "hostname", .value = "string", .help = "The Forgejo host (default: the current repository's)" },
    },
    .run = run,
};

fn run(ctx: *Ctx, args: *const cli.Args) !u8 {
    var endpoint = args.arg(0).?;
    if (std.mem.indexOf(u8, endpoint, "{owner}") != null or std.mem.indexOf(u8, endpoint, "{repo}") != null) {
        const r = try repo.resolve(ctx, args);
        endpoint = try std.mem.replaceOwned(u8, ctx.alloc, endpoint, "{owner}", r.owner);
        endpoint = try std.mem.replaceOwned(u8, ctx.alloc, endpoint, "{repo}", r.name);
    }
    if (std.mem.startsWith(u8, endpoint, "/api/v1")) endpoint = endpoint["/api/v1".len..];
    if (!std.mem.startsWith(u8, endpoint, "/")) endpoint = try std.fmt.allocPrint(ctx.alloc, "/{s}", .{endpoint});

    var client = try api.Client.init(ctx, try host(ctx, args));

    var headers: std.ArrayList(std.http.Header) = .empty;
    for (args.names, args.values) |n, v| {
        if (!std.mem.eql(u8, n, "header")) continue;
        const colon = std.mem.indexOfScalar(u8, v, ':') orelse return ctx.fail("invalid header \"{s}\"; expected key:value", .{v});
        try headers.append(ctx.alloc, .{ .name = std.mem.trim(u8, v[0..colon], " "), .value = std.mem.trim(u8, v[colon + 1 ..], " ") });
    }

    var fields: std.json.ObjectMap = .empty;
    var query: std.ArrayList(u8) = .empty;
    for (args.names, args.values) |n, v| {
        const typed = std.mem.eql(u8, n, "field");
        if (!typed and !std.mem.eql(u8, n, "raw-field")) continue;
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse return ctx.fail("invalid field \"{s}\"; expected key=value", .{v});
        const key = v[0..eq];
        const value = v[eq + 1 ..];
        try fields.put(ctx.alloc, key, if (typed) try typedValue(ctx, value) else .{ .string = value });
        try query.print(ctx.alloc, "{s}{s}={s}", .{ if (query.items.len == 0) "" else "&", try api.escape(ctx.alloc, key), try api.escape(ctx.alloc, value) });
    }

    const input: ?[]const u8 = if (args.get("input")) |path|
        if (std.mem.eql(u8, path, "-")) try ctx.readStdin() else std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e|
            return ctx.fail("cannot read {s}: {t}", .{ path, e })
    else
        null;

    const method_name = args.get("method") orelse if (fields.count() > 0 or input != null) "POST" else "GET";
    var upper_buf: [16]u8 = undefined;
    if (method_name.len > upper_buf.len) return ctx.fail("unknown method {s}", .{method_name});
    const method = std.meta.stringToEnum(std.http.Method, std.ascii.upperString(&upper_buf, method_name)) orelse
        return ctx.fail("unknown method {s}", .{method_name});

    var body: ?[]const u8 = input;
    if (method == .GET or method == .HEAD or method == .DELETE) {
        if (query.items.len > 0) {
            const sep: u8 = if (std.mem.indexOfScalar(u8, endpoint, '?') != null) '&' else '?';
            endpoint = try std.fmt.allocPrint(ctx.alloc, "{s}{c}{s}", .{ endpoint, sep, query.items });
        }
    } else if (body == null and fields.count() > 0) {
        body = try std.json.Stringify.valueAlloc(ctx.alloc, std.json.Value{ .object = fields }, .{});
    }

    if (args.has("paginate") and method == .GET) {
        const items = try client.listValues(endpoint, std.math.maxInt(u32), null);
        try api.printJson(ctx, items);
        return 0;
    }

    const resp = try client.raw(method, endpoint, .{ .body = body, .extra_headers = headers.items });
    try writeBody(ctx, resp.body);
    if (!resp.ok()) {
        try ctx.err.print("smith: HTTP {d}\n", .{resp.status});
        return 1;
    }
    return 0;
}

fn host(ctx: *Ctx, args: *const cli.Args) !config.Host {
    const cfg = try config.load(ctx);
    if (args.get("hostname")) |h| return repo.hostFor(ctx, cfg, h);
    if (try inRepo(ctx)) {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        const saved = ctx.err;
        ctx.err = &discard.writer;
        defer ctx.err = saved;
        if (repo.resolve(ctx, args)) |r| return r.host else |_| {}
    }
    return repo.hostFor(ctx, cfg, null);
}

fn inRepo(ctx: *Ctx) !bool {
    return (try git.remotes(ctx)).len > 0;
}

fn typedValue(ctx: *Ctx, s: []const u8) !std.json.Value {
    if (std.mem.eql(u8, s, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, s, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, s, "null")) return .null;
    if (std.fmt.parseInt(i64, s, 10)) |n| return .{ .integer = n } else |_| {}
    if (std.mem.startsWith(u8, s, "@")) {
        const path = s[1..];
        const data = if (std.mem.eql(u8, path, "-")) try ctx.readStdin() else std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e|
            return ctx.fail("cannot read {s}: {t}", .{ path, e });
        return .{ .string = data };
    }
    return .{ .string = s };
}

/// JSON is pretty-printed on a terminal; anything else is written as sent.
fn writeBody(ctx: *Ctx, body: []const u8) !void {
    if (body.len == 0) return;
    if (ctx.stdout_tty) {
        if (std.json.parseFromSliceLeaky(std.json.Value, ctx.alloc, body, .{})) |v| {
            try api.printJson(ctx, v);
            return;
        } else |_| {}
    }
    try ctx.out.writeAll(body);
    if (body[body.len - 1] != '\n' and ctx.stdout_tty) try ctx.out.writeByte('\n');
}
