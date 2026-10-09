# smith

A command-line client for [Forgejo](https://forgejo.org), in the spirit of
`gh` and `glab`: clone repositories, open, review and merge pull requests,
work issues, follow Actions runs, cut releases, without leaving the terminal.

> **Status: feature complete** against `gh`'s command surface, wherever
> Forgejo's API can back it ([ROADMAP.md](ROADMAP.md) says what cannot).

## Why another one

Forgejo already has `tea` (Gitea's CLI) and `fj` (forgejo-cli). smith copies
`gh`'s command surface specifically, so muscle memory carries over:
`smith pr checkout 42`, `smith run watch`, `smith issue list --label bug`.
It is also written in Zig, mostly because why not.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh
```

This installs the latest release into `~/.local/bin` (`--dir` or
`SMITH_INSTALL_DIR` to change it): a static binary for Linux (x86_64,
aarch64) or macOS (Intel, Apple silicon), checked against the release's
`SHA256SUMS` (which catches a corrupted download; it comes from the same
release, so it is not a signature). Running it again upgrades in place, or
says smith is up to date. Pass options after `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh -s -- --version 0.3.0
curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh -s -- --dev
```

`--dev` builds the tip of master from source (a minute or two) with Zig
0.16.0: yours if it is on `PATH`, else through mise, else a download from
ziglang.org checked against its published checksum; `smith --version` then
says `<version>-dev+<commit>`. `--from forgejo` downloads from git.arzaroth.com
(releases from 0.3.0 on) instead of GitHub. Other systems (Windows,
FreeBSD, 32-bit ARM) can build it (below). To uninstall, delete the
binary; `smith auth logout` first removes its tokens from the keyring, and
`~/.config/smith` holds its settings.

### Packages

On Debian and Ubuntu, each release has a `.deb` for amd64 and arm64, and
on Fedora, openSUSE and other RPM systems an `.rpm` for x86_64 and aarch64
(the same static binary, with shell completions):

```sh
sudo apt install ./smith-cli_<version>_amd64.deb
sudo dnf install ./smith-cli-<version>-1.x86_64.rpm
```

For Arch, PKGBUILDs for `smith-cli` (built from source) and `smith-cli-bin`
(the release binary) are in `packaging/arch`; they are not on the AUR yet.
In a checkout, `mise run aur <version>` fills them in for a published release
under `dist/aur`, ready for `makepkg -si`. They are `smith-cli` because the
AUR's `smith` is an unrelated text editor with a `smith` of its own; the
command is `smith` either way.

## Getting started

```sh
smith auth login --hostname git.example.com   # opens your browser to sign in
smith repo clone owner/repo
cd repo
```

Login opens the instance's sign-in page in your browser, like `gh auth login`,
and renews itself afterwards. Without a browser, or with `--password`, it asks
for your username, password and two-factor code and creates a token for
smith; `--with-token` reads one from standard input for scripts. The token
goes to your system keyring (Secret Service on Linux, the keychain on macOS)
when there is one. Login also finds the SSH hostname your instance
advertises, so `git@ssh.example.com:owner/repo` remotes map back to
`git.example.com`.

Inside a clone, smith works out the host and `owner/repo` from the git
remotes (`upstream`, then `origin`; `smith repo set-default` picks another);
`-R [HOST/]OWNER/REPO` overrides it anywhere. Public repositories on an https
remote work without logging in.

## Commands

```sh
smith pr list | view | diff | create | checkout | merge | checks | review
smith pr status | update-branch | ready | comment | close | reopen | edit
smith issue list | view | create | close | reopen | comment | edit
smith repo clone | view | list | create | fork | edit | sync | archive | delete | set-default
smith run list | view | watch | cancel | download
smith workflow list | run
smith release list | view | create | edit | upload | download | delete
smith label list | create | edit | delete | clone
smith milestone list | view | create | edit | close | reopen | delete
smith secret list | set | delete          # --org ORG or --user for other scopes
smith variable list | get | set | delete
smith search repos | issues | prs
smith status                              # what needs you across the host
smith notification list | read
smith ssh-key | gpg-key list | add | delete
smith org list
smith auth login | status | switch | logout | token
smith alias set | list | delete | import
smith config get | set | unset | list
smith api <endpoint> [-X METHOD] [-f key=value] [-F key=typed] [--paginate]
smith browse [<n> | <path>[:<line>]] [--settings] [--actions]
smith completion bash | zsh | fish
smith help [<command>] | reference | skill
```

Every command has `--help`. Commands that show API objects take `--json` to
print them as Forgejo sent them, `-q/--jq EXPR` to filter them with jq, and
`-t/--template` for a Go-style template:

```sh
smith pr list -q '.[].head.ref'
smith release view -t '{{.tag_name}}: {{len .assets}} assets{{"\n"}}'
smith issue list -t '{{range .}}#{{.number}} {{.title}} ({{timeago .updated_at}}){{"\n"}}{{end}}'
smith pr list -t '{{range .}}{{tablerow (printf "#%v" .number | autocolor "green") .title .head.ref}}{{end}}'
```

- Drafts are Forgejo's `WIP:` title prefix; `pr ready` removes it.
- `pr checks` reads commit statuses, so any CI that posts them shows up, not
  only Forgejo Actions. It exits 1 when a check failed and 8 while one is
  pending.
- `pr checkout` handles pull requests from forks through `refs/pull/<n>/head`,
  as `pr-<n>` when the fork's branch is named like one of yours.
- Piped, lists print plain numbers, whole text, timestamps and a state
  column, like gh's machine format. Exit codes follow gh: 1 on failure, 4
  when authentication failed, 8 while checks are pending.
- Deleting anything asks first on a terminal, and needs `--yes` without one.

## Several hosts and accounts

Log in to as many instances as you like; inside a clone, the remotes decide
which one a command talks to. Outside one, smith uses the default host: the
first you logged in to, until `smith auth switch --hostname other.example`.

Logging in to the same host as another user adds an account rather than
replacing the first. `smith auth switch` flips between them (`--user` picks
one), `smith auth status` shows which is active, and `auth logout` / `auth
token` take `--user`.

`SMITH_TOKEN` is only ever sent to the default host, so a token cannot leak
to another instance; `SMITH_TOKEN_<HOST>` sets one for a specific host.

## Aliases and preferences

```sh
smith alias set co 'pr checkout'
smith alias set bugs 'issue list --label bug --assignee $1'
smith alias set standup '!smith status && smith notification list'
smith config set editor 'nvim'
smith config set pager 'less -R'
smith config set -h git.example.com git_protocol https
smith alias import aliases.yml             # gh's alias file
```

`$1`… take the alias's arguments (a missing one is an error), extra
arguments are appended, and a leading `!` (or `--shell`) runs the rest with
`sh`. An alias can never take a smith command's name, and replacing one
needs `--clobber`; `alias import` reads gh's YAML alias file.
Preferences (`git_protocol` for new logins, or per host with `-h`,
`editor`, `browser`, `pager`, and `prompt disabled` to never ask) and
aliases live in `config.zon`.

## Configuration

`~/.config/smith/` (or `$XDG_CONFIG_HOME/smith`, or `$SMITH_CONFIG_DIR`)
holds `hosts.zon` (mode 0600: hosts and accounts, and tokens when there is no
keyring) and `config.zon` (preferences and aliases).

| Variable | Effect |
|---|---|
| `SMITH_TOKEN` | Token for the default host only (its exact name, https unless configured) |
| `SMITH_TOKEN_<HOST>` | Token for one host, e.g. `SMITH_TOKEN_GIT_EXAMPLE_COM` |
| `SMITH_HOST` | Default host when not in a clone |
| `SMITH_CONFIG_DIR` | Where the config files live |
| `SMITH_KEYRING` | `none` to keep tokens in `hosts.zon`, or `secret-tool` / `security` |
| `SMITH_LOGIN_TIMEOUT` | Seconds the browser login waits (default 300) |
| `SMITH_EDITOR`, `VISUAL`, `EDITOR` | Editor for bodies (`config set editor` sits after `SMITH_EDITOR`) |
| `SMITH_BROWSER`, `BROWSER` | Browser for `--web` (`config set browser` sits after `SMITH_BROWSER`) |
| `SMITH_PAGER`, `PAGER` | Pager for lists, views and diffs on a terminal (`config set pager` sits between them; `cat`, or `SMITH_PAGER=` empty, for none) |
| `SMITH_PROMPT_DISABLED` | Never prompt, as if `config set prompt disabled` |
| `SMITH_JQ` | The jq program `--jq` runs |
| `NO_COLOR`, `CLICOLOR_FORCE` | Colour off, colour on |

## For coding agents

`smith help reference` prints every command, flag, exit code and
environment variable as one Markdown page, generated from the command tree.
`smith help skill` prints a skill that teaches Claude Code (or any agent
that reads `SKILL.md` files) to use smith: install it once with

```sh
mkdir -p ~/.claude/skills/smith
smith help skill > ~/.claude/skills/smith/SKILL.md
```

## Shell completion

```sh
smith completion bash > ~/.local/share/bash-completion/completions/smith
smith completion zsh > "${fpath[1]}/_smith"
smith completion fish > ~/.config/fish/completions/smith.fish
```

## Building

Toolchain and tasks come from [mise](https://mise.jdx.dev):

```sh
mise install          # Zig 0.16.0, shellcheck, nfpm
mise run build        # zig-out/bin/smith
mise run test         # unit and invocation tests (-Dtest-filter=... for a subset)
mise run check        # the gate: zig fmt --check, shellcheck, installer and packaging checks, tests, ReleaseSafe build
mise run dist         # release archives, .deb and .rpm packages and the source tarball in dist/
mise run aur 0.5.0    # the Arch PKGBUILDs for a published release, in dist/aur
mise run coverage     # line coverage under kcov (needs kcov installed)
```

The only dependency is the Zig standard library: HTTP, TLS and JSON included,
so the binary is static. Git operations shell out to your `git`, so SSH keys
and credential helpers behave exactly as they do in your terminal; `--jq`
uses your `jq`, and the keyring its command-line helper. How it all fits
together is in [brain/](brain/BRAIN.md).

## Licence

MIT, see [LICENSE](LICENSE).
