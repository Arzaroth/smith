const std = @import("std");
const Harness = @import("../testing/Harness.zig");
const fx = @import("fixtures.zig");

test "version and help need no server" {
    var h: Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    try h.expectRun(0, &.{"--version"});
    try h.expectOut("smith ");
    try h.expectRun(0, &.{ "pr", "--help" });
    try h.expectOut("checkout");
    try h.expectRun(1, &.{"frobnicate"});
    try h.expectErr("unknown command \"frobnicate\"");
}

test "repo view -R reaches the mock" {
    var h: Harness = undefined;
    try h.init(&.{.{ .path = "/api/v1/repos/owner/repo", .body = fx.repo }}, .{});
    defer h.deinit();
    const host = try std.fmt.allocPrint(h.arena.allocator(), "127.0.0.1:{d}/owner/repo", .{h.mock.port});
    try h.expectRun(0, &.{ "repo", "view", "-R", host });
    try h.expectOut("owner/repo");
    try h.expectOut("3 stars");
    try std.testing.expectEqualStrings("/api/v1/repos/owner/repo", h.mock.requests.items[0].target);
}
