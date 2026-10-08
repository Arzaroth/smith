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

## Development

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
- **`pr view` of a merged pull request** still says "wants to merge", and
  once its branch is deleted the head shows as `refs/pull/<n>/head`
  (Forgejo's ref then); gh says "merged" and keeps the branch name.
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
- **Verify installs beyond the same host's `SHA256SUMS`**: each forge builds
  its own release archives, which differ byte for byte (tar mtimes, gzip
  headers), so the installer cannot cross-check GitHub against Forgejo.
  Reproducible archives (fixed mtime and owner, `gzip -n`) would allow that;
  signing `SHA256SUMS` (minisign, key pinned in `install.sh`) would go
  further.
