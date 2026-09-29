# TODO

Deferred work, queued behind feature development.
Feature backlog with design notes lives in [ROADMAP.md](ROADMAP.md).

## Hosting

- **Create the repo on Forgejo** (`git.arzaroth.com/Arzaroth/smith`) and push
  `master`. No API token was available when the repo was scaffolded, so it
  exists locally only.
- **GitHub push mirror**: `POST /api/v1/repos/Arzaroth/smith/push_mirrors` to
  `github.com/Arzaroth/smith`, same settings as the other mirrors
  (`interval: 8h0m0s`, `sync_on_commit: true`).
- **Check a Forgejo Actions runner picks up `.forgejo/workflows/ci.yml`.** If
  the instance has none, the job just sits queued.

## Development

- **An API token for smoke tests**, scopes `read:user`, `write:repository`,
  `write:issue`, so the MVP can be exercised against the real instance and
  not only the mock server.
- **Zig 0.16 `std.http.Client` + TLS against the real host**: confirm it
  negotiates with git.arzaroth.com before the client layer is built on it.
  If it cannot, the fallback is linking libcurl, which costs the static
  binary.
