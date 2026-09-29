//! What an instance offers, learnt without logging in: Forgejo or Gitea and
//! which version, whether it is an OAuth provider smith can use, which of
//! the built-in public OAuth clients it knows, and its largest page size.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const api = @import("api.zig");
const config = @import("config.zig");

pub const OAuthClient = struct {
    name: []const u8,
    id: []const u8,
};

/// Public clients Forgejo registers by default (`[oauth2] DEFAULT_APPLICATIONS`),
/// in the order smith prefers them. They accept any loopback redirect port.
pub const builtin_clients = [_]OAuthClient{
    .{ .name = "tea", .id = "d57cb8c4-630c-4168-8324-ec79935e18d4" },
    .{ .name = "git-credential-oauth", .id = "a4792ccc-144e-407e-86c9-5e7d8d9c3269" },
};

pub const Caps = struct {
    forgejo: bool = false,
    version: ?[]const u8 = null,
    /// Authorization code grant with S256 PKCE.
    oauth: bool = false,
    builtin_client: ?OAuthClient = null,
    page_size: ?u32 = null,
};

/// A client that sends no token: discovery must not leak one to endpoints
/// that do not need it.
fn anonymous(ctx: *Ctx, host: config.Host) !api.Client {
    var h = host;
    h.token = null;
    return .{ .ctx = ctx, .host = h, .base = try h.apiBase(ctx.alloc) };
}

pub fn discover(ctx: *Ctx, host: config.Host) !Caps {
    var c = try anonymous(ctx, host);
    const web = try host.webBase(ctx.alloc);
    var caps: Caps = .{};

    const Version = struct { version: []const u8 };
    const forgejo = try c.raw(.GET, try std.fmt.allocPrint(ctx.alloc, "{s}/api/forgejo/v1/version", .{web}), .{});
    if (forgejo.ok()) {
        caps.forgejo = true;
        if (parse(Version, ctx, forgejo.body)) |v| caps.version = v.version;
    } else {
        const gitea = try c.raw(.GET, "/version", .{});
        if (!gitea.ok()) return ctx.fail("{s} does not look like a Forgejo instance (no /api/v1/version)", .{host.name});
        if (parse(Version, ctx, gitea.body)) |v| caps.version = v.version;
    }

    const Settings = struct { max_response_items: ?u32 = null };
    const settings = try c.raw(.GET, "/settings/api", .{});
    if (settings.ok()) if (parse(Settings, ctx, settings.body)) |s| {
        caps.page_size = s.max_response_items;
    };

    const Oidc = struct {
        grant_types_supported: ?[]const []const u8 = null,
        code_challenge_methods_supported: ?[]const []const u8 = null,
    };
    const oidc = try c.raw(.GET, try std.fmt.allocPrint(ctx.alloc, "{s}/.well-known/openid-configuration", .{web}), .{});
    if (oidc.ok()) if (parse(Oidc, ctx, oidc.body)) |o| {
        caps.oauth = contains(o.grant_types_supported, "authorization_code") and contains(o.code_challenge_methods_supported, "S256");
    };
    if (caps.oauth) {
        for (builtin_clients) |client| {
            if (try clientKnown(ctx, &c, web, client.id)) {
                caps.builtin_client = client;
                break;
            }
        }
    }
    return caps;
}

/// Whether the instance knows an OAuth client, told apart by the error its
/// token endpoint gives a made-up code: `invalid_client` only for an unknown one.
pub fn clientKnown(ctx: *Ctx, c: *api.Client, web: []const u8, id: []const u8) !bool {
    const form = try std.fmt.allocPrint(ctx.alloc, "grant_type=authorization_code&client_id={s}&code=probe&code_verifier={s}&redirect_uri=http%3A%2F%2F127.0.0.1%2F", .{ id, "p" ** 43 });
    const r = try c.raw(.POST, try std.fmt.allocPrint(ctx.alloc, "{s}/login/oauth/access_token", .{web}), .{
        .body = form,
        .content_type = "application/x-www-form-urlencoded",
    });
    const Err = struct { @"error": ?[]const u8 = null };
    const e = parse(Err, ctx, r.body) orelse return false;
    const code = e.@"error" orelse return false;
    return !std.mem.eql(u8, code, "invalid_client");
}

fn parse(comptime T: type, ctx: *Ctx, body: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, ctx.alloc, body, .{ .ignore_unknown_fields = true }) catch null;
}

fn contains(list: ?[]const []const u8, s: []const u8) bool {
    for (list orelse return false) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}
