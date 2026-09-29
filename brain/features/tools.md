# api, browse, completion

**`api <endpoint>`**: an authenticated request, printed as received (JSON
pretty-printed on a terminal). The endpoint is relative to `/api/v1`
(`/api/v1/...` also accepted); `{owner}` and `{repo}` are filled from the
current repository. `-f key=value` adds string fields and `-F` typed ones
(`true`, `false`, `null`, integers, `@file`); fields make the method POST
unless `-X` says otherwise, and go in the query string for GET and DELETE.
`--input` sends a file as the body, `-H` adds headers, `--paginate` fetches
every page of a list into one array. A non-2xx status prints the body and
exits 1. The host is `--hostname`, else the current repository's, else the
default one.

**`browse [<number> | <path>[:<line>]]`**: opens the repository, an issue or
pull request (`/issues/<n>` redirects to a pull request), a file on the
default branch or `-b`, the settings (`-s`) or Actions (`-a`); `-n` prints
the URL instead.

**`completion <bash|zsh|fish>`**: generated from the command tree. bash
completes subcommands and the flags of the command typed so far; zsh loads
the bash script through `bashcompinit`; fish uses a helper that works out the
command path from the tokens typed.

## Sources

- `src/cmd/api.zig`
- `src/cmd/browse.zig`
- `src/cmd/completion.zig`
- `src/tests/tools_test.zig`
