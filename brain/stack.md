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
  build), `release <x.y.z>` (`mise-tasks/release`), `dist` (`mise-tasks/dist`:
  stripped ReleaseSafe archives for x86_64 and aarch64 Linux (static musl)
  and macOS, with `SHA256SUMS`).
- **CI**: `.github/workflows/ci.yml` runs the gate on Forgejo Actions and,
  through the mirror, on GitHub Actions. A `v*` tag runs
  `.github/workflows/release.yml`: the gate, `mise run dist`, then the release
  notes from `CHANGELOG.md`, published with `gh release create` on GitHub and
  with `smith release create` itself on Forgejo (the job token, or a
  `RELEASE_TOKEN` secret). The Forgejo runner reaches its server as
  `http://server:3000`, so that step writes smith a `hosts.zon` naming it
  with its scheme before `SMITH_TOKEN` can apply. `actions/checkout` is
  pinned to a commit that GitHub and Forgejo's action mirrors share.

## Sources

- `.mise.toml`
- `build.zig`, `build.zig.zon`
- `src/main.zig`
- `mise-tasks/release`
- `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- `mise-tasks/dist`
