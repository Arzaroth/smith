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
- **The release workflow on Forgejo**: v0.2.0 built its archives there but
  could not publish (`cannot reach server:3000: TlsInitializationFailed`,
  the runner reaches Forgejo over plain http). The workflow now writes smith
  a config entry for that host; check the next tag publishes, and whether
  the job token may create releases (if not, add a `RELEASE_TOKEN` secret
  with `smith secret set RELEASE_TOKEN`). GitHub published v0.2.0 fine.

## Development

- **Report the std 0.16 bugs upstream, in your own words**: Zig's code of
  conduct refuses LLM-written reports (codeberg ziglang/zig#31361, bug 2
  below, was closed for that reason), so these need writing by hand.
  Checked against Zig master on 2026-09-29; all four are still there.
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
     kept-alive request after it). Not reported anywhere yet.
- **`--template` leftovers**: `define`/`template`/`block`, gh's `regexMatch`
  (needs a regex engine), `html`/`js`/`urlquery`; tables are not cut to the
  terminal width.
