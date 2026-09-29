# pr

A pull request is named by number, `#number`, URL, or head branch; without
one, the open pull request whose head is the current branch.

| Command | Endpoints |
|---|---|
| `pr list` | `GET /repos/{o}/{r}/pulls?state=&poster=&base=&labels=<ids>&sort=recentupdate` |
| `pr view [--comments]` | `GET .../pulls/{n}` (or the open list, by branch) |
| `pr diff [--patch] [--name-only]` | `GET .../pulls/{n}.diff`/`.patch`, `GET .../pulls/{n}/files` |
| `pr create` | `GET .../repos/{o}/{r}` for the default base, `POST .../pulls`, `POST .../pulls/{n}/requested_reviewers` |
| `pr checkout <n>` | `GET .../pulls/{n}`, then git |
| `pr merge` | `POST .../pulls/{n}/merge` |
| `pr close/reopen` | `PATCH .../pulls/{n}` `{state}`, `DELETE .../branches/{b}` with `-d` |
| `pr ready [--undo]` | `PATCH .../pulls/{n}` `{title}` |
| `pr comment`, `pr edit` | as for issues, plus `base` on edit |
| `pr checks [--watch]` | `GET .../commits/{head sha}/status` |

- **Drafts** are Forgejo's `WIP: ` title prefix: `create --draft` adds it,
  `ready` removes it, `--undo` puts it back. The list shows them as `draft`.
- **merged** is not a Forgejo state: `list -s merged` asks for closed ones and
  keeps those with `merged`, fetching up to four times the limit.
- **create** defaults the head to the current branch and requires it to have
  an upstream; if that upstream remote belongs to another owner (a fork), the
  head becomes `owner:branch`. `--fill` (and the defaults offered on a
  terminal) take one commit's subject and body, or the branch name and a list
  of subjects, from `<remote>/<base>..HEAD`.
- **checkout**: a same-repository head is fetched into
  `refs/remotes/<remote>/<branch>` and checked out tracking it (fast-forward
  if it exists, `-f` resets). A fork's head, or a head that is itself a ref
  (AGit, deleted branch), is fetched from `refs/pull/<n>/head` into a local
  branch (`pr-<n>` for the latter).
- **merge** picks `--merge|--squash|--rebase|--rebase-merge|--ff-only`, else
  the repository's `default_merge_style`. `--auto` is
  `merge_when_checks_succeed`, `--admin` is `force_merge`, `-d` deletes the
  head branch on the server and, after an immediate merge, locally (switching
  to the base first). 405 and 409 get their own messages.
- **checks** reads the combined commit status, so any CI that posts statuses
  shows, Forgejo Actions included; relative target URLs are made absolute.
  Exit 1 if something failed, 8 if something is pending, 0 otherwise.

## Sources

- `src/cmd/pr.zig`
- `src/cmd/common.zig`
- `src/tests/pr_test.zig`
