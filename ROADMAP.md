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
      (`mise run check`: fmt, tests, ReleaseSafe build).
- [ ] Argument parsing: nested `<command> <subcommand>`, long and short flags,
      `--flag=value`, repeated flags, `--` passthrough, per-command `--help`.
      Decided: hand-written over the standard library, no dependency (the
      command tree is static and small enough to declare as data).
- [ ] Host config at `$XDG_CONFIG_HOME/smith/hosts.zon`, mode 0600, one entry
      per host: `token`, `user`, `git_protocol` (ssh|https), `ssh_host`
      (the SSH hostname when it differs from the web one, e.g. `box.` vs
      `git.`), `scheme` (https default, http allowed for LAN instances and
      tests). `SMITH_TOKEN` and `SMITH_HOST` override. Open question: ZON or
      JSON for the file (ZON reads nicer, JSON is what every other tool can
      edit).
- [ ] HTTP client over `std.http.Client`: token auth header, JSON decode into
      structs that ignore unknown fields, API error bodies surfaced as
      `smith: <message> (HTTP 404)`, `Link`/`X-Total-Count` pagination.
- [ ] Repo resolution: `-R [host/]owner/repo`, else parse git remotes
      (`upstream` before `origin`, then any), mapping `ssh_host` back to the
      API host. Handles `git@h:o/r.git`, `ssh://git@h[:port]/o/r.git`,
      `https://h/o/r(.git)`.
- [ ] Output: aligned tables and colour on a TTY only, honouring `NO_COLOR`;
      relative times ("3 hours ago"); `--json` dumps the API objects verbatim;
      `--web` opens the page with `xdg-open`/`open`.
- [ ] Test harness: a local HTTP mock server in the test binary, temporary
      git repos, no network and no real `$HOME`.
- [ ] CI (`.github/workflows/ci.yml`): `mise run check`, on Forgejo Actions
      and on GitHub Actions through the mirror.

## P1 - MVP: clone, pull requests, issues, pipelines

- [ ] `auth login` (token pasted or `--with-token` on stdin, checked against
      `/api/v1/version` and `/api/v1/user`; a token without `read:user` still
      works, the user is then asked for), `auth status`, `auth logout`,
      `auth token`. `ssh_host` discovered from a repo's `ssh_url` at login.
- [ ] `repo clone <owner/repo|repo|url> [dir] [-- <git flags>]`: protocol from
      config; a fork gets an `upstream` remote, like gh. `repo view [--web]`,
      `repo list [owner]`.
- [ ] `pr list` (`--state open|closed|merged|all`, `--author`, `--label`,
      `--base`, `--head`, `-L`), `pr view [<n>|<branch>] [--comments]`, `pr diff`.
- [ ] `pr create` (`--title`, `--body`, `--body-file`, `--fill`, `--base`,
      `--head`, `--draft`, `--label`, `--assignee`, `--reviewer`, `--web`).
      Decided: `--draft` is Forgejo's `WIP:` title prefix, since the API has no
      draft flag. Title prompted and body opened in `$EDITOR` on a TTY only.
- [ ] `pr checkout <n>`: same-repo head tracks `<remote>/<branch>`; a fork's
      head is fetched from `refs/pull/<n>/head`.
- [ ] `pr merge <n>` (`--merge|--squash|--rebase|--rebase-merge|--ff-only`,
      `--delete-branch`, `--auto` = `merge_when_checks_succeed`),
      `pr close`, `pr reopen`, `pr comment`, `pr ready` (drops `WIP:`).
- [ ] `pr checks <n> [--watch]`: the head commit's combined status. Decided:
      read commit statuses rather than Actions runs, so Woodpecker, Drone and
      other external CI show up too.
- [ ] `issue list` (`--state`, `--label`, `--assignee`, `--author`,
      `--search`, `-L`), `issue view [--comments]`, `issue create`,
      `issue close`, `issue reopen`, `issue comment`, `issue edit`.
- [ ] `run list` (`--branch`, `--status`, `--event`, `-L`), `run view <id>`
      (jobs and their status), `run view --log [--job <id>]`, `run watch <id>`,
      `run cancel <id>`. Forgejo Actions only (`/actions/runs`).
- [ ] `browse [<path>|<n>]`, `api <path>` passthrough (`-X`, `-f`/`-F`,
      `--paginate`, `-H`), `completion <bash|zsh|fish>`.
- [ ] Release pipeline: static binaries for x86_64/aarch64 Linux and macOS,
      attached to a Forgejo release and mirrored to GitHub.

## P2 - gh parity

- [ ] `pr review` (`--approve`, `--request-changes`, `--comment`), `pr edit`,
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
