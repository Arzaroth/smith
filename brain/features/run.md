# run

Forgejo Actions runs (`/repos/{o}/{r}/actions/...`). A run is named by its
API id (what `run list` prints); the number in the web URL is
`index_in_repo`. Without an id, `view` and `watch` take the latest run of the
current branch.

| Command | Endpoints |
|---|---|
| `run list` | `GET .../actions/runs?ref=refs/heads/<b>&status=&event=&workflow_id=&head_sha=` |
| `run view [--log \| --log-failed] [-j id]` | `GET .../actions/runs/{id}`, `.../runs/{id}/jobs`, `.../actions/jobs/{job}/logs` |
| `run watch` | polls `GET .../actions/runs/{id}` and its jobs every `-i` seconds (default 3) |
| `run cancel` | `POST .../actions/runs/{id}/cancel` |
| `run download` | `GET .../actions/runs/{id}/artifacts`, `GET .../actions/artifacts/{id}/zip` |

- Statuses: `success`; `failure` and `cancelled` count as failed; `skipped`;
  `waiting`, `running`, `blocked` and `unknown` as pending. `watch` stops
  on `blocked` (a run from a fork waiting for approval, which no amount of
  waiting fixes) with exit 8, and on `unknown` with exit 1.
- `--exit-status` exits 1 for a failed run and, on `view`, 8 for one still
  running.
- Log lines are prefixed with the job name and a tab.
- `download` unpacks each artifact into `-D/<name>/` (through a temporary
  zip file streamed from the server, which `std.zip` needs), `-n` globs pick
  artifacts, expired ones are skipped with a warning. A destination that
  already exists is refused rather than merged into, and artifact names must
  be plain file names.
- No `rerun`: Forgejo's API has no endpoint for it.

## Sources

- `src/cmd/run.zig`
- `src/tests/run_test.zig`
