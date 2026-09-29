# auth

| Command | Does | Endpoints |
|---|---|---|
| `auth login` | Stores a token for a host | `GET /version`, `GET /user`, `GET /repos/search?limit=1` |
| `auth status` | Checks every stored token | `GET /user` per host |
| `auth logout` | Forgets a host | none |
| `auth token` | Prints the token in use | none |

- **login**: the hostname comes from `--hostname`, `SMITH_HOST`, or a prompt;
  the token from `--with-token` (stdin) or a no-echo prompt on a terminal,
  never from an argument. `/version` proves it is a Forgejo, `/user` checks
  the token (401 fails; 403 means no `read:user` scope and is accepted without
  a username). The SSH hostname is read off a repository's `ssh_url` unless
  `--ssh-host` gives it. The first host logged in to becomes `default_host`.
- **status** exits 1 if any token is missing or rejected; tokens are shown as
  their first four characters unless `--show-token`.
- Differences from gh: no OAuth/device flow (Forgejo has none), no keyring yet
  (the file is 0600), `--scheme http` for LAN instances.

## Sources

- `src/cmd/auth.zig`
- `src/config.zig`
- `src/tests/auth_test.zig`
