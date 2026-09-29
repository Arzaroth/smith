//! A Forgejo stand-in for tests: canned responses by method and path, served
//! from a background task on 127.0.0.1, with every request recorded.
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
    /// How many times the route answers before it stops matching.
    times: ?u32 = null,
};

pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    authorization: ?[]const u8 = null,
};

io: Io,
arena: std.heap.ArenaAllocator,
server: Io.net.Server,
port: u16,
routes: []const Route,
used: []u32,
requests: std.ArrayList(Request) = .empty,
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
    m.used = try m.arena.allocator().alloc(u32, routes.len);
    @memset(m.used, 0);
    const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    m.server = try addr.listen(io, .{ .reuse_address = true });
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
    while (true) {
        const stream = m.server.accept(m.io) catch return;
        m.handle(stream) catch {};
        stream.close(m.io);
    }
}

fn handle(m: *Mock, stream: Io.net.Stream) !void {
    const alloc = m.arena.allocator();
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(m.io, &read_buf);
    var writer = stream.writer(m.io, &write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = try server.receiveHead();
    const target = try alloc.dupe(u8, req.head.target);
    const method = req.head.method;
    var authorization: ?[]const u8 = null;
    var headers = req.iterateHeaders();
    while (headers.next()) |hd| if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) {
        authorization = try alloc.dupe(u8, hd.value);
    };
    var body: []const u8 = "";
    if (req.head.content_length) |len| {
        var body_buf: [4096]u8 = undefined;
        const r = req.readerExpectNone(&body_buf);
        body = try r.readAlloc(alloc, @intCast(len));
    }
    try m.requests.append(alloc, .{ .method = method, .target = target, .body = body, .authorization = authorization });

    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;
    const query = if (q) |i| target[i + 1 ..] else "";
    for (m.routes, m.used) |route, *used| {
        if (route.method != method or !std.mem.eql(u8, route.path, path)) continue;
        if (route.query) |want| if (std.mem.indexOf(u8, query, want) == null) continue;
        if (route.times) |t| if (used.* >= t) continue;
        used.* += 1;
        const with_location = [_]std.http.Header{
            .{ .name = "content-type", .value = route.content_type },
            .{ .name = "location", .value = route.location orelse "" },
        };
        try req.respond(route.body, .{
            .status = @enumFromInt(route.status),
            .keep_alive = false,
            .extra_headers = if (route.location != null) &with_location else with_location[0..1],
        });
        return;
    }
    try req.respond("{\"message\":\"no mock route\"}", .{ .status = .not_found, .keep_alive = false });
}

fn samePath(target: []const u8, path: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return std.mem.eql(u8, target[0..end], path);
}
