# workflow, secret, variable

**workflow**
- `list`: the workflow files of the first of `.forgejo/workflows`,
  `.gitea/workflows`, `.github/workflows` that exists, read through
  `/repos/{o}/{r}/contents/{dir}` (Forgejo has no workflow listing endpoint).
- `run <file>`: `POST .../actions/workflows/{file}/dispatches` with `ref`
  (`-r`, else the current branch, else the default branch), `inputs` from
  repeated `-f key=value`, and `return_run_info`, whose run id is offered to
  `smith run watch`. The workflow must declare `workflow_dispatch`.

**secret** and **variable** act on the current repository, an organization
(`--org`) or your account (`--user`):

| | Repository | Organization | User |
|---|---|---|---|
| secrets | `/repos/{o}/{r}/actions/secrets` | `/orgs/{org}/actions/secrets` | `/user/actions/secrets` (set and delete only) |
| variables | `/repos/{o}/{r}/actions/variables` | `/orgs/{org}/actions/variables` | `/user/actions/variables` |

- `secret set` reads the value from `--body`, else a no-echo prompt on a
  terminal, else stdin (trailing newline dropped). Values cannot be read back.
- `variable set` tries `PUT` (update) and falls back to `POST` (create) on a
  404; `variable get` prints the value.

## Sources

- `src/cmd/workflow.zig`
- `src/cmd/secret.zig`
- `src/tests/actions_test.zig`
