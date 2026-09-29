# api, browse, completion, help

**`api <endpoint>`**: an authenticated request, printed as received (JSON
pretty-printed on a terminal). The endpoint is relative to `/api/v1`
(`/api/v1/...` also accepted); `{owner}` and `{repo}` are filled from the
current repository. `-f key=value` adds string fields and `-F` typed ones
(`true`, `false`, `null`, integers, `@file`); fields make the method POST
unless `-X` says otherwise, and go in the query string for GET and DELETE.
`--input` sends a file as the body, `-H` adds headers, `--paginate` fetches
every page of a list into one array. `--jq` and `--template` apply to a 2xx JSON
answer, as on other commands, and are refused on anything else; like gh,
an error answer is printed as sent, unfiltered, with its status, and exits
1. The host is `--hostname`, else the current repository's, else the
default one.

**`browse [<number> | <path>[:<line>]]`**: opens the repository, an issue or
pull request (`/issues/<n>` redirects to a pull request), a file on the
default branch or `-b`, the settings (`-s`) or Actions (`-a`); `-n` prints
the URL instead.

**`completion <bash|zsh|fish>`**: generated from the command tree. bash
completes subcommands and the flags of the command typed so far; zsh loads
the bash script through `bashcompinit`; fish uses a helper that works out the
command path from the tokens typed.

**`help [<command>... | reference | skill | environment | exit-codes |
formatting]`**: `help pr checks` is `pr checks --help`; the last three
are gh's help topics, each a section of the reference. `help reference` writes the whole command tree as
Markdown (conventions, exit codes, environment, then every command with its
usage and flags), walked from `app.root` like completion, so it cannot fall
behind the code. `help skill` writes a `SKILL.md` that teaches a coding
agent to drive smith: the non-interactive flags, structured output, exit
codes, asking before `--yes`, and to read `help reference` rather than
guess from gh. Install it with
`smith help skill > ~/.claude/skills/smith/SKILL.md`.

## Sources

- `src/cmd/api.zig`
- `src/cmd/browse.zig`
- `src/cmd/completion.zig`
- `src/cmd/help.zig`
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
  "foo" not defined`). On a terminal the output keeps only colour
  sequences and OSC 8 links to http(s) URLs; any other control character,
  whether it came from the data or was built by the template (`printf
  "%c"`, byte `slice`), becomes `?`. As in gh, `color` always colours and
  `autocolor` only with colour on; `hyperlink` links only on a terminal and
  only to http(s) URLs, and `color` ignores a style it does not know.
  Left out: `define`/`template`/`block` (refused with a clear error),
  `html`, `js`, `urlquery`, `call` and gh's `regexMatch`.
