# smith

A command-line client for [Forgejo](https://forgejo.org), in the spirit of
`gh` and `glab`: clone repositories, open and merge pull requests, work
issues and watch pipelines without leaving the terminal.

> **Status: pre-alpha.** The binary builds and answers `--help` and
> `--version`; nothing else works yet. [ROADMAP.md](ROADMAP.md) has the plan.

## Why another one

Forgejo already has `tea` (Gitea's CLI) and `fj` (forgejo-cli). smith aims at
`gh`'s command surface specifically, so muscle memory carries over:
`smith pr checkout 42`, `smith run watch`, `smith issue list --label bug`.
It is also written in Zig, mostly because why not.

## What it will do (MVP)

```sh
smith auth login --hostname git.example.com
smith repo clone owner/repo
smith pr list
smith pr create --fill
smith pr checkout 42
smith pr checks 42 --watch
smith pr merge 42 --squash --delete-branch
smith issue list --label bug
smith issue create --title "It broke"
smith run list
smith run view 1234 --log
```

Inside a clone, smith works out the host and `owner/repo` from the git
remotes; `-R owner/repo` overrides it anywhere.

## Building

Toolchain and tasks come from [mise](https://mise.jdx.dev):

```sh
mise install          # Zig 0.16.0
mise run build        # zig-out/bin/smith
mise run test         # unit tests
mise run check        # the gate: zig fmt --check, shellcheck, tests, ReleaseSafe build
```

The only dependency is the Zig standard library: HTTP, TLS and JSON included.
Git operations shell out to your `git`, so SSH keys and credential helpers
behave exactly as they do in your terminal.

## Licence

MIT, see [LICENSE](LICENSE).
