# Output

- **TTY or not**: tables are space-aligned with colour on a terminal and
  tab-separated without colour otherwise, like gh, so piped output stays easy
  to cut. `NO_COLOR` turns colour off, `CLICOLOR_FORCE` on, `TERM=dumb` off.
- **stdout vs stderr**: stdout carries what a command produces (tables,
  bodies, URLs, JSON); confirmations (`✓ Merged ...`), warnings and git's own
  output go to stderr.
- **Times**: RFC 3339 timestamps render as "about 3 hours ago"; run durations
  as "1m 5s", and as nothing when the run never started (Forgejo reports
  its zero time, `1970-01-01T01:00:00+01:00`, as the start).
- **Watching**: `pr checks --watch` and `run watch` redraw the screen on a
  terminal and append snapshots otherwise.
- **Browser**: `--web` runs `$SMITH_BROWSER`, `$BROWSER`, else `xdg-open`
  (`open` on macOS).

## Sources

- `src/term.zig`
- `src/Ctx.zig`
