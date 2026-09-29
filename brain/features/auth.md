# auth

| Command | Does | Endpoints |
|---|---|---|
| `auth login` | Logs in to a host, then stores the token | discovery (below), then per route; `GET /user`, `GET /repos/search?limit=1` |
| `auth status` | Checks every stored token | `GET /user` per host |
| `auth switch` | Changes the default host or the active account | none |
| `auth logout` | Forgets an account | none |
| `auth token` | Prints the token in use | none |

## Login routes

`auth login` first learns what the instance offers ([caps](#discovery)), then
takes one of three routes:

- **Browser** (`--web`; the default on a terminal when the instance is an
  OAuth provider with S256 PKCE and a browser can be opened: `SMITH_BROWSER`,
  `BROWSER`, macOS, or a `DISPLAY`/`WAYLAND_DISPLAY`). smith listens on a
  random 127.0.0.1 port, opens `/login/oauth/authorize` with a PKCE challenge
  and a random state, waits for the redirect, checks the state, and trades
  the code at `/login/oauth/access_token`. The access token (an hour on
  Forgejo) is stored with its refresh token, expiry and client ID, and is
  renewed within a minute of expiring by `api.Client.init`, which saves the
  new pair. A refused refresh asks to log in again.
- **Password** (`--password`; the default on a terminal otherwise). Username
  (`-u` or a prompt) and password (no echo) authenticate
  `POST /users/{user}/tokens` with basic auth to create a token named
  `smith on <machine> (<time>)` with the scopes `write:repository`,
  `write:issue`, `read:user`, `read:organization`. A 401 or 403 that is not
  "password is invalid" / "user does not exist" is taken as a 2FA challenge:
  smith asks for the code once and retries with `X-Forgejo-OTP` (and
  `X-Gitea-OTP`). Accounts that sign in only through SSO or only with a
  security key cannot use this route.
- **Token** (`--with-token`, the only route without a terminal): read from
  stdin, never from an argument.

The OAuth client for the browser route: `--client-id`, else the one this host
used before, else the first built-in public client the instance knows (`tea`,
then `git-credential-oauth`), else the user registers smith once (name smith,
redirect URI `http://127.0.0.1/`, not confidential) and gives its ID, which is
then remembered. Forgejo accepts any loopback port for public clients.

The browser route gives up after five minutes without a redirect
(`SMITH_LOGIN_TIMEOUT` seconds), suggesting `--password`: a timer task shuts
the listening socket, which is how std lets another task end a blocking
accept.

## Where the token goes

The system keyring when there is one ([../architecture/config.md](../architecture/config.md#keyring)),
else `hosts.zon`; `--insecure-storage` insists on the file. Login says which.
A keyring that refuses the token leaves it in the file, with a warning.
`logout` removes the account's keyring entries.

## Discovery

`caps.discover`, with no token sent:

| Learns | From |
|---|---|
| Forgejo (vs Gitea) and version | `/api/forgejo/v1/version`, else `/api/v1/version` |
| Largest page size | `/api/v1/settings/api` `max_response_items`, stored as `page_size` |
| OAuth with PKCE | `/.well-known/openid-configuration` |
| Built-in clients | `/login/oauth/access_token` with a made-up code: `invalid_client` means unknown, any other error means known |

## Several hosts and accounts

Each login is an account, keyed by host and user
([../architecture/config.md](../architecture/config.md#accounts)).

- **switch** (`--hostname`, `--user`): `--hostname` makes that host the
  default; `--user` makes that account the active one; neither flips to the
  next account on the default host. Refuses when there is nothing to change.
- **logout** removes the active account of `--hostname` (default: the default
  host), or `--user`'s; another account on the host becomes active. It only
  forgets the login locally: a token made by the password route stays valid
  until revoked under Settings > Applications, which logout says.
- **token** prints the active account's token, or `--user`'s.
- **status** groups accounts under their host, marks the default host and,
  for a host with several accounts, which one is active; exits 1 if any
  token is missing or rejected; tokens are shown as their first four
  characters unless `--show-token`; a browser login says so.
- `SMITH_TOKEN` replaces the token of the default host only, and
  `SMITH_TOKEN_<HOST>` that of one host; either turns refreshing off.

## Sources

- `src/cmd/auth.zig`
- `src/caps.zig`
- `src/oauth.zig`
- `src/config.zig`
- `src/tests/auth_test.zig`, `src/tests/login_test.zig`
