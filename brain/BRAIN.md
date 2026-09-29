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
| What does "host" mean vs "ssh host"? | [glossary.md](glossary.md) |

## Feature catalog

| Group | Commands | Doc |
|---|---|---|
| auth | login, status, logout, token | [features/auth.md](features/auth.md) |
| repo | clone, view, list | [features/repo.md](features/repo.md) |
| issue | list, view, create, close, reopen, comment, edit | [features/issue.md](features/issue.md) |
| pr | list, view, diff, create, checkout, merge, close, reopen, comment, ready, edit, checks | [features/pr.md](features/pr.md) |
| run | list, view, watch, cancel | [features/run.md](features/run.md) |
| api, browse, completion | | [features/tools.md](features/tools.md) |
