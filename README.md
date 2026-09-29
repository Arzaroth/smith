# smith

A command-line client for [Forgejo](https://forgejo.org), in the spirit of
`gh` and `glab`: clone repositories, open, check out and merge pull requests,
work issues and follow Actions runs without leaving the terminal.

> **Status: MVP.** Authentication, repositories, issues, pull requests and
> Actions runs work; [ROADMAP.md](ROADMAP.md) has the road to gh parity.

## Why another one

Forgejo already has `tea` (Gitea's CLI) and `fj` (forgejo-cli). smith copies
`gh`'s command surface specifically, so muscle memory carries over:
`smith pr checkout 42`, `smith run watch`, `smith issue list --label bug`.
It is also written in Zig, mostly because why not.

## Getting started

```sh
smith auth login --hostname git.example.com   # opens your browser to sign in
smith repo clone owner/repo
cd repo
```

Login opens the instance's sign-in page in your browser, like `gh auth login`,
and renews itself afterwards. Without a browser, or with `--password`, it asks
for your username, password and two-factor code and creates a token for
smith; `--with-token` reads one from standard input for scripts. It also
finds the SSH hostname your instance advertises, so
`git@ssh.example.com:owner/repo` remotes map back to `git.example.com`.

Inside a clone, smith works out the host and `owner/repo` from the git
remotes (`upstream`, then `origin`); `-R [HOST/]OWNER/REPO` overrides it
anywhere. Public repositories on an https remote work without logging in.

## Commands

```sh
smith pr list [--state open|closed|merged|all] [--author A] [--label L]
smith pr view [<n> | <branch>] [--comments] [--web] [--json]
smith pr create [--fill] [--draft] [--base B] [--label L] [--reviewer R]
smith pr checkout <n>
smith pr checks [<n>] [--watch]
smith pr merge [<n>] [--merge|--squash|--rebase|--ff-only] [--delete-branch] [--auto]
smith pr diff | comment | close | reopen | ready | edit

smith issue list [--state S] [--label L] [--assignee A] [--search Q]
smith issue view <n> [--comments]
smith issue create [--title T] [--body B] [--label L]
smith issue close | reopen | comment | edit

smith run list [--branch B] [--status S] [--workflow ci.yml]
smith run view [<id>] [--log | --log-failed] [--exit-status]
smith run watch [<id>]
smith run cancel <id>

smith repo clone [HOST/|HOST:]OWNER/REPO | view | list
smith auth login | status | logout | token
smith api <endpoint> [-X METHOD] [-f key=value] [-F key=typed] [--paginate]
smith browse [<n> | <path>[:<line>]] [--settings] [--actions]
smith completion bash|zsh|fish
```

Every command has `--help`. List and view commands take `--json` to print
the API objects as Forgejo sent them, for `jq`.

- Drafts are Forgejo's `WIP:` title prefix; `pr ready` removes it.
- `pr checks` reads commit statuses, so any CI that posts them shows up, not
  only Forgejo Actions. It exits 1 when a check failed and 8 while one is
  pending.
- `pr checkout` handles pull requests from forks through `refs/pull/<n>/head`.

## Configuration

`~/.config/smith/hosts.zon` (or `$XDG_CONFIG_HOME/smith`, or
`$SMITH_CONFIG_DIR`), mode 0600, written by `smith auth login`.

| Variable | Effect |
|---|---|
| `SMITH_TOKEN` | Token to use instead of the stored one |
| `SMITH_HOST` | Default host when not in a clone |
| `SMITH_CONFIG_DIR` | Where `hosts.zon` lives |
| `SMITH_EDITOR`, `VISUAL`, `EDITOR` | Editor for bodies |
| `SMITH_BROWSER`, `BROWSER` | Browser for `--web` |
| `NO_COLOR`, `CLICOLOR_FORCE` | Colour off, colour on |

## Shell completion

```sh
smith completion bash > ~/.local/share/bash-completion/completions/smith
smith completion zsh > "${fpath[1]}/_smith"
smith completion fish > ~/.config/fish/completions/smith.fish
```

## Building

Toolchain and tasks come from [mise](https://mise.jdx.dev):

```sh
mise install          # Zig 0.16.0, shellcheck
mise run build        # zig-out/bin/smith
mise run test         # unit and invocation tests (-Dtest-filter=... for a subset)
mise run check        # the gate: zig fmt --check, shellcheck, tests, ReleaseSafe build
```

The only dependency is the Zig standard library: HTTP, TLS and JSON included,
so the binary is static. Git operations shell out to your `git`, so SSH keys
and credential helpers behave exactly as they do in your terminal. How it all
fits together is in [brain/](brain/BRAIN.md).

## Licence

MIT, see [LICENSE](LICENSE).
