# search, status, notification, ssh-key, gpg-key, org

These act on a host rather than a repository: `--hostname`, else the default
host.

- **search repos <q>**: `/repos/search` (the `data` array), sorted by recent
  update, archived ones left out unless `--archived`. `--owner` looks the
  owner's id up (`/users/{name}`) and passes `uid` with `exclusive`.
- **search issues|prs <q>**: `/repos/issues/search?type=issues|pulls` with
  `state` and `owner`; rows name the repository (`team/app#3`).
- **status**: four `/repos/issues/search` queries for open items with
  `assigned`, `review_requested` and `mentioned`: assigned issues, assigned
  pull requests, review requests, mentions (`-L` per section, 10 by
  default). Needs a login.
- **notification list** (`--all` includes read ones), **notification read
  <id>** (`PATCH /notifications/threads/{id}?to-status=read`) or `--all`
  (`PUT /notifications?all=true&to-status=read`).
- **ssh-key** `list`, `add [file]` (stdin without one; the title defaults to
  the key's comment; `--read-only`), `delete <id>` over `/user/keys`.
- **gpg-key** `list`, `add [file]` (armored), `delete <id>` over
  `/user/gpg_keys`.
- **org list [user]**: `/user/orgs`, or `/users/{user}/orgs`.

## Sources

- `src/cmd/search.zig`
- `src/cmd/status.zig`
- `src/cmd/notification.zig`
- `src/cmd/key.zig`
- `src/tests/account_test.zig`
