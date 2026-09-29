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
`.forgejo/workflows/`, which also keeps the mirror's GitHub PAT free of the
workflow scope.
