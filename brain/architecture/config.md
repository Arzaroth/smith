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
stored one. Only a host that is configured in `hosts.zon`, or is the
default host, can receive one, its name must match exactly (port included),
and over plain http only when the configured entry says http:

1. `SMITH_TOKEN_<HOST>` for that host: the host name upper-cased with every
   non-alphanumeric character turned into `_` (`SMITH_TOKEN_GIT_EXAMPLE_COM`,
   `SMITH_TOKEN_127_0_0_1_3000`). Lookalike names can map to the same
   variable (`git-example.com`), which is why the host must be a trusted one.
2. Else `SMITH_TOKEN`, only for the default host. A clone whose remotes point
   elsewhere never receives it; a 401 there says so and names the variables
   that would work.

An environment token turns refreshing off for that invocation.
`SMITH_CONFIG_DIR` moves the file.

The file is written to a temporary file with a random name, created
exclusively with mode 0600 (a planted file or symlink makes the write fail
rather than be followed), then renamed over `hosts.zon`.

## Sources

- `src/config.zig`
- `src/cmd/auth.zig`
- `src/api.zig`

## Keyring

`keyring.zig` talks to the system keyring through its command-line helper,
with secrets on the helper's stdin:

| Backend | Program | Entry |
|---|---|---|
| Secret Service (Linux, BSD) | `secret-tool` | attributes `service=smith host=<name> user=<user> kind=token\|refresh` |
| macOS keychain | `security` (`-i` to keep the secret off argv) | service `smith:<host>`, account `<user>:<kind>` |

`SMITH_KEYRING` overrides the choice: `none` (or `file`), `secret-tool`,
`security`, or the absolute path of a secret-tool-compatible program (how the
tests plug in a fake: a child's program is looked up in smith's own `PATH`,
not the environment passed to it).

An account with `keyring = true` has its token and refresh token in the
keyring. `save` (`moveSecrets`) writes whatever secrets it holds there and
strips them from the file, or keeps them in the file and drops the flag when
the keyring refuses; `withEnv` (through `withSecrets`) reads them back for
the account in use, unless an environment token applies. The rest of the
entry, expiry included, stays in the file.
