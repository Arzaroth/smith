# Roadmap

The agreed backlog, in delivery order, with the decisions taken on each item so
they are not lost. How things work lives in [brain/](brain/BRAIN.md); the
reasoning behind the shape is in [brain/decisions.md](brain/decisions.md).
Deferred chores that are not features go in [TODO.md](TODO.md).

The target is feature parity with `gh` (and the parts of `glab` Forgejo can
back), command for command, so existing muscle memory works. Where Forgejo has
no equivalent, the command is listed under Not planned rather than faked.

API reference: `https://<host>/swagger.v1.json`. Developed against Forgejo
16.0.5.

## P0 - Foundation

- [x] Zig 0.16 project, mise toolchain and tasks, `--help`/`--version`, gate
      (`mise run check`: fmt, shellcheck, tests, ReleaseSafe build).
- [x] Argument parsing: nested `<command> <subcommand>`, long and short flags,
      `--flag=value`, clustered short flags, repeatable and comma-separated
      values, `--` passthrough, per-command `--help`. Decided: hand-written
      over the standard library, no dependency; the command tree is data,
      and help and completion are generated from it.
- [x] Host config at `$XDG_CONFIG_HOME/smith/hosts.zon`, mode 0600, one entry
      per host: `token`, `user`, `git_protocol` (ssh|https), `ssh_host`,
      `scheme` (https default, http for LAN instances and tests).
      `SMITH_TOKEN`, `SMITH_HOST` and `SMITH_CONFIG_DIR` override. Decided:
      ZON, since `std.zon` reads and writes it with no dependency.
- [x] HTTP client over `std.http.Client`: token header, JSON decoded into
      structs that ignore unknown fields, API error messages surfaced, a 401
      pointing at `auth login`. Decided: page/limit pagination rather than
      `Link` headers, since the Actions endpoints do not send them; std's
      redirect handling off, same-host redirects followed by smith (std 0.16
      leaks the token across hosts and never sends privileged headers).
- [x] Repo resolution: `-R [host/]owner/repo`, else the git remotes
      (`upstream` before `origin`, then any), each read both as configured and
      after `insteadOf`, mapping `ssh_host` back to the API host.
- [x] Output: aligned tables and colour on a TTY only, tab-separated when
      piped, `NO_COLOR`/`CLICOLOR_FORCE`; relative times; `--json` dumps the
      API objects verbatim; `--web` opens the page. git's own output goes to
      stderr.
- [x] Test harness: a mock Forgejo served in the test binary, temporary git
      repos (with a bare repo behind `insteadOf` for `pr checkout`), no
      network and no real `$HOME`.
- [x] CI (`.github/workflows/ci.yml`): `mise run check`, on Forgejo Actions
      and on GitHub Actions through the mirror.

## P1 - MVP: clone, pull requests, issues, pipelines

- [x] `auth login` (token pasted without echo or `--with-token` on stdin,
      checked against `/api/v1/version` and `/api/v1/user`; a token without
      `read:user` is kept without a username), `auth status`, `auth logout`,
      `auth token`. `ssh_host` discovered from a repo's `ssh_url` at login.
- [x] `repo clone <owner/repo|repo|url> [dir] [-- <git flags>]`: protocol from
      config; a fork gets an `upstream` remote, like gh. `repo view [--web]`,
      `repo list [owner]`.
- [x] `pr list` (`--state open|closed|merged|all`, `--author`, `--label`,
      `--base`, `-L`), `pr view [<n>|<branch>] [--comments]`, `pr diff`
      (`--patch`, `--name-only`). Open question: `--head`, which Forgejo's
      list endpoint cannot filter on.
- [x] `pr create` (`--title`, `--body`, `--body-file`, `--fill`, `--base`,
      `--head`, `--draft`, `--label`, `--assignee`, `--reviewer`, `--web`).
      Decided: `--draft` is Forgejo's `WIP:` title prefix, since the API has no
      draft flag. Title prompted and body opened in `$EDITOR` on a TTY only.
      The branch must be pushed; a branch pushed to a fork opens as
      `owner:branch`.
- [x] `pr checkout <n>`: same-repo head tracks `<remote>/<branch>`; a fork's
      or headless pull request's head is fetched from `refs/pull/<n>/head`.
- [x] `pr merge <n>` (`--merge|--squash|--rebase|--rebase-merge|--ff-only`,
      default the repository's style, `--delete-branch`, `--auto` =
      `merge_when_checks_succeed`, `--admin`), `pr close`, `pr reopen`,
      `pr comment`, `pr ready` (drops `WIP:`), `pr edit`.
- [x] `pr checks <n> [--watch]`: the head commit's combined status. Decided:
      read commit statuses rather than Actions runs, so Woodpecker, Drone and
      other external CI show up too. Exit 1 on failure, 8 while pending.
- [x] `issue list` (`--state`, `--label`, `--assignee`, `--author`,
      `--mention`, `--search`, `-L`), `issue view [--comments]`,
      `issue create`, `issue close`, `issue reopen`, `issue comment`,
      `issue edit`.
- [x] `run list` (`--branch`, `--status`, `--event`, `--workflow`,
      `--commit`, `-L`), `run view [<id>]` (jobs and their status),
      `run view --log|--log-failed [--job <id>]`, `run watch [<id>]`,
      `run cancel <id>`. Forgejo Actions only (`/actions/runs`).
- [x] `browse [<path>|<n>]`, `api <path>` passthrough (`-X`, `-f`/`-F`,
      `--input`, `--paginate`, `-H`, `{owner}`/`{repo}`),
      `completion <bash|zsh|fish>`.
- [ ] Release pipeline: static binaries for x86_64/aarch64 Linux and macOS,
      attached to a Forgejo release and mirrored to GitHub.
## P2 - gh parity

- [ ] `pr review` (`--approve`, `--request-changes`, `--comment`),
      `pr status` (mine, review requested, current branch), `pr update`
      (merge or rebase base into head).
- [ ] `repo create`, `repo fork [--clone]`, `repo delete`, `repo edit`,
      `repo sync`, `repo archive`, `repo set-default`.
- [ ] `release list|view|create|upload|download|delete`.
- [ ] `label list|create|edit|delete`, `milestone` (glab has it, gh does not).
- [ ] `run rerun`, `run download` (artifacts), `workflow run` (dispatch).
- [ ] `secret` and `variable` (repo, org, user scopes).
- [ ] `search repos|issues|prs`, `status` (cross-repo dashboard),
      `notification` list and mark read.
- [ ] `ssh-key`, `gpg-key`, `org list`.
- [ ] `alias set|list|delete`, `config get|set|list`.
- [ ] `--jq` filtering on `--json` output, `--template` formatting.

## Later

- System keyring for tokens (Secret Service over D-Bus, macOS Keychain),
  keeping the 0600 file as the fallback.
- `$PAGER` for long output (`pr diff`, `run view --log`).
- OAuth2 device flow login, if Forgejo gains it.
- `pr checkout` into a new worktree.
- Packaging: AUR, Homebrew tap, Nix flake.

## Not planned

- `codespace`, `copilot`, `attestation`, `ruleset`, `cache`: no Forgejo
  equivalent.
- `gist`: Forgejo has no gists.
- `project`: Forgejo projects have no API.
