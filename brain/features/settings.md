# config, alias

Both live in `$SMITH_CONFIG_DIR/config.zon` (next to `hosts.zon`, nothing
secret in it), read at the start of every invocation. A file that does
not parse is reported and ignored there, so it never blocks the commands
that repair it; `config` and `alias`, which rewrite it, refuse to until it
is fixed or deleted.

**config** `get`, `set`, `unset`, `list` over five keys (`get` and `list`
show the default of an unset key):
- `git_protocol`: `ssh` (default) or `https`, given to hosts logged in to
  afterwards. With `-h HOST` (`--host`), `get`, `set` and `list` read or
  change a logged-in host's own protocol in `hosts.zon` instead, the one
  key that exists per host. A command that declares its own `-h` keeps
  help on `--help` only, as gh's `config` does.
- `editor`: used after `SMITH_EDITOR` and before `VISUAL`/`EDITOR`.
- `browser`: used after `SMITH_BROWSER` and before `BROWSER`.
- `pager`: used after `SMITH_PAGER` and before `PAGER`; see
  [../architecture/output.md](../architecture/output.md).
- `prompt`: `enabled` (default) or `disabled`. Disabled, or with
  `SMITH_PROMPT_DISABLED` set, a terminal behaves like a script: no
  prompts, no editor, `--yes` needed for deletions, `--title` and `--body`
  needed for creation (`Ctx.interactive`).

**alias** `set <name> <expansion>`, `list`, `delete [<name> | --all]`,
`import [<file> | -]`:
- `set <name> -` reads the expansion from standard input.
- `import` reads gh's alias file, a YAML map of `name: expansion` lines
  (plain, single- or double-quoted values, `#` comments), checks every entry
  as `set` would before writing any, and needs `--clobber` to replace
  existing ones. Nested YAML is refused.- `set` refuses to replace an alias without `--clobber`, and `--shell` (`-s`)
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
