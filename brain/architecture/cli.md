# Command line

The command tree is data: every command is a `cli.Command` (name, summary,
usage, flags, subcommands, `run` function, argument bounds). `app.root` holds
the tree; `smith completion` and `--help` are generated from it, so a new flag
exists everywhere once it is declared.

- **Parsing** (`cli.parse`): long flags (`--state closed`, `--state=closed`),
  short flags with attached or separate values (`-L5`, `-L 5`), clustered
  booleans (`-dl bug`), booleans with `=true` or `=false` as gh takes them
  (`--enable-wiki=false` is `--disable-wiki`), repeatable flags whose values are also split on commas
  (`Args.all`), negative numbers kept as positionals, `--` passthrough for
  commands that declare `passthrough` (`repo clone ... -- --depth 1`).
  `-h` is help unless the command declares its own `-h` (`config --host`);
  `--help` always is.
- **Dispatch** (`app.run`): walks the leading words down the tree
  (`cli.resolve`), prints help for a group, rejects unknown subcommands, then
  parses and calls `run`. A command returns its exit code. A command with
  `pages` set (lists, views, `pr diff`) starts the pager first, and
  `app.run` stops it after flushing.
- **Exit codes**: 0 ok, 1 failure or usage error, 4 authentication failed
  (a 401, `error.AuthRequired`), 8 checks still pending
  (`pr checks`, `run view --exit-status`), following gh.
- **Errors**: `Ctx.fail` prints the message and returns `error.Reported`,
  which `app.run` maps to exit 1. Anything else unexpected prints
  `smith: <error name>`.
- **Context** (`Ctx`): arena allocator for the whole invocation, `Io`,
  environment map, buffered stdout/stderr writers, TTY facts, fixed "now",
  the shared HTTP client, an optional git working directory and stdin
  override. Every child process gets `ctx.env`.

## Sources

- `src/cli.zig`
- `src/app.zig`
- `src/Ctx.zig`
- `src/main.zig`
