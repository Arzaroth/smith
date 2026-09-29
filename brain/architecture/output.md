# Output

- **TTY or not**: tables are space-aligned with colour on a terminal and
  tab-separated without colour otherwise, like gh, so piped output stays easy
  to cut. `NO_COLOR` turns colour off, `CLICOLOR_FORCE` on, `TERM=dumb` off.
- **Piped lists are for scripts**: plain numbers (`12`, not `#12`), the
  full text, timestamps as the API sent them, and a state column that a
  terminal shows as colour instead (`Cell.pipe`). `pr checks` prints only
  its rows.
- **Server text is cleaned**: control characters in anything the server
  sent (titles, bodies, labels, log lines, diffs on a terminal) become `?`
  (`term.clean`), so an escape sequence cannot write to the clipboard or
  forge a line; table cells also lose tabs and newlines. `--json`, `api` and
  piped `pr diff` stay byte-exact. On a terminal, `--template` and
  `--jq` output is cleaned the same way, and stderr goes through
  `term.Scrubber`, so the names and titles quoted in smith's own messages
  are covered too.
- **stdout vs stderr**: stdout carries what a command produces (tables,
  bodies, URLs, JSON); confirmations (`✓ Merged ...`), warnings and git's own
  output go to stderr.
- **Times**: RFC 3339 timestamps render as "about 3 hours ago"; run durations
  as "1m 5s", and as nothing when the run never started (Forgejo reports
  its zero time, `1970-01-01T01:00:00+01:00`, as the start).
- **Watching**: `pr checks --watch` and `run watch` redraw the screen on a
  terminal and append snapshots otherwise; each poll allocates from its own
  arena, freed before the next.
- **Pager**: lists, views and `pr diff` on a terminal write through
  `SMITH_PAGER`, then `config set pager`, then `PAGER` (`cat` means none),
  run with `sh -c` and `LESS=FRX`, `LV=-c` unless set, as gh does. Watch
  modes and prompts never page.
- **Browser**: `--web` runs `$SMITH_BROWSER`, `$BROWSER`, else `xdg-open`
  (`open` on macOS), detached so that a browser started directly does not
  hold smith, and only for http(s) URLs, since some come from the server.

## Sources

- `src/term.zig`
- `src/Ctx.zig`
- **--jq / --template**: applied by `api.printJson` to anything a command
  would print as JSON; see [../features/tools.md](../features/tools.md#--jq-and---template).
- **Confirmation**: destructive commands ask on a terminal (`Ctx.confirm`)
  and need `--yes` without one; `repo delete` wants the full name typed.
