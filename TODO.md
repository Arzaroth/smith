# TODO

Deferred work, queued behind feature development.
Feature backlog with design notes lives in [ROADMAP.md](ROADMAP.md).

## Hosting

- **GitHub push mirror**: `POST /api/v1/repos/Arzaroth/smith/push_mirrors` to
  `github.com/Arzaroth/smith`, same settings as the other mirrors
  (`interval: 8h0m0s`, `sync_on_commit: true`).
- **No runner picks up `.forgejo/workflows/ci.yml`.** The first run (run 1,
  job `gate`, `runs-on: docker`) sat in `waiting`. Either register a runner
  or switch `runs-on` to a label an existing runner carries.

## Development

- **An API token for smoke tests**, scopes `read:user`, `write:repository`,
  `write:issue`, so the MVP can be exercised against the real instance and
  not only the mock server.
- **Zig 0.16 `std.http.Client` + TLS against the real host**: confirm it
  negotiates with git.arzaroth.com before the client layer is built on it.
  If it cannot, the fallback is linking libcurl, which costs the static
  binary.
