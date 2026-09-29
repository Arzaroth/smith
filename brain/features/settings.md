# config, alias

Both live in `$SMITH_CONFIG_DIR/config.zon` (next to `hosts.zon`, nothing
secret in it), read at the start of every invocation.

**config** `get`, `set`, `unset`, `list` over three keys:
- `editor`: used after `SMITH_EDITOR` and before `VISUAL`/`EDITOR`.
- `browser`: used after `SMITH_BROWSER` and before `BROWSER`.
- `git_protocol`: `ssh` or `https`, given to hosts logged in to afterwards.

**alias** `set <name> <expansion>`, `list`, `delete`:
- Expanded in `app.dispatch` when the first word is not a smith command, so
  an alias can never shadow one (`set` refuses such names, and expansions
  whose first word is not a command unless they start with `!`).
- The expansion is split like a shell would (quotes, backslashes); `$1`…
  take the words after the alias, and words no placeholder took are
  appended: `bugs` for `issue list --label $1` makes `smith bugs ui -L 5`
  run `issue list --label ui -L 5`.
- `!` aliases run with `sh -c`, the arguments as `$1`…, and exit with the
  shell's status.
- Aliases do not expand inside aliases.

## Sources

- `src/settings.zig`
- `src/cmd/settings.zig`
- `src/app.zig` (`dispatch`, `shellAlias`)
- `src/tests/settings_test.zig`
