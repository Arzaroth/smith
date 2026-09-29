# repo

| Command | Does | Endpoints |
|---|---|---|
| `repo clone <repo> [<dir>] [-- <git flags>]` | Clones; a fork also gets `upstream` | `GET /repos/{o}/{r}` |
| `repo view [<repo>]` | Description, visibility, counters, clone URLs | `GET /repos/{o}/{r}` |
| `repo list [<owner>]` | A user's or organization's repositories | `GET /users/{o}/repos`, falling back to `/orgs/{o}/repos`; `/user/repos` without an owner |

- A repository argument is `REPO` (the logged-in user's), `OWNER/REPO`,
  `HOST:OWNER/REPO` (git's scp-like form; HOST may be the SSH hostname),
  `HOST/OWNER/REPO` or a clone URL.
- `clone` takes `ssh_url` or `clone_url` by the host's `git_protocol`; for a
  fork it runs `git remote add -f upstream <parent>` (`-u` renames it).
- `browse` lives in [tools.md](tools.md).
- **create** `[OWNER/]NAME`: `POST /user/repos`, or `/orgs/{owner}/repos`
  when the owner is not you. Visibility must be chosen (`--public` or
  `--private`, or a prompt on a terminal). `--add-readme`, `--gitignore`,
  `--license` initialise it; `--homepage` is a follow-up `PATCH`. `--source
  DIR` adds the new repository as a remote there (`--remote`, default
  origin) and `--push` pushes HEAD; otherwise `--clone` clones it.
- **fork**: `POST .../forks` (`--org`, `--fork-name`). Inside a clone of the
  repository, `--remote` renames `origin` to `upstream` and adds the fork as
  `origin`; elsewhere `--clone` clones the fork and adds `upstream`.
- **edit**: one `PATCH` with only what was asked: `-d`, `--homepage`,
  `--default-branch`, `--visibility`, `--merge-style`,
  `--delete-branch-on-merge`, `--template`, and `--enable-X` / `--disable-X`
  for issues, wiki, pull-requests, actions, releases, projects, packages.
- **sync**: a pull mirror gets `POST .../mirror-sync`; a fork first reads
  `GET .../sync_fork` (or `/sync_fork/{branch}` with `-b`): nothing to do
  when `commits_behind` is 0, an error when Forgejo does not allow it (the
  fork has commits of its own), else the same path with `POST`. Anything
  else is an error.
- **list** takes gh's `--fork`, `--source`, `--visibility
  public|private|internal`, `--archived`, `--no-archived`, `-l/--language` and
  `--topic` (repeatable), filtered while paging (`Client.listMatching`):
  `/user/repos`, `/users/{o}/repos` and `/orgs/{o}/repos` cannot filter
  on them (`/repos/search` could, for some).
- **archive** / **unarchive**: `PATCH {archived}`, after a confirmation.
- **delete**: `DELETE /repos/{o}/{r}`; on a terminal the full name must be
  typed back, otherwise `--yes` is required.
- **set-default [REPO]**: records which remote this clone's commands act on as
  `git config remote.<name>.smith-resolved base` (gh's convention with its own
  key); `--view` prints it, `--unset` forgets it. See
  [../architecture/repo-resolution.md](../architecture/repo-resolution.md).

## Sources

- `src/cmd/repo.zig`
- `src/tests/repo_test.zig`
