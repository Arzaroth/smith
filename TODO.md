# TODO

Deferred work, queued behind feature development.
Feature backlog with design notes lives in [ROADMAP.md](ROADMAP.md).

## Hosting

- **Cancel Forgejo run 1.** It was queued from the first workflow
  (`runs-on: docker`, a label no runner carries) and sits in `waiting`
  forever: `POST /api/v1/repos/Arzaroth/smith/actions/runs/142/cancel`.

## Development

- **An API token for smoke tests**, scopes `read:user`, `write:repository`,
  `write:issue`, so the MVP can be exercised against the real instance and
  not only the mock server.
- **Zig 0.16 `std.http.Client` + TLS against the real host**: confirm it
  negotiates with git.arzaroth.com before the client layer is built on it.
  If it cannot, the fallback is linking libcurl, which costs the static
  binary.
