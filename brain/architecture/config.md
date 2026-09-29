# Host configuration

`$SMITH_CONFIG_DIR/hosts.zon` (default `$XDG_CONFIG_HOME/smith`, then
`~/.config/smith`), ZON, written through a temporary file and renamed, mode
0600. One entry per account; a host with several accounts has several
entries, one of them `active`:

```zig
.{
    .default_host = "git.example.com",
    .hosts = .{
        .{ .name = "git.example.com", .user = "me", .token = "...",
           .git_protocol = .ssh, .ssh_host = "box.example.com" },
        .{ .name = "git.example.com", .user = "work", .token = "...", .active = false },
        .{ .name = "codeberg.org", .user = "me", .token = "...", .refresh_token = "...",
           .expires_at = 1790686800, .oauth_client_id = "..." },
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

## Accounts

An account is a *(host, user)* pair (`sameAccount`). Logging in again as the
same user replaces the entry; as another user adds one and makes it the
active account. `Config.find` returns the active account of a host, so
everything outside `auth` sees one account per host. `auth switch` changes
the active account or the default host, `auth logout` removes the active
account (or `--user`) and activates another one on the same host.

## Default host

Used when no repository says otherwise (`Config.defaultName`): `SMITH_HOST`,
then `default_host` (set by the first login, changed by `auth switch
--hostname`), then the host when only one is configured.

## Tokens from the environment

`withEnv` decides, per host, whether an environment token replaces the
stored one:

1. `SMITH_TOKEN_<HOST>` for that host: the host name upper-cased with every
   non-alphanumeric character turned into `_` (`SMITH_TOKEN_GIT_EXAMPLE_COM`,
   `SMITH_TOKEN_127_0_0_1_3000`).
2. Else `SMITH_TOKEN`, but only for the default host as defined above. A
   clone whose remotes point elsewhere never receives it; a 401 there says
   so and names the variables that would work.

An environment token turns refreshing off for that invocation.
`SMITH_CONFIG_DIR` moves the file.

## Sources

- `src/config.zig`
- `src/cmd/auth.zig`
- `src/api.zig`
