# repo

| Command | Does | Endpoints |
|---|---|---|
| `repo clone <repo> [<dir>] [-- <git flags>]` | Clones; a fork also gets `upstream` | `GET /repos/{o}/{r}` |
| `repo view [<repo>]` | Description, visibility, counters, clone URLs | `GET /repos/{o}/{r}` |
| `repo list [<owner>]` | A user's or organization's repositories | `GET /users/{o}/repos`, falling back to `/orgs/{o}/repos`; `/user/repos` without an owner |

- A repository argument is `REPO` (the logged-in user's), `OWNER/REPO`,
  `HOST/OWNER/REPO` or a clone URL.
- `clone` takes `ssh_url` or `clone_url` by the host's `git_protocol`; for a
  fork it runs `git remote add -f upstream <parent>` (`-u` renames it).
- `browse` lives in [tools.md](tools.md).

## Sources

- `src/cmd/repo.zig`
- `src/tests/repo_test.zig`
