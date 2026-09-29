//! Forgejo REST client over std.http: token auth, JSON in and out, API error
//! bodies turned into messages, page/limit pagination.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const Ctx = @import("Ctx.zig");
const Host = @import("config.zig").Host;

pub const Client = struct {
    ctx: *Ctx,
    host: Host,
    base: []const u8,

    pub fn init(ctx: *Ctx, host: Host) !Client {
        return .{ .ctx = ctx, .host = host, .base = try host.apiBase(ctx.alloc) };
    }

    pub const Response = struct {
        status: u16,
        body: []const u8,

        pub fn ok(r: Response) bool {
            return r.status >= 200 and r.status < 300;
        }
    };

    pub const Method = std.http.Method;

    pub const RequestOptions = struct {
        body: ?[]const u8 = null,
        accept: []const u8 = "application/json",
        content_type: []const u8 = "application/json",
        extra_headers: []const std.http.Header = &.{},
    };

    /// Sends a request and returns whatever came back, error statuses included.
    /// `path` is relative to `/api/v1` unless it is an absolute URL.
    pub fn raw(c: *Client, method: Method, path: []const u8, opts: RequestOptions) !Response {
        const ctx = c.ctx;
        const url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
            path
        else
            try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ c.base, path });
        const uri = std.Uri.parse(url) catch return ctx.fail("invalid URL: {s}", .{url});

        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(ctx.alloc, .{ .name = "accept", .value = opts.accept });
        try headers.appendSlice(ctx.alloc, opts.extra_headers);
        var privileged: []const std.http.Header = &.{};
        if (c.host.token) |t| {
            const auth = try std.fmt.allocPrint(ctx.alloc, "token {s}", .{t});
            privileged = try ctx.alloc.dupe(std.http.Header, &.{.{ .name = "authorization", .value = auth }});
        }

        var req = ctx.http.request(method, uri, .{
            .headers = .{
                .user_agent = .{ .override = "smith" },
                .content_type = if (opts.body != null) .{ .override = opts.content_type } else .default,
            },
            .extra_headers = headers.items,
            .privileged_headers = privileged,
            .redirect_behavior = if (opts.body == null) @enumFromInt(3) else .unhandled,
        }) catch |e| return ctx.fail("cannot reach {s}: {t}", .{ c.host.name, e });
        defer req.deinit();

        send(&req, opts.body) catch |e| return ctx.fail("cannot reach {s}: {t}", .{ c.host.name, e });

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |e| return ctx.fail("no response from {s}: {t}", .{ c.host.name, e });

        var body: Io.Writer.Allocating = .init(ctx.alloc);
        var transfer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const decompress_buf = try ctx.alloc.alloc(u8, switch (response.head.content_encoding) {
            .identity => 0,
            .zstd => std.compress.zstd.default_window_len,
            else => std.compress.flate.max_window_len,
        });
        const reader = response.readerDecompressing(&transfer, &decompress, decompress_buf);
        _ = reader.streamRemaining(&body.writer) catch |e| switch (e) {
            error.ReadFailed => return ctx.fail("reading the response from {s} failed: {t}", .{ c.host.name, response.bodyErr().? }),
            else => |x| return x,
        };
        return .{ .status = @intFromEnum(response.head.status), .body = body.written() };
    }

    fn send(req: *std.http.Client.Request, body: ?[]const u8) !void {
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            var bw = try req.sendBodyUnflushed(&.{});
            try bw.writer.writeAll(b);
            try bw.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
    }

    /// Like `raw`, but an error status becomes a reported failure.
    pub fn call(c: *Client, method: Method, path: []const u8, opts: RequestOptions) !Response {
        const r = try c.raw(method, path, opts);
        if (!r.ok()) return c.failStatus(method, path, r);
        return r;
    }

    pub fn failStatus(c: *Client, method: Method, path: []const u8, r: Response) Ctx.Error {
        const ctx = c.ctx;
        const message = errorMessage(ctx.alloc, r.body);
        switch (r.status) {
            401 => return ctx.fail("authentication failed for {s} ({s}); run `smith auth login --hostname {s}`", .{ c.host.name, message orelse "HTTP 401", c.host.name }),
            else => {},
        }
        if (message) |m| return ctx.fail("{s} (HTTP {d}, {t} {s})", .{ m, r.status, method, path });
        return ctx.fail("HTTP {d} from {t} {s}", .{ r.status, method, path });
    }

    pub fn getValue(c: *Client, path: []const u8) !json.Value {
        const r = try c.call(.GET, path, .{});
        return c.parseValue(r.body);
    }

    pub fn sendValue(c: *Client, method: Method, path: []const u8, payload: anytype) !json.Value {
        const body = try json.Stringify.valueAlloc(c.ctx.alloc, payload, .{ .emit_null_optional_fields = false });
        const r = try c.call(method, path, .{ .body = body });
        if (r.body.len == 0) return .null;
        return c.parseValue(r.body);
    }

    pub fn sendNoContent(c: *Client, method: Method, path: []const u8, payload: anytype) !void {
        const body = try json.Stringify.valueAlloc(c.ctx.alloc, payload, .{ .emit_null_optional_fields = false });
        _ = try c.call(method, path, .{ .body = body });
    }

    pub fn parseValue(c: *Client, body: []const u8) !json.Value {
        return json.parseFromSliceLeaky(json.Value, c.ctx.alloc, body, .{}) catch
            c.ctx.fail("{s} answered with something that is not JSON", .{c.host.name});
    }

    /// Fetches up to `limit` items across pages. `field` names the array when
    /// the endpoint wraps it in an object (e.g. `workflow_runs`).
    pub fn listValues(c: *Client, path: []const u8, limit: u32, field: ?[]const u8) ![]json.Value {
        const ctx = c.ctx;
        var items: std.ArrayList(json.Value) = .empty;
        const page_size: u32 = @min(limit, 50);
        const sep: u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) '&' else '?';
        var page: u32 = 1;
        while (items.items.len < limit) : (page += 1) {
            const p = try std.fmt.allocPrint(ctx.alloc, "{s}{c}page={d}&limit={d}", .{ path, sep, page, page_size });
            const v = try c.getValue(p);
            const arr = switch (if (field) |f| (if (v == .object) v.object.get(f) orelse .null else .null) else v) {
                .array => |a| a.items,
                .null => &.{},
                else => return ctx.fail("unexpected response shape from {s}", .{p}),
            };
            for (arr) |item| {
                if (items.items.len >= limit) break;
                try items.append(ctx.alloc, item);
            }
            if (arr.len < page_size) break;
        }
        return items.toOwnedSlice(ctx.alloc);
    }
};

