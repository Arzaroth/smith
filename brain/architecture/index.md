# Architecture

How the pieces fit. Only the entry point exists so far.

| Doc | Covers |
|---|---|
| (none yet) | `src/main.zig` parses `--help`/`--version`; see [../stack.md](../stack.md) |

Planned layers, in the order ROADMAP P0 builds them: argument parsing, host
config, HTTP client, repo resolution from git remotes, output formatting,
test harness. Each gets a doc here when it lands.
