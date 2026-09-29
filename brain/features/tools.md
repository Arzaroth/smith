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
- `src/template.zig`, `src/template/`
- `src/tests/tools_test.zig`

## --jq and --template

Every command with `--json` also takes `-q/--jq` and `-t/--template`
(`cli.implicitFlags`), and either implies `--json`. `api.printJson` applies
them:

- `--jq EXPR` pipes the JSON through the system `jq -r EXPR` (strings come
  out raw, like gh). smith does not embed jq; without it installed, the error
  says so and points at `--template`. `SMITH_JQ` names another jq program.
  When jq fails, its own message is smith's error.
- `--template` renders Go's text/template as gh users know it
  (`src/template.zig`, whose top comment is the full list; lexer, parser,
  evaluator and functions in `src/template/`): pipelines with `|`,
  parentheses, variables (`$`, `:=`, `=`, `range $i, $v :=`), `if` /
  `with` / `range` with `else if` chains, `break`, `continue`, comments,
  `{{-`/`-}}` trimming across blocks; Go's functions (`printf`, `eq`,
  `and`, `index`, `slice`...) and gh's (`tablerow`/`tablerender`,
  `truncate`, `color`/`autocolor`, `hyperlink`, `timefmt`, `timeago`,
  `pluck`, `join`, `contains`). A missing field renders as nothing.
  Syntax errors, argument counts included, are found before anything
  prints, and every error names its position (`template: 1:14: function
  "foo" not defined`). On a terminal only the strings from the JSON are
  cleaned of control characters, so the template's own colours and links
  survive; colour follows smith's colour setting, links need a terminal.
  Left out: `define`/`template`/`block` (refused with a clear error),
  `html`, `js`, `urlquery`, `call` and gh's `regexMatch`.
