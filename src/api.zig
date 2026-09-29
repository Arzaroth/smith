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
const template = @import("template.zig");
const term = @import("term.zig");

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

    pub const Upload = struct {
        prefix: []const u8,
        file: Io.File,
        size: u64,
        suffix: []const u8,
    };
    pub const RequestOptions = struct {
        body: ?[]const u8 = null,
        accept: []const u8 = "application/json",
        content_type: []const u8 = "application/json",
        extra_headers: []const std.http.Header = &.{},
        /// Replaces the host's token as the authorization header; `""` sends none.
        authorization: ?[]const u8 = null,
        /// Streams a successful body here instead of keeping it in memory.
        sink: ?*Io.Writer = null,
        /// Streams the request body from this file instead of `body`: the
        /// multipart prefix, the file, then the suffix.
        upload: ?Upload = null,
    };

    /// Sends a request and returns whatever came back, error statuses included.
    /// `path` is relative to `/api/v1` unless it is an absolute URL.
    pub fn raw(c: *Client, method: Method, path: []const u8, opts: RequestOptions) !Response {
        const ctx = c.ctx;
        const absolute = std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://");
        const url = if (absolute) path else try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ c.base, path });
        var uri = std.Uri.parse(url) catch return ctx.fail("invalid URL: {s}", .{url});

        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(ctx.alloc, .{ .name = "accept", .value = opts.accept });
        try headers.appendSlice(ctx.alloc, opts.extra_headers);
        // std 0.16 never sends `privileged_headers` and keeps the overridable
        // authorization header across redirects to any host, so the token
        // is attached here only while the URL stays on the API's scheme, host
        // and port: an absolute URL from the server (a release asset) or a
        // redirect elsewhere (object storage) goes without it.
        var auth: std.http.Client.Request.Headers.Value = if (opts.authorization) |a|
            (if (a.len == 0) .omit else .{ .override = a })
        else if (c.host.token) |t|
            .{ .override = try std.fmt.allocPrint(ctx.alloc, "token {s}", .{t}) }
        else
            .omit;
        if (absolute and opts.authorization == null) {
            const base = std.Uri.parse(c.base) catch unreachable;
            if (!sameHost(base, uri)) auth = .omit;
        }
        const has_body = opts.body != null or opts.upload != null;

        var redirects: u8 = 0;
        while (true) {
            var req = ctx.http.request(method, uri, .{
                .headers = .{
                    .user_agent = .{ .override = "smith" },
                    .authorization = auth,
                    .content_type = if (has_body) .{ .override = opts.content_type } else .default,
                },
                .extra_headers = headers.items,
                .redirect_behavior = .unhandled,
            }) catch |e| return ctx.fail("cannot reach {s}: {t}", .{ c.host.name, e });
            defer req.deinit();

            send(ctx, &req, opts) catch |e| return ctx.fail("cannot reach {s}: {t}", .{ c.host.name, e });

            var response = req.receiveHead(&.{}) catch |e| return ctx.fail("no response from {s}: {t}", .{ c.host.name, e });
            const status = @intFromEnum(response.head.status);
            if (!has_body and (status == 301 or status == 302 or status == 303 or status == 307 or status == 308)) {
                const location = response.head.location orelse return ctx.fail("HTTP {d} from {s} without a location", .{ status, url });
                const next = try resolveRedirect(ctx.alloc, uri, location);
                if (!sameHost(uri, next)) auth = .omit;
                redirects += 1;
                if (redirects > 3) return ctx.fail("too many redirects from {s}", .{url});
                uri = next;
                continue;
            }
            return readResponse(ctx, c.host.name, &response, opts.sink);
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

    fn readResponse(ctx: *Ctx, host_name: []const u8, response: *std.http.Client.Response, sink: ?*Io.Writer) !Response {
        const status = @intFromEnum(response.head.status);
        // No body follows these. Without a length, std would read the kept-alive
        // connection until the server drops it, here or when the request is
        // released (`Request.deinit` ignores the rule), so mark the body read.
        if (response.request.method == .HEAD or status == 204 or status == 304 or status < 200) {
            response.request.reader.state = .ready;
            return .{ .status = status, .body = "" };
        }
        var body: Io.Writer.Allocating = .init(ctx.alloc);
        const out = if (sink != null and status >= 200 and status < 300) sink.? else &body.writer;
        var transfer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const decompress_buf = try ctx.alloc.alloc(u8, switch (response.head.content_encoding) {
            .identity => 0,
            .zstd => std.compress.zstd.default_window_len,
            else => std.compress.flate.max_window_len,
        });
        const reader = response.readerDecompressing(&transfer, &decompress, decompress_buf);
        _ = reader.streamRemaining(out) catch |e| switch (e) {
            error.ReadFailed => {
                if (response.bodyErr()) |why| return ctx.fail("reading the response from {s} failed: {t}", .{ host_name, why });
                return ctx.fail("reading the response from {s} failed (connection or decompression error)", .{host_name});
            },
            else => |x| return x,
        };
        return .{ .status = status, .body = body.written() };
    }

    fn send(ctx: *Ctx, req: *std.http.Client.Request, opts: RequestOptions) !void {
        if (opts.upload) |u| {
            req.transfer_encoding = .{ .content_length = u.prefix.len + u.size + u.suffix.len };
            var wbuf: [16 * 1024]u8 = undefined;
            var bw = try req.sendBodyUnflushed(&wbuf);
            try bw.writer.writeAll(u.prefix);
            var rbuf: [16 * 1024]u8 = undefined;
            var fr = u.file.reader(ctx.io, &rbuf);
            try fr.interface.streamExact64(&bw.writer, u.size);
            try bw.writer.writeAll(u.suffix);
            try bw.end();
            try req.connection.?.flush();
            return;
        }
        if (opts.body orelse if (req.method.requestHasBody()) @as([]const u8, "") else null) |b| {
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

    /// Uploads a file as the `attachment` field of a multipart form,
    /// streaming it rather than holding it in memory.
    pub fn uploadFile(c: *Client, path: []const u8, filename: []const u8, file: Io.File, size: u64) !Response {
        const ctx = c.ctx;
        const boundary = try std.fmt.allocPrint(ctx.alloc, "smith-{s}", .{try ctx.nonce()});
        const safe = try ctx.alloc.dupe(u8, filename);
        for (safe) |*ch| if (ch.* == '"' or ch.* == '\r' or ch.* == '\n' or ch.* == '\\') {
            ch.* = '_';
        };
        return c.call(.POST, path, .{
            .upload = .{
                .prefix = try std.fmt.allocPrint(ctx.alloc, "--{s}\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, safe }),
                .file = file,
                .size = size,
                .suffix = try std.fmt.allocPrint(ctx.alloc, "\r\n--{s}--\r\n", .{boundary}),
            },
            .content_type = try std.fmt.allocPrint(ctx.alloc, "multipart/form-data; boundary={s}", .{boundary}),
        });
    }

    /// Downloads `url` into `target`, streaming it through a temporary file
    /// renamed into place, so a failed download leaves nothing behind.
    /// Returns the number of bytes written.
    pub fn download(c: *Client, url: []const u8, target: []const u8, clobber: bool) !u64 {
        const ctx = c.ctx;
        const cwd = Io.Dir.cwd();
        if (!clobber) if (cwd.access(ctx.io, target, .{})) |_| {
            return ctx.fail("{s} already exists; pass --clobber to overwrite it", .{target});
        } else |_| {};
        const tmp = try std.fmt.allocPrint(ctx.alloc, "{s}.{s}.part", .{ target, try ctx.nonce() });
        var file = cwd.createFile(ctx.io, tmp, .{ .exclusive = true }) catch |e| return ctx.fail("cannot write {s}: {t}", .{ tmp, e });
        var keep = false;
        defer if (!keep) cwd.deleteFile(ctx.io, tmp) catch {};
        {
            defer file.close(ctx.io);
            var buf: [64 * 1024]u8 = undefined;
            var fw = file.writer(ctx.io, &buf);
            const r = try c.raw(.GET, url, .{ .accept = "*/*", .sink = &fw.interface });
            if (!r.ok()) return c.failStatus(.GET, url, r);
            fw.interface.flush() catch |e| return ctx.fail("cannot write {s}: {t}", .{ tmp, e });
        }
        cwd.rename(tmp, cwd, target, ctx.io) catch |e| return ctx.fail("cannot write {s}: {t}", .{ target, e });
        keep = true;
        const size = (cwd.statFile(ctx.io, target, .{}) catch return 0).size;
        return size;
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
        const All = struct {
            pub fn keep(_: @This(), _: json.Value) !bool {
                return true;
            }
        };
        return c.list(path, limit, field, limit, All{});
    }

    /// Like `listValues`, keeping only the items `filter.keep` accepts and
    /// reading on until `limit` of them were found or the list ends: for
    /// filters the API lacks.
    pub fn listMatching(c: *Client, path: []const u8, limit: u32, field: ?[]const u8, filter: anytype) ![]json.Value {
        return c.list(path, limit, field, std.math.maxInt(u32), filter);
    }

    fn list(c: *Client, path: []const u8, limit: u32, field: ?[]const u8, batch: u32, filter: anytype) ![]json.Value {
        const ctx = c.ctx;
        var items: std.ArrayList(json.Value) = .empty;
        var page_size: u32 = @max(1, @min(batch, c.host.page_size orelse 50));
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
                if (try filter.keep(item)) try items.append(ctx.alloc, item);
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

/// Prints JSON, or what `--jq` or `--template` make of it.
pub fn printJson(ctx: *Ctx, v: anytype) !void {
    if (ctx.jq == null and ctx.template == null) {
        try json.Stringify.value(v, .{ .whitespace = .indent_2 }, ctx.out);
        try ctx.out.writeByte('\n');
        return;
    }
    const text = try json.Stringify.valueAlloc(ctx.alloc, v, .{});
    if (ctx.template) |src| {
        const value = try json.parseFromSliceLeaky(json.Value, ctx.alloc, text, .{});
        const t = template.Template.parse(ctx.alloc, src) catch return ctx.fail("invalid --template: {s}", .{src});
        var aw: Io.Writer.Allocating = .init(ctx.alloc);
        t.render(ctx.alloc, &aw.writer, value, ctx.now) catch |e| switch (e) {
            error.TemplateSyntax => return ctx.fail("invalid --template: {s}", .{src}),
            else => |x| return x,
        };
        return writeFiltered(ctx, aw.written());
    }
    try jqFilter(ctx, text, ctx.jq.?);
}

/// Runs the system jq over `text`, like gh's --jq: strings come out raw.
/// Output made from server text by --template or --jq, cleaned of control
/// characters on a terminal and left byte for byte in a pipe.
fn writeFiltered(ctx: *Ctx, text: []const u8) !void {
    try ctx.out.writeAll(if (ctx.stdout_tty) try term.clean(ctx.alloc, text, true) else text);
}

fn jqFilter(ctx: *Ctx, text: []const u8, expr: []const u8) !void {
    try ctx.out.flush();
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ ctx.getenv("SMITH_JQ") orelse "jq", "-r", expr },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = ctx.env,
    }) catch |e| switch (e) {
        error.FileNotFound => return ctx.fail("--jq needs jq installed (https://jqlang.org); --template works without it", .{}),
        else => return ctx.fail("cannot run jq: {t}", .{e}),
    };
    defer child.kill(ctx.io);
    {
        var buf: [4096]u8 = undefined;
        var w = child.stdin.?.writerStreaming(ctx.io, &buf);
        w.interface.writeAll(text) catch {};
        w.interface.flush() catch {};
        child.stdin.?.close(ctx.io);
        child.stdin = null;
    }
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(ctx.io, &buf);
    const out = try r.interface.allocRemaining(ctx.alloc, .limited(256 * 1024 * 1024));
    var ebuf: [4096]u8 = undefined;
    var er = child.stderr.?.readerStreaming(ctx.io, &ebuf);
    const complaint = er.interface.allocRemaining(ctx.alloc, .limited(64 * 1024)) catch "";
    const exit = try child.wait(ctx.io);
    try writeFiltered(ctx, out);
    if (exit != .exited or exit.exited != 0) {
        const why = std.mem.trim(u8, complaint, " \r\n");
        if (why.len > 0) return ctx.fail("{s}", .{why});
        return ctx.fail("jq rejected the expression: {s}", .{expr});
    }
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
