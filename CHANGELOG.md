# Changelog

All notable changes to smith are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `smith auth login`, `status`, `logout` and `token`: a token per Forgejo host,
  stored in `~/.config/smith/hosts.zon` with mode 0600, checked against the
  instance at login. Login also finds the SSH hostname the instance
  advertises, so SSH remotes map back to the right host. `SMITH_TOKEN` and
  `SMITH_HOST` override the file.
- smith works out the host and repository from the clone's git remotes
  (`upstream` first, then `origin`), or from `-R [HOST/]OWNER/REPO`.
- `smith repo clone`, `view` and `list`. Cloning a fork adds an `upstream`
  remote for its parent.
- `smith issue list`, `view`, `create`, `close`, `reopen`, `comment` and
  `edit`, with labels by name, assignees, comments, and bodies from a flag, a
  file, standard input or your editor.
- `smith pr list`, `view`, `diff`, `create`, `checkout`, `merge`, `close`,
  `reopen`, `comment`, `ready`, `edit` and `checks`. Drafts are Forgejo's
  `WIP:` prefix; `pr create --fill` takes the title and body from the commits
  and opens from a fork when the branch is pushed to one; `pr checkout`
  handles forks; `pr merge` supports every Forgejo merge style, `--auto` and
  `--delete-branch`; `pr checks` shows every commit status and can `--watch`.
- `smith run list`, `view` (with `--log` and `--log-failed`), `watch` and
  `cancel` for Forgejo Actions.
- `smith api` for any API endpoint, `smith browse` to open a repository,
  issue, pull request or file, and `smith completion` for bash, zsh and fish.
- `--json` on list and view commands prints the API objects as Forgejo sent
  them; `--web` opens the page instead.
- `smith --help` and `smith --version`.
