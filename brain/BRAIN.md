# The brain

How smith works, written so it can be understood without reading the source.
Start here, drill through the two indexes, land on a leaf doc. The code is the
source of truth: when a doc disagrees with it, fix the doc.

| Topic | Where |
|---|---|
| Stack, toolchain, tasks | [stack.md](stack.md) |
| How the pieces fit | [architecture/index.md](architecture/index.md) |
| What each command does | [features/index.md](features/index.md) |
| Why it is shaped this way | [decisions.md](decisions.md) |
| Vocabulary | [glossary.md](glossary.md) |

## Find by question

| Question | Doc |
|---|---|
| How do I build, test or release? | [stack.md](stack.md) |
| Why Zig? Why no dependencies? | [decisions.md](decisions.md) |
| Where is the token stored, what overrides it? | [architecture/config.md](architecture/config.md) |
| How does smith know which repository I mean? | [architecture/repo-resolution.md](architecture/repo-resolution.md) |
| Why doesn't smith let std follow redirects? | [architecture/api-client.md](architecture/api-client.md) |
| How do I test a command without a server? | [architecture/testing.md](architecture/testing.md) |
| How does `pr checkout` handle forks? | [features/pr.md](features/pr.md) |
| Keyring or file: where does the token live? | [architecture/config.md](architecture/config.md) |
| How is a release built and published? | [stack.md](stack.md) |
| How do aliases expand? | [features/settings.md](features/settings.md) |
| How do `--jq` and `--template` work? | [features/tools.md](features/tools.md) |
| What does "host" mean vs "ssh host"? | [glossary.md](glossary.md) |

## Feature catalog

| Group | Commands | Doc |
|---|---|---|
| auth | login, status, switch, logout, token | [features/auth.md](features/auth.md) |
| repo | clone, view, list, create, fork, edit, sync, archive, unarchive, delete, set-default | [features/repo.md](features/repo.md) |
| issue | list, view, create, close, reopen, comment, edit | [features/issue.md](features/issue.md) |
| pr | list, view, diff, create, checkout, merge, close, reopen, comment, ready, edit, review, update, status, checks | [features/pr.md](features/pr.md) |
| run | list, view, watch, cancel, download | [features/run.md](features/run.md) |
| workflow, secret, variable | list, run; list, set, delete; list, get, set, delete | [features/actions-settings.md](features/actions-settings.md) |
| release | list, view, create, edit, upload, download, delete, delete-asset | [features/release.md](features/release.md) |
| label, milestone | list, create, edit, delete, clone; list, view, create, edit, close, reopen, delete | [features/planning.md](features/planning.md) |
| search, status, notification, ssh-key, gpg-key, org | | [features/account.md](features/account.md) |
| config, alias | get, set, unset, list; set, list, delete | [features/settings.md](features/settings.md) |
| api, browse, completion | --jq and --template | [features/tools.md](features/tools.md) |
