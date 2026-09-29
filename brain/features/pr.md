# pr

A pull request is named by number, `#number` or URL, or by branch: `branch`
means that branch in this repository, `owner:branch` a fork's (`fix/42` is a
branch, never #42). Without one, it is the current branch as pushed: the
owner of its upstream's remote and the upstream branch. An open pull request
is looked for first, then the most recently updated closed or merged one.

| Command | Endpoints |
|---|---|
| `pr list` | `GET /repos/{o}/{r}/pulls?state=&poster=&base=&labels=<ids>&sort=recentupdate`; `--head` filtered client-side |
| `pr view [--comments]` | `GET .../pulls/{n}` (or the open list, by branch) |
| `pr diff [--patch] [--name-only]` | `GET .../pulls/{n}.diff`/`.patch`, `GET .../pulls/{n}/files` |
| `pr create` | `GET .../repos/{o}/{r}` for the default base, `POST .../pulls`, `POST .../pulls/{n}/requested_reviewers` |
| `pr checkout <n>` | `GET .../pulls/{n}`, then git |
| `pr merge` | `POST .../pulls/{n}/merge` |
| `pr close/reopen` | `PATCH .../pulls/{n}` `{state}`, `DELETE .../branches/{b}` with `-d` |
| `pr ready [--undo]` | `PATCH .../pulls/{n}` `{title}` |
| `pr comment`, `pr edit` | as for issues, plus `base` on edit |
| `pr checks [--watch]` | `GET .../commits/{head sha}/status` |
| `pr review` | `POST .../pulls/{n}/reviews` `{event, body, commit_id}` |
| `pr update-branch [--rebase]` | `POST .../pulls/{n}/update?style=merge\|rebase` |
| `pr status` | `GET .../pulls?state=open`, and the current branch's combined status |

- **Drafts** are Forgejo's work-in-progress title prefixes (`WIP:`,
  `[WIP]`, any case): `create --draft` adds `WIP: `,
  `ready` removes it, `--undo` puts it back. The list shows them as `draft`.
- **merged** is not a Forgejo state: `list -s merged` asks for closed ones and
  keeps those with `merged`, fetching up to four times the limit.
- **create** takes the current branch as pushed: its upstream's remote must
  hold a branch of the same name (a branch cut from `origin/main` tracks
  `main`, which is refused with the `git push -u` to run). If that remote
  belongs to another owner (a fork), the head becomes `owner:branch`.
  `--fill` (and the defaults offered on a terminal) take one commit's
  subject and body, or the branch name and a list of subjects, from
  `<remote>/<base>..HEAD`. Without a terminal, `--title` and `--body` (or
  `--fill`) are required, as in gh.
- **checkout**: a same-repository head is fetched into
  `refs/remotes/<remote>/<branch>` and checked out tracking it (fast-forward
  if it exists, `-f` resets). A fork's head, or a head that is itself a ref
  (AGit, deleted branch), is fetched from `refs/pull/<n>/head` into a local
  branch named after the head, or `pr-<n>` when that name is taken by a
  branch smith did not make for this pull request (a fork's `main` must not
  land on ours). smith records its branches as
  `branch.<name>.smith-pr = <n>`. Names from the server that start with `-`
  are refused before git sees them.
- **merge** picks `--merge|--squash|--rebase|--rebase-merge|--ff-only`, else
  the repository's `default_merge_style`; `--subject`, `--body` or
  `--body-file` set the commit message. `--auto` is
  `merge_when_checks_succeed`: Forgejo answers 201 when it schedules the
  merge and 200 when the checks had already passed and it merged at once,
  and smith reports which. `--admin` is `force_merge`. `-d` deletes the head
  branch on the server and, after an actual merge, the pull request's local
  branch: the one smith checked out for it, or a same-repository branch of
  the head's name tracking it, never a fork's namesake (switching to the
  base first, created from its remote if needed). 405 and 409 get their own
  messages.
- **checks** reads the combined commit status, so any CI that posts statuses
  shows, Forgejo Actions included; relative target URLs are made absolute.
  Exit 1 if something failed, 8 if something is pending, 0 otherwise. Piped,
  only the rows are printed.

- **review** takes exactly one of `--approve`, `--request-changes`,
  `--comment`; the last two need a body (flag, file, or the editor on a
  terminal), while an approval never opens the editor. The review is pinned to the head commit.
- **update-branch** (gh's name) merges the base into the head (or rebases with `--rebase`);
  409 is reported as a conflict to solve by hand.
- **status** sorts the repository's open pull requests into the current
  branch's (with its checks summary), yours, and those requesting your
  review. The current branch is matched as pushed, owner included, like
  `find`, so a fork's branch of the same name is not taken for it. "You" is the account's stored user, else `GET /user`.
- **list --head** filters on `branch` or `owner:branch` after fetching,
  since Forgejo's list endpoint cannot; like `-s merged`, it fetches up to
  four times the limit.

## Sources

- `src/cmd/pr.zig`
- `src/cmd/common.zig`
- `src/tests/pr_test.zig`
