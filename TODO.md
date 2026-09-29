# TODO

Deferred work, queued behind feature development.
Feature backlog with design notes lives in [ROADMAP.md](ROADMAP.md).

## Try for real

Everything below is covered against the mock only; reads were exercised
live on git.arzaroth.com and codeberg.org.

- **The writes against git.arzaroth.com**, with a scratch repository: create,
  comment, merge, close, cancel, release create/upload, labels, milestones,
  secrets, variables, repo create/fork/edit/delete, keys.
- **Both logins with a real account**: the browser round trip (consent
  screen, refresh an hour later) and the password route with TOTP. Only the
  start of the browser flow and a wrong password were tried live.
- **The keyring with the real Secret Service** (KDE Wallet or GNOME Keyring
  here) and on a Mac. Tests only drive a fake secret-tool.
- **The release workflow on both forges**: tag a pre-release and check the
  archives land on git.arzaroth.com and GitHub. Whether Forgejo's job token
  may create releases is unknown; if not, add a `RELEASE_TOKEN` secret
  (`smith secret set RELEASE_TOKEN`).

## Development

- **`pr list -s merged` and `--head` can come back short.** Forgejo cannot
  filter on either, so smith fetches up to four times the limit and filters;
  a repository with many other pull requests returns fewer than `-L`.
- **Report the std 0.16 bugs upstream** (`lib/std/http/Client.zig`):
  `privileged_headers` are never written by `sendHead`; the overridable
  authorization header is kept across a redirect to another host; and in
  `Io/Threaded.zig`, `EAGAIN` from `accept` is a debug panic. smith works
  around all three.

## Deferred from the MVP review

- **A submit / cancel step for `pr create` and `issue create`** on a
  terminal, and exit code 2 on cancel, as gh does; today an empty editor
  buffer still submits.
- **Runs in `blocked` or `unknown` state** count as pending, so `run watch`
  waits on them indefinitely; decide whether to stop and say so.
- **The mock always closes connections**, so keep-alive behaviour (the 204
  bug the review found) is only covered by the code path, not a test.
