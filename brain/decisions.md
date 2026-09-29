# Decisions

Non-obvious choices and why they were made. Append, do not rewrite history;
when a decision is reversed, add the reversal with its reason.

## Zig, standard library only (2026-09-29)

Chosen for fun over Rust, which the sibling tools (remuda, selvedge) use. The
cost is a pre-1.0 language whose standard library breaks between releases, so
the Zig version is pinned in `.mise.toml` and bumped deliberately. No
third-party packages: the standard library covers HTTP, TLS and JSON, and
every dependency would be one more thing to port on each Zig bump.

## Shell out to git (2026-09-29)

Clone, fetch and checkout run the user's `git` rather than a library, so SSH
keys, agents, credential helpers and `insteadOf` rewrites behave exactly as
they do in the terminal.

## gh's command surface (2026-09-29)

Commands and flags copy `gh` wherever Forgejo can back them, so muscle memory
carries over. Where Forgejo has no equivalent (gists, codespaces), the command
is absent rather than approximated.

## Forgejo first, GitHub mirror (2026-09-29)

The repo lives on git.arzaroth.com and is push-mirrored to GitHub, so smith is
developed through its own pull requests and pipelines. CI lives in
`.github/workflows/`, like the sibling repos: Forgejo's runners read it too,
and the same file runs on both sides of the mirror, so it installs mise with
the `mise.run` script rather than an action only one side can resolve. The
mirror's GitHub token therefore needs the Workflows permission.

## One arena per invocation (2026-09-29)

Every command allocates from the process arena and frees nothing
individually. An invocation lives for a few HTTP calls, so per-object
ownership would add error paths without saving memory. Tests wrap the same
code in an arena over `std.testing.allocator`.

## ZON for the config file (2026-09-29)

`hosts.zon` rather than JSON or TOML: `std.zon` parses and serialises it with
no dependency, and it reads like the rest of the project. The file is small
and edited by `smith auth` far more often than by hand.

## Auth header and redirects handled by smith (2026-09-29)

Zig 0.16's HTTP client never sends `privileged_headers`, and the standard
authorization header it does send is kept on a redirect to any host. smith
therefore sends the token through the standard header, turns std's redirects
off, and follows a redirect only within the same scheme, host and port. The
bug was invisible in manual testing against public repositories, which is
why the mock records the authorization header.

## git's output on stderr (2026-09-29)

Commands that run git (`repo clone`, `pr checkout`, `pr merge -d`) send its
stdout to smith's stderr: smith's stdout is for what smith produces, so it
can be piped. The test runner makes this a hard rule too, since a test
binary's stdout is the build runner's protocol pipe.

## Remotes matched on both URLs (2026-09-29)

A remote identifies the forge either by the URL git fetches from (after
`insteadOf`) or by the URL as configured. Aliases like `fj:owner/repo` only
parse after rewriting; a rewrite to a local mirror only parses before it.

## Drafts as a title prefix (2026-09-29)

Forgejo has no draft flag in its API; its UI treats a `WIP:` title prefix as a
draft. `pr create --draft`, `pr ready` and the `draft` state in `pr list`
work on that prefix.

## Checks from commit statuses (2026-09-29)

`pr checks` reads the head commit's combined status rather than Actions runs,
so Woodpecker, Drone and anything else that posts statuses shows up next to
Forgejo Actions.

## Login without handling tokens (2026-09-29)

Creating a token by hand is not a login. `auth login` offers the browser
(OAuth authorization code with PKCE and a loopback redirect, like gh) and the
terminal (username, password and TOTP, which create a scoped token, like tea),
and chooses between them from what the instance and the machine offer.
Pasting a token stays as `--with-token` for scripts.

For the browser route smith borrows Forgejo's built-in public clients (`tea`,
then `git-credential-oauth`) rather than asking every user to register an
application: they exist on default installs and accept any loopback port.
The cost is a consent screen naming that client. An instance without them
gets a one-time registration, remembered per host.

## Capabilities probed, not assumed (2026-09-29)

Instances differ by version, fork (Forgejo or Gitea) and configuration. What
smith depends on is learnt at login from unauthenticated endpoints, including
whether a built-in OAuth client exists, told apart by the token endpoint's
`invalid_client` versus any other error for a made-up code.
