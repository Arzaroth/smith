//! A Forgejo stand-in for tests: canned responses by method and path, served
//! from background tasks on 127.0.0.1, one per connection, with every
//! request recorded.
const Mock = @This();

const std = @import("std");
const Io = std.Io;

pub const Route = struct {
    method: std.http.Method = .GET,
    /// Path without the query string, e.g. "/api/v1/repos/o/r/pulls/1".
    path: []const u8,
    /// Substring the query string must contain, when set.
    query: ?[]const u8 = null,
    status: u16 = 200,
    body: []const u8 = "",
    content_type: []const u8 = "application/json",
    /// Sent as the Location header, for redirects.
    location: ?[]const u8 = null,
    /// Plays the authorization server: redirects to the request's
    /// `redirect_uri` with this code and the request's `state`.
    authorize_code: ?[]const u8 = null,
    /// How many times the route answers before it stops matching.
    times: ?u32 = null,
    /// Keeps the connection open for the next request, as real servers do; a
    /// client that then waits for a body the answer does not have is cut off
    /// after `idle_seconds`, which a test can notice from the time taken.
    keep_alive: bool = false,
    /// Sent verbatim as the whole response, status line and headers
    /// included, before the connection is closed.
    raw: ?[]const u8 = null,
};

pub const idle_seconds = 5;

pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    authorization: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},

    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

io: Io,
arena: std.heap.ArenaAllocator,
server: Io.net.Server,
port: u16,
routes: []const Route,
used: []u32,
requests: std.ArrayList(Request) = .empty,
lock: Io.Mutex = .init,
future: ?Io.Future(void) = null,

pub fn start(m: *Mock, io: Io, routes: []const Route) !void {
    m.* = .{
        .io = io,
        .arena = .init(std.heap.page_allocator),
        .server = undefined,
        .port = 0,
        .routes = routes,
        .used = undefined,
    };
    errdefer m.arena.deinit();
    m.used = try m.arena.allocator().alloc(u32, routes.len);
    @memset(m.used, 0);
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    m.server = try addr.listen(io, .{ .reuse_address = true });
    errdefer m.server.deinit(io);
    m.port = m.server.socket.address.getPort();
    m.future = try io.concurrent(serve, .{m});
}

pub fn stop(m: *Mock) void {
    if (m.future) |*f| f.cancel(m.io);
    m.server.deinit(m.io);
    m.arena.deinit();
}

/// Requests matching `method` and `path` (the query string is ignored).
pub fn count(m: *const Mock, method: std.http.Method, path: []const u8) usize {
    var n: usize = 0;
    for (m.requests.items) |r| {
        if (r.method == method and samePath(r.target, path)) n += 1;
    }
    return n;
}

/// The body of the last request matching `method` and `path`.
pub fn lastBody(m: *const Mock, method: std.http.Method, path: []const u8) ?[]const u8 {
    var i = m.requests.items.len;
    while (i > 0) {
        i -= 1;
        const r = m.requests.items[i];
        if (r.method == method and samePath(r.target, path)) return r.body;
    }
    return null;
}

fn serve(m: *Mock) void {
    var connections: Io.Group = .init;
    defer connections.cancel(m.io);
    while (true) {
        const stream = m.server.accept(m.io) catch return;
        connections.concurrent(m.io, connection, .{ m, stream }) catch {
            stream.close(m.io);
            return;
        };
    }
}

fn connection(m: *Mock, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(m.io);
    m.handle(stream) catch |e| if (e == error.Canceled) return error.Canceled;
}

fn handle(m: *Mock, stream: Io.net.Stream) !void {
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(m.io, &read_buf);
    var writer = stream.writer(m.io, &write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var watchdog: ?Io.Future(void) = null;
    defer if (watchdog) |*w| w.cancel(m.io);
    while (true) {
        var req = server.receiveHead() catch |e| {
            if (watchdog != null) return;
            return e;
        };
        if (watchdog) |*w| {
            w.cancel(m.io);
            watchdog = null;
        }
        if (!try m.answer(&req)) return;
        watchdog = try m.io.concurrent(cutOff, .{ m.io, stream });
    }
}

fn cutOff(io: Io, stream: Io.net.Stream) void {
    io.sleep(.fromSeconds(idle_seconds), .awake) catch return;
    stream.shutdown(io, .both) catch {};
}

/// Records and answers one request; true when the connection stays open.
fn answer(m: *Mock, req: *std.http.Server.Request) !bool {
    try m.lock.lock(m.io);
    defer m.lock.unlock(m.io);
    const alloc = m.arena.allocator();
    const target = try alloc.dupe(u8, req.head.target);
    const method = req.head.method;
    var authorization: ?[]const u8 = null;
    var headers: std.ArrayList(std.http.Header) = .empty;
    var it = req.iterateHeaders();
    while (it.next()) |hd| {
        const copy: std.http.Header = .{ .name = try alloc.dupe(u8, hd.name), .value = try alloc.dupe(u8, hd.value) };
        try headers.append(alloc, copy);
        if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) authorization = copy.value;
    }
    var body: []const u8 = "";
    if (req.head.content_length) |len| {
        var body_buf: [4096]u8 = undefined;
        const r = req.readerExpectNone(&body_buf);
        body = try r.readAlloc(alloc, @intCast(len));
    }
    try m.requests.append(alloc, .{ .method = method, .target = target, .body = body, .authorization = authorization, .headers = headers.items });

    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;
    const query = if (q) |i| target[i + 1 ..] else "";
    for (m.routes, m.used) |route, *used| {
        if (route.method != method or !std.mem.eql(u8, route.path, path)) continue;
        if (route.query) |want| if (std.mem.indexOf(u8, query, want) == null) continue;
        if (route.times) |t| if (used.* >= t) continue;
        used.* += 1;
        if (route.raw) |bytes| {
            try req.server.out.writeAll(bytes);
            try req.server.out.flush();
            return false;
        }
        if (route.keep_alive and route.status == 204) {
            req.server.reader.state = .ready;
            try req.server.out.writeAll("HTTP/1.1 204 No Content\r\n\r\n");
            try req.server.out.flush();
            return true;
        }
        const location = if (route.authorize_code) |code|
            try std.fmt.allocPrint(alloc, "{s}?code={s}&state={s}", .{ try param(alloc, query, "redirect_uri"), code, try param(alloc, query, "state") })
        else
            route.location;
        const with_location = [_]std.http.Header{
            .{ .name = "content-type", .value = route.content_type },
            .{ .name = "location", .value = location orelse "" },
        };
        try req.respond(route.body, .{
            .status = if (route.authorize_code != null) .found else @enumFromInt(route.status),
            .keep_alive = route.keep_alive,
            .extra_headers = if (location != null) &with_location else with_location[0..1],
        });
        return route.keep_alive;
    }
    try req.respond("{\"message\":\"no mock route\"}", .{ .status = .not_found, .keep_alive = false });
    return false;
}

fn samePath(target: []const u8, path: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return std.mem.eql(u8, target[0..end], path);
}

fn param(alloc: std.mem.Allocator, query: []const u8, name: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const raw = pair[eq + 1 ..];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '%' and i + 2 < raw.len) {
                try out.append(alloc, try std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16));
                i += 2;
            } else try out.append(alloc, raw[i]);
        }
        return out.items;
    }
    return "";
}
