//! Forgejo REST client over std.http: token auth, JSON in and out, API error
//! bodies turned into messages, page/limit pagination.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const Ctx = @import("Ctx.zig");
const config = @import("config.zig");
const Host = config.Host;
const oauth = @import("oauth.zig");

pub const Client = struct {
    ctx: *Ctx,
    host: Host,
    base: []const u8,

    /// A client for `host`, renewing a browser login's access token first
    /// when it is about to expire.
    pub fn init(ctx: *Ctx, host: Host) !Client {
        const h = try oauth.refreshIfDue(ctx, host);
        return .{ .ctx = ctx, .host = h, .base = try h.apiBase(ctx.alloc) };
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
        /// Replaces the host's token as the authorization header; `""` sends none.
        authorization: ?[]const u8 = null,
    };

    /// Sends a request and returns whatever came back, error statuses included.
    /// `path` is relative to `/api/v1` unless it is an absolute URL.
    pub fn raw(c: *Client, method: Method, path: []const u8, opts: RequestOptions) !Response {
        const ctx = c.ctx;
        const url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
            path
        else
            try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ c.base, path });
        var uri = std.Uri.parse(url) catch return ctx.fail("invalid URL: {s}", .{url});

        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(ctx.alloc, .{ .name = "accept", .value = opts.accept });
        try headers.appendSlice(ctx.alloc, opts.extra_headers);
        // std 0.16 never sends `privileged_headers` and keeps the overridable
        // authorization header across redirects to any host, so redirects
        // are followed here, and only within the same host.
        const auth: std.http.Client.Request.Headers.Value = if (opts.authorization) |a|
            (if (a.len == 0) .omit else .{ .override = a })
        else if (c.host.token) |t|
            .{ .override = try std.fmt.allocPrint(ctx.alloc, "token {s}", .{t}) }
        else
            .omit;

        var redirects: u8 = 0;
        while (true) {
            var req = ctx.http.request(method, uri, .{
                .headers = .{
                    .user_agent = .{ .override = "smith" },
                    .authorization = auth,
                    .content_type = if (opts.body != null) .{ .override = opts.content_type } else .default,
                },
                .extra_headers = headers.items,
                .redirect_behavior = .unhandled,
            }) catch |e| return ctx.fail("cannot reach {s}: {t}", .{ c.host.name, e });
            defer req.deinit();

            send(&req, opts.body) catch |e| return ctx.fail("cannot reach {s}: {t}", .{ c.host.name, e });

            var response = req.receiveHead(&.{}) catch |e| return ctx.fail("no response from {s}: {t}", .{ c.host.name, e });
            const status = @intFromEnum(response.head.status);
            if (opts.body == null and (status == 301 or status == 302 or status == 307 or status == 308)) {
                const location = response.head.location orelse return ctx.fail("HTTP {d} from {s} without a location", .{ status, url });
                const next = try resolveRedirect(ctx.alloc, uri, location);
                if (!sameHost(uri, next)) return ctx.fail("{s} redirects to another host ({s}); not following it with the token", .{ c.host.name, location });
                redirects += 1;
                if (redirects > 3) return ctx.fail("too many redirects from {s}", .{url});
                uri = next;
                continue;
            }
            return readResponse(ctx, c.host.name, &response);
        }
    }

    fn resolveRedirect(alloc: std.mem.Allocator, base: std.Uri, location: []const u8) !std.Uri {
        const buf = try alloc.alloc(u8, location.len + 1024);
        @memcpy(buf[0..location.len], location);
        var aux = buf;
        return base.resolveInPlace(location.len, &aux) catch base;
    }

    fn sameHost(a: std.Uri, b: std.Uri) bool {
        var ab: [std.Io.net.HostName.max_len]u8 = undefined;
        var bb: [std.Io.net.HostName.max_len]u8 = undefined;
        const ha = a.getHost(&ab) catch return false;
        const hb = b.getHost(&bb) catch return false;
        return std.ascii.eqlIgnoreCase(ha.bytes, hb.bytes) and a.port == b.port and std.mem.eql(u8, a.scheme, b.scheme);
    }

    fn readResponse(ctx: *Ctx, host_name: []const u8, response: *std.http.Client.Response) !Response {
        const status = @intFromEnum(response.head.status);
        // No body follows these, and without a length std would read the
        // kept-alive connection until the server drops it.
        if (response.request.method == .HEAD or status == 204 or status == 304 or status < 200)
            return .{ .status = status, .body = "" };
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
            error.ReadFailed => {
                if (response.bodyErr()) |why| return ctx.fail("reading the response from {s} failed: {t}", .{ host_name, why });
                return ctx.fail("reading the response from {s} failed (connection or decompression error)", .{host_name});
            },
            else => |x| return x,
        };
        return .{ .status = status, .body = body.written() };
    }

    fn send(req: *std.http.Client.Request, body: ?[]const u8) !void {
        if (body orelse if (req.method.requestHasBody()) @as([]const u8, "") else null) |b| {
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
            401 => {
                if (config.tokenWithheld(ctx, c.host)) {
                    ctx.err.print("authentication failed for {s} ({s}); SMITH_TOKEN only applies to the host SMITH_HOST names, or the default host: set SMITH_HOST={s} or {s}\n", .{ c.host.name, message orelse "HTTP 401", c.host.name, config.tokenVariable(ctx.alloc, c.host.name) catch "SMITH_TOKEN_<HOST>" }) catch {};
                } else {
                    ctx.err.print("authentication failed for {s} ({s}); run `smith auth login --hostname {s}`\n", .{ c.host.name, message orelse "HTTP 401", c.host.name }) catch {};
                }
                return error.AuthRequired;
            },
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
        var page_size: u32 = @max(1, @min(limit, c.host.page_size orelse 50));
        var size_known = c.host.page_size != null;
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
            if (arr.len >= page_size) continue;
            // A short page ends the list, unless the server caps pages below
            // what was asked; learn its cap once before trusting it.
            if (arr.len == 0 or size_known) break;
            size_known = true;
            const max = try c.maxPageSize() orelse break;
            if (arr.len != max) break;
            page_size = max;
        }
        return items.toOwnedSlice(ctx.alloc);
    }

    /// The server's `max_response_items`, when it says.
    fn maxPageSize(c: *Client) !?u32 {
        const r = try c.raw(.GET, "/settings/api", .{});
        if (!r.ok()) return null;
        const Settings = struct { max_response_items: ?u32 = null };
        const s = json.parseFromSliceLeaky(Settings, c.ctx.alloc, r.body, .{ .ignore_unknown_fields = true }) catch return null;
        return s.max_response_items;
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