pub fn errorMessage(alloc: Allocator, body: []const u8) ?[]const u8 {
    const v = json.parseFromSliceLeaky(json.Value, alloc, body, .{}) catch return null;
    if (v != .object) return null;
    const m = v.object.get("message") orelse return null;
    if (m != .string or m.string.len == 0) return null;
    return m.string;
}

/// Decodes a JSON value into `T`, ignoring fields `T` does not declare.
pub fn decode(comptime T: type, ctx: *Ctx, v: json.Value) !T {
    return json.parseFromValueLeaky(T, ctx.alloc, v, .{ .ignore_unknown_fields = true }) catch |e|
        ctx.fail("unexpected {s} from the API: {t}", .{ @typeName(T), e });
}

pub fn decodeAll(comptime T: type, ctx: *Ctx, vs: []const json.Value) ![]T {
    const out = try ctx.alloc.alloc(T, vs.len);
    for (vs, out) |v, *o| o.* = try decode(T, ctx, v);
    return out;
}

pub fn printJson(ctx: *Ctx, v: anytype) !void {
    try json.Stringify.value(v, .{ .whitespace = .indent_2 }, ctx.out);
    try ctx.out.writeByte('\n');
}

/// Percent-encodes a query or path component.
pub fn escape(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(alloc, ch);
        } else {
            try out.print(alloc, "%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "errorMessage reads Forgejo's message field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("not found", errorMessage(a, "{\"message\":\"not found\",\"url\":\"x\"}").?);
    try testing.expect(errorMessage(a, "<html>") == null);
    try testing.expect(errorMessage(a, "{\"message\":\"\"}") == null);
}

test "escape keeps unreserved characters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("feat%2Fx%20y", try escape(arena.allocator(), "feat/x y"));
}
