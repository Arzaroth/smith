# issue

| Command | Endpoints |
|---|---|
| `issue list` | `GET /repos/{o}/{r}/issues?type=issues&state=&labels=&q=&created_by=&assigned_by=&mentioned_by=` |
| `issue view <n> [--comments]` | `GET .../issues/{n}`, `GET .../issues/{n}/comments` |
| `issue create` | `GET .../labels` (and `/orgs/{o}/labels`) to map names, `POST .../issues` |
| `issue close/reopen <n> [-c comment]` | `POST .../comments` first, then `PATCH .../issues/{n}` `{state}` |
| `issue comment <n>` | `POST .../issues/{n}/comments` |
| `issue edit <n>` | `PATCH` title/body/assignees, `POST .../labels`, `DELETE .../labels/{id}` |

- Label names are matched case-insensitively against the repository's and,
  for an organization, the organization's labels; an unknown name fails
  before anything is written.
- Bodies come from `--body`, `--body-file` (`-` for stdin), else the editor on
  a terminal (`SMITH_EDITOR`, `VISUAL`, `EDITOR`, `vi`), else empty. A title
  is prompted for on a terminal; without one, `--title` and `--body` are
  both required, as in gh. `create` on a terminal, unless both came as
  flags, ends with submit, edit the body again, or cancel (exit 2); Ctrl-D
  cancels too.
- Closing an already closed issue warns and does nothing.
- The issue endpoints also back pull request comments, labels and assignees
  ([pr.md](pr.md)); the shared code is `cmd/common.zig`.

## Sources

- `src/cmd/issue.zig`
- `src/cmd/common.zig`
- `src/tests/issue_test.zig`
