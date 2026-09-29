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

## Environment tokens are aimed at one host (2026-09-29)

`SMITH_TOKEN` used to replace the token of whatever host a command resolved
to, so with two hosts configured, or a clone pointing somewhere unexpected,
a token meant for one instance could be sent to another. It now reaches only
the default host; `SMITH_TOKEN_<HOST>` targets any other. gh splits the same
way (`GH_TOKEN` for github.com, `GH_ENTERPRISE_TOKEN` for `GH_HOST`).

## Accounts rather than hosts (2026-09-29)

The config holds one entry per *(host, user)* with one active per host,
rather than a nested map of hosts to accounts: every existing reader keeps
seeing a flat list and `Config.find` keeps returning one entry per host, so
only `auth` had to learn about accounts.

## Hostile servers are in the threat model (2026-09-29)

smith talks to instances the user may not control, reached from a clone's
remotes or a `-R` typo, so the max review of the MVP treated server data as
untrusted: a name from the API never reaches git where it could read as an
option (`--`, and refusing names that start with `-`), environment tokens go
only to exactly-named trusted https hosts, `--web` opens only http(s) URLs,
and control characters are stripped before server text reaches the
terminal.

## A fork's branch never lands on ours (2026-09-29)

`pr checkout` of a fork whose branch is called `main` used to fast-forward
the user's `main` onto the fork, and `-d` could delete a same-named branch
of the user's own. Checkouts now fall back to `pr-<n>` when the name is
taken, smith marks the branches it makes (`branch.<name>.smith-pr`), and `-d`
only deletes those, or a same-repository branch tracking the head.

## Piped output follows gh's machine format (2026-09-29)

Tables piped to another program print plain numbers, whole text, raw
timestamps and the state that colour carries on a terminal, so scripts
written against gh's piped output port over.

## The token follows the API, not the URL (2026-09-29)

Forgejo lets anyone who can edit a release add an external asset, whose
download URL is whatever they typed, and `release download` fetched it with
the token. Redirects already dropped the token off-host; now an absolute URL
gets it only when its scheme, host and port are the API's own, from the
first request.

## Scrub stderr as a whole (2026-09-29)

smith's confirmations and errors quote server text (titles, names, tags) in
some sixty places. Rather than wrapping each, stderr on a terminal goes
through `term.Scrubber`, which applies `term.clean`'s rule to everything
written, so a new message cannot forget. smith never writes escape sequences
to stderr itself; piped stderr stays byte-exact.

## Stream release assets and artifacts (2026-09-29)

Uploads and downloads used to be read whole into memory (up to 2 GiB for an
upload). They now stream between the file and the socket, and downloads land
in a temporary file renamed into place, so a failed transfer leaves nothing
half-written.

## Filtered lists read until they have enough (2026-09-29)

`pr list -s merged` and `--head` used to fetch four times `-L` and filter,
coming back short in busy repositories. They now read whole pages until `-L`
items pass or the list ends, which can mean many requests for a rare match;
a correct answer was preferred over a small bound. The max review added
a ceiling of 100 pages (with a warning) so a hostile or enormous server
cannot keep smith paging forever.

## Opt-in paging (2026-09-29)

Commands ask for the pager (`cli.Command.pages`) rather than smith paging
everything on a terminal: prompts, the editor, watch modes and `api` output
would fight a pager for the terminal. Lists, views and `pr diff` page, as in
gh.

## A blocked run ends the watch (2026-09-29)

Forgejo's `blocked` is a run from a fork waiting for someone to approve it,
which waiting will not change, so `run watch` stops with exit 8 (pending, as
gh reports) and says what it needs; `unknown` stops with exit 1.

## Agents get a reference and a skill, not an MCP server (2026-09-29)

Coding agents already have a shell, and smith already has `--json`, `--jq`
and non-interactive flags, so an MCP server would only restate the CLI and
drift from it. Instead `smith help reference` renders the command tree as
Markdown and `smith help skill` prints a `SKILL.md`; both come from the
binary, so what an agent reads always matches the smith it runs.
