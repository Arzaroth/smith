# config, alias

Both live in `$SMITH_CONFIG_DIR/config.zon` (next to `hosts.zon`, nothing
secret in it), read at the start of every invocation. A file that does
not parse is reported and ignored there, so it never blocks the commands
that repair it; `config` and `alias`, which rewrite it, refuse to until it
is fixed or deleted.

**config** `get`, `set`, `unset`, `list` over three keys (`get` prints an
empty line for an unset key, and `git_protocol` shows its default, `ssh`):
- `editor`: used after `SMITH_EDITOR` and before `VISUAL`/`EDITOR`.
- `browser`: used after `SMITH_BROWSER` and before `BROWSER`.
- `git_protocol`: `ssh` or `https`, given to hosts logged in to afterwards.

**alias** `set <name> <expansion>`, `list`, `delete`:
- `set` refuses to replace an alias without `--clobber`, and `--shell` (`-s`)
  is the same as a leading `!`, as in gh. An empty expansion or an
  unterminated quote is refused.
- Expanded in `app.dispatch` when the first word is not a smith command, so
  an alias can never shadow one (`set` refuses such names, and expansions
  whose first word is not a command unless they start with `!`).
- The expansion is split like a shell would (quotes, backslashes); `$1`…
  take the words after the alias, and words no placeholder took are
  appended: `bugs` for `issue list --label $1` makes `smith bugs ui -L 5`
  run `issue list --label ui -L 5`. A placeholder with no argument is an
  error (`not enough arguments for alias`), as in gh.
- `!` aliases run with `sh -c`, the arguments as `$1`…, and exit with the
  shell's status.
- Aliases do not expand inside aliases.

## Sources

- `src/settings.zig`
- `src/cmd/settings.zig`
- `src/app.zig` (`dispatch`, `shellAlias`)
- `src/tests/settings_test.zig`
