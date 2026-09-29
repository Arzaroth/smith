# Stack

- **Language**: Zig 0.16.0, pinned in `.mise.toml`. The entry point takes
  `std.process.Init` (arena, `Io`, args) and writes through buffered
  `Io.File.Writer`s that must be flushed.
- **Dependencies**: the Zig standard library only. HTTP and TLS come from
  `std.http.Client`, JSON from `std.json`. Git work shells out to `git`.
- **Version**: `build.zig.zon` `.version`, passed to the binary as the
  `build_options.version` module by `build.zig`.
- **Tasks** (`mise run <task>`): `build`, `run`, `test` (`zig build test
  -Dtest-filter=<text>` for a subset), `fmt`, `check` (the
  gate: `zig fmt --check`, `shellcheck mise-tasks/*`, tests, ReleaseSafe
  build), `release <x.y.z>` (`mise-tasks/release`).
- **CI**: `.github/workflows/ci.yml` runs the gate on Forgejo Actions and,
  through the mirror, on GitHub Actions.

## Sources

- `.mise.toml`
- `build.zig`, `build.zig.zon`
- `src/main.zig`
- `mise-tasks/release`
- `.github/workflows/ci.yml`
