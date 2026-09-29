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

## Deferred from the gh-parity review

- **`--template` beyond the basics**: pipes, variables, `with`, `printf`,
  comparisons and gh's helpers (`tablerow`/`tablerender`, `truncate`,
  `color`, `pluck`, `timefmt`, `hyperlink`); the error should name the
  action it choked on rather than repeat the whole template.
- **More of gh's config and alias surface**: `pager`, `prompt` and friends,
  per-host keys (`-h`), `alias set <name> -` (from stdin), `alias delete
  --all`, `alias import`.
- **`pr list --head` on the server**: Forgejo documents a `head` filter on
  `/pulls`; check its format across versions before dropping the
  client-side filter.
- **`release edit --latest`** only clears the pre-release flag; Forgejo has
  no way to promote an older release to latest.
- **Pin `actions/checkout` to a commit** in the workflows, once it is clear
  the Forgejo runner's action mirror carries the same commits as GitHub.
- **`smith status` test routes**: only the review-request section has a
  route of its own, so a wrong filter on the other three would pass.
- **`--jq` tests need jq installed** and pass silently without it.
