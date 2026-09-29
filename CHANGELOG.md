# Changelog

All notable changes to smith are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `smith auth login` signs you in without making a token by hand: in the
  browser, like `gh auth login`, or in the terminal with your username,
  password and two-factor code. It picks the browser when the instance offers
  it and one can be opened; `--web`, `--password` and `--with-token` choose
  explicitly. A browser login renews itself.
- Login looks at what the instance offers first: Forgejo or Gitea and which
  version, browser sign-in, its page size, and the SSH hostname it advertises,
  so SSH remotes map back to the right host.
- `smith auth status`, `logout` and `token`. Logins are kept in
  `~/.config/smith/hosts.zon` with mode 0600; `SMITH_TOKEN` and `SMITH_HOST`
  override the file.
- smith works out the host and repository from the clone's git remotes
  (`upstream` first, then `origin`), or from `-R [HOST/]OWNER/REPO`.
- `smith repo clone`, `view` and `list`, taking `OWNER/REPO`, `HOST/OWNER/REPO`
  or `HOST:OWNER/REPO` (the SSH hostname works too). Cloning a fork adds an `upstream`
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
