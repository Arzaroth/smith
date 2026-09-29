# Host configuration

`$SMITH_CONFIG_DIR/hosts.zon` (default `$XDG_CONFIG_HOME/smith`, then
`~/.config/smith`), ZON, written through a temporary file and renamed, mode
0600. One entry per Forgejo host:

```zig
.{
    .default_host = "git.example.com",
    .hosts = .{
        .{ .name = "git.example.com", .token = "...", .user = "me",
           .git_protocol = .ssh, .ssh_host = "box.example.com" },
    },
}
```

- `name` is the web/API hostname, with a port if it has one. `scheme` is
  `https` unless set to `http` (LAN instances, tests).
- `ssh_host` is the hostname git uses over SSH when it is not `name`; `auth
  login` discovers it from a repository's `ssh_url`. Remote URLs are matched
  against both (`Host.matches`).
- `git_protocol` picks the URL `repo clone` uses.
- `page_size` is the instance's `max_response_items`, read at login (50 when
  unknown).
- A browser login also stores `oauth_client_id`, `refresh_token` and
  `expires_at` (Unix seconds); see [../features/auth.md](../features/auth.md).
- Environment: `SMITH_TOKEN` overrides the stored token (and turns refreshing
  off) of whatever host is
  in use; `SMITH_HOST` picks the default host; `SMITH_CONFIG_DIR` moves the
  file.
- Default host when no repository says otherwise: `SMITH_HOST`, then
  `default_host`, then the only configured host.

## Sources

- `src/config.zig`
- `src/cmd/auth.zig`
