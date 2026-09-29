# Changelog

All notable changes to smith are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Boolean flags take `=true` and `=false` as in gh: `repo edit
  --enable-wiki=false`.
- `issue view` and `pr view` show the milestone.
- `repo list` takes gh's `--fork`, `--source`, `--visibility`, `--archived`
  and `--no-archived`.

### Fixed

- `milestone create --due` meant the end of that day in UTC, so a Forgejo
  east of UTC stored the next day; it is now the end of the day where you
  are, and due dates show as local days.
- `pr merge` waits while Forgejo is still checking the branch (right after a
  push or `pr update-branch`) instead of failing with "try again later".
- `pr merge -d` fast-forwards the base branch it switches to.
- `secret delete` and `variable delete` ask first and take `--yes`, like
  every other deletion.
- `repo sync` on a fork that is already up to date says so instead of
  failing with Forgejo's "You can't sync this branch".

## [0.3.1] - 2026-09-29

### Added

- `install.sh`: `curl -fsSL https://raw.githubusercontent.com/Arzaroth/smith/master/install.sh | sh`
  installs the latest release (or `--version`), checked against the
  release's `SHA256SUMS`; `--dev` builds master from source.

### Fixed

- `smith --version` works without `HOME` set.

## [0.3.0] - 2026-09-29

### Added

- `smith config` has `pager` (with `SMITH_PAGER` and `PAGER`; lists, views
  and diffs page on a terminal) and `prompt` (`disabled`, or
  `SMITH_PROMPT_DISABLED`, never asks), and `-h HOST` for a host's own
  `git_protocol`.
- `smith alias import` reads gh's alias file; `alias set NAME -` reads the
  expansion from standard input; `alias delete --all`.
- `issue create` and `pr create` on a terminal end with submit, edit the
  body again, or cancel (exit 2).
- `SMITH_JQ` picks the jq program; jq's own error message is shown.
- `smith help reference` prints every command and flag as Markdown;
  `smith help skill` prints a SKILL.md so coding agents know how to use
  smith; `smith help <command>` shows a command's help, and `help
  environment`, `exit-codes` and `formatting` are gh's help topics.
- `smith api` takes `--jq` and `--template`.
- `--template` covers Go's text/template as gh documents it: pipelines,
  variables, `with`, `else if`, `printf`, comparisons, and gh's `tablerow`,
  `tablerender`, `truncate`, `color`, `autocolor`, `hyperlink`, `timefmt`,
  `pluck` and `contains`; errors name their position.

### Changed

- `run watch` stops on a run that needs approval (exit 8) or whose status
  Forgejo does not know (exit 1) instead of waiting forever.
- `pr list -s merged` and `--head` read on until they have `-L` results;
  `--head` lets Forgejo 16 narrow the list on the server.

### Fixed

- Piping smith into a program that stops reading early (`| head`) no
  longer ends with `smith: WriteFailed`.
- A request after a 204 no longer waits for the server to close the
  connection (seconds per `release upload --clobber`, `label delete` and
  similar on a kept-alive connection).
- The release workflow can publish on Forgejo, whose runner reaches the
  server over plain http.

## [0.2.0] - 2026-09-29

### Added

- Tokens are kept in the system keyring (Secret Service on Linux, the keychain
  on macOS) when there is one, and in `hosts.zon` otherwise or with
  `auth login --insecure-storage`. The browser login gives up after five
  minutes without a sign-in.
- `smith pr review` (approve, request changes, comment), `pr status`,
  `pr update-branch`, and `pr list --head`.
- `smith repo create` (also from a local clone, with `--push`), `fork`,
  `edit`, `sync` (a fork from its parent, a mirror from its source),
  `archive`, `unarchive`, `delete` and `set-default`.
- `smith release` list, view, create with assets, edit, upload, download,
  delete and delete-asset.
- `smith label` (with `clone` from another repository) and `smith milestone`;
  `--milestone` on issues and pull requests.
- `smith run download` unpacks a run's artifacts; `smith workflow list` and
  `workflow run` dispatch a workflow with inputs (`-F`, with `@file`, and
  `-f`, as in gh).
- `smith secret` and `smith variable`, for a repository, an organization or
  your account.
- `smith search` (repositories, issues, pull requests), `smith status` (what
  needs you across the host), `smith notification`, `smith ssh-key`,
  `smith gpg-key` and `smith org list`.
- `smith alias` (`set --clobber` to replace one, `--shell` for `!`) and
  `smith config` (editor, browser, git protocol).
- `-q/--jq` and `-t/--template` on every command with `--json`.
- Release archives for Linux and macOS, x86_64 and aarch64, published on
  both forges when a version is tagged.

### Fixed

- Server text quoted in smith's own messages (titles, names) can no longer
  carry terminal escape sequences.

## [0.1.0] - 2026-09-29

### Added

- `smith auth login` signs you in without making a token by hand: in the
  browser, like `gh auth login`, or in the terminal with your username,
  password and two-factor code. It picks the browser when the instance offers
  it and one can be opened; `--web`, `--password` and `--with-token` choose
  explicitly. A browser login renews itself.
- Login looks at what the instance offers first: Forgejo or Gitea and which
  version, browser sign-in, its page size, and the SSH hostname it advertises,
  so SSH remotes map back to the right host.
- `smith auth status`, `switch`, `logout` and `token`. Logins are kept in
  `~/.config/smith/hosts.zon` with mode 0600, as many hosts as you like and
  several accounts per host: `auth switch` changes the default host or the
  active account.
- `SMITH_TOKEN` is used for the default host only, so it never reaches
  another instance; `SMITH_TOKEN_<HOST>` sets a token for one host, and
  `SMITH_HOST` picks the default.
- smith works out the host and repository from the clone's git remotes
  (`upstream` first, then `origin`), or from `-R [HOST/]OWNER/REPO`. A remote
  on a forge that is not Forgejo, such as a GitHub mirror, is skipped, and
  the error says which remotes were checked.
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
- Piped output follows gh's machine format: plain numbers, whole text,
  timestamps and a state column; exit code 4 when authentication failed.
- Built for servers you do not control: nothing a server sends can become a
  git option or a terminal escape sequence, environment tokens only go to
  exactly-named https hosts you configured, and `--web` only opens web
  addresses.
