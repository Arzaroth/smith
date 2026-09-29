# TODO

Deferred work, queued behind feature development.
Feature backlog with design notes lives in [ROADMAP.md](ROADMAP.md).

## Development

- **Smoke-test the write paths against the real instance.** Every write
  (create, comment, merge, close, cancel, login) is covered against the mock
  only; reads were exercised live on git.arzaroth.com and codeberg.org. Needs
  a token with `read:user`, `write:repository` and `write:issue`, and a
  scratch repository to open and merge pull requests in.
- **Strip the release binary.** ReleaseSafe is 10.9 MB with debug info;
  `strip` in `build.zig` for release builds should bring it down to a few MB.
- **`pr list -s merged` can come back short.** Forgejo has no merged filter,
  so smith fetches up to four times the limit of closed pull requests and
  keeps the merged ones; a repository with many closed-unmerged ones returns
  fewer than `-L`.
- **Report the std 0.16 HTTP client bugs upstream**: `privileged_headers`
  are never written by `sendHead`, and the overridable authorization header
  is kept across a redirect to another host (`lib/std/http/Client.zig`).
  smith works around both in `api.zig`.
- **`auth logout` does not revoke anything.** A token made by the password
  route stays valid until revoked in the web UI; revoking it needs basic auth
  again (`DELETE /users/{user}/tokens/{id}`), so logout could offer to ask for
  the password. Browser logins have no revocation endpoint in the API.
- **The browser login waits forever** for the redirect. A timeout (a few
  minutes, then a hint about `--password`) would suit SSH sessions where the
  opener did nothing visible.
- **Smoke-test the browser and password logins on git.arzaroth.com** with a
  real account: only the start of the browser flow and a wrong password were
  tried live.

## Deferred from the MVP review

- **A submit / cancel step for `pr create` and `issue create`** on a
  terminal, and exit code 2 on cancel, as gh does; today an empty editor
  buffer still submits.
- **Runs in `blocked` or `unknown` state** count as pending, so `run watch`
  waits on them indefinitely; decide whether to stop and say so.
- **The mock always closes connections**, so keep-alive behaviour (the 204
  bug the review found) is only covered by the code path, not a test.
