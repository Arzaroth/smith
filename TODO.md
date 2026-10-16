# TODO

Deferred work, queued behind feature development.
Feature backlog with design notes lives in [ROADMAP.md](ROADMAP.md).

## Try for real

The writes (a fork included), the browser login with its token refresh, and
the Secret Service keyring were exercised on git.arzaroth.com on 2026-09-29; these were not:

- **`gpg-key add/delete`**, and **`repo sync` of a fork that is behind** (the
  up-to-date case was tried on a fork of vyol/trading_bot).
- **The password login with TOTP** with a real account; only a wrong
  password was tried live.
- **The keyring on a Mac** (`security`); Linux's Secret Service works.
- **`auth setup-git` and the SSH key offer at login**: git cloning over
  HTTPS through `auth git-credential`, and `POST /user/keys` with a browser
  login's token and with a password login's basic credentials and 2FA code.

## Development

- **Hide `auth git-credential` from help, the man page and completions**, as
  gh does: it is plumbing for git. `cli.Command` has no hidden flag yet, and
  help, man and both completion walkers would each have to honour one.

- **Report the std 0.16 bugs upstream, in your own words**: Zig's code of
  conduct refuses LLM-written reports (codeberg ziglang/zig#31361, bug 2
  below, was closed for that reason), so these need writing by hand.
  Bugs 1 to 3 were checked against Zig master on 2026-09-29 and are still
  there.
  1. `http/Client.zig`: `privileged_headers` are never written by
     `sendHead`. Open fix: ziglang/zig pull 31741 ("std.http: fix message
     framing bugs"); support it rather than file a duplicate.
  2. `http/Client.zig`: the `headers.authorization` override is kept across
     a redirect to another host (only `privileged_headers` are dropped).
     Reported as ziglang/zig#31361 and closed unfixed under the policy.
  3. `Io/Threaded.zig` `netAcceptPosix`: `EAGAIN` from `accept` (a listener
     with `SO_RCVTIMEO`) is `errnoBug`, a panic in Debug, though
     `AcceptError` declares `WouldBlock`. Related, not the same:
     ziglang/zig#35284 (the same for receive timeouts).
  4. `http/Client.zig` `Request.deinit`: a 204 or 304 without a length is
     read until the server closes the connection, although `receiveHead`
     already knows such answers have no body (a DELETE's 204 stalls every
     kept-alive request after it). Found after the upstream search; look
     for an existing report first.
  5. `Io/Threaded.zig` Windows spawn: a `.file` stdio is reopened by name
     (`OpenFile` relative to the handle), which fails with
     `PIPE_NOT_AVAILABLE`, reported as `NoDevice`, when the handle is a
     pipe, as stderr is under the test runner.
  6. The aarch64 Windows Zig 0.16.0 crashes (`0xC0000005`, no output)
     compiling on GitHub's arm64 Windows runner, even an empty `main`,
     most times but not every time; the tests there run from a binary
     cross-compiled on Linux (`zig build test-exe`) instead.
  7. Wine 11 lacks the AFD socket ioctls `Io/Threaded.zig` uses on Windows
     (`INVALID_DEVICE_REQUEST` on `setsockopt`), so Windows test binaries
     cannot listen under Wine. Wine's side, not Zig's.
- **`pr view` of a merged pull request** still says "wants to merge", and
  once its branch is deleted the head shows as `refs/pull/<n>/head`
  (Forgejo's ref then); gh says "merged" and keeps the branch name.
- **`pr checks` flags against gh**: `--watch` with `--json` prints the table
  where gh refuses the pair, `--interval` without `--watch` is accepted
  where gh refuses it, and there is no `--fail-fast`.
- **`mise run coverage` with `-p`** reads `zig-out/coverage` whatever the
  prefix, and the keychain backend (`security`) is never run by a test: it
  is found on smith's `PATH` and would be the developer's real keychain.
- **`--template` leftovers**: `define`/`template`/`block`, gh's `regexMatch`
  (needs a regex engine), `html`/`js`/`urlquery`; tables are not cut to the
  terminal width. `truncate` and `tablerow` count codepoints where gh counts
  display width (wide characters misalign, and truncating coloured text
  can cut its escape); `%e` rounds the shortest decimal rather than the
  exact binary value (`%f` is exact); `timefmt` lacks `002` (day of year)
  and wants a non-letter after `January`/`Monday`; `{{089}}` is refused
  where Go reads a float. Two divergences the tests pin as they are (update
  `template.zig`'s tests with the fix): `{{range $v := .}}{{else}}{{$v = 1}}`
  drops the assignment where Go sets `$v`, and `color` gives up on a
  background attribute other than `h` (`red:blue+b`) where mgutz/ansi
  ignores it and keeps both colours.
- **Check `SHA256SUMS.asc` in the installers**: releases are one build,
  signed, on both forges, but `install.sh` and `install.ps1` only check
  `SHA256SUMS`. With `gpg` available they could verify it against the key
  fingerprint pinned in the script.
- **Windows leftovers**: a Credential Manager keyring backend, PowerShell
  completion (`smith completion powershell`, as gh has), an icon for the
  MSI, and Authenticode signing if a certificate ever comes along.
