# Stack

- **Language**: Zig 0.16.0, pinned in `.mise.toml`. The entry point takes
  `std.process.Init` (arena, `Io`, args) and writes through buffered
  `Io.File.Writer`s that must be flushed.
- **Dependencies**: the Zig standard library only. HTTP and TLS come from
  `std.http.Client`, JSON from `std.json`. Git work shells out to `git`.
- **Version**: `build.zig.zon` `.version`, passed to the binary as the
  `build_options.version` module by `build.zig`; `-Dversion=` overrides it
  (`install.sh --dev` builds `<version>-dev+<commit>`).
- **Tasks** (`mise run <task>`): `build`, `run`, `test` (`zig build test
  -Dtest-filter=<text>` for a subset), `fmt`, `check` (the
  gate: `zig fmt --check`, `shellcheck mise-tasks/*`,
  `mise-tasks/installer-check` (shellcheck of `install.sh`, its Zig
  version against `.mise.toml`'s, and an offline run of it),
  `mise-tasks/packaging-check` (shellcheck of the PKGBUILD templates, their
  Zig version and checksums against `.mise.toml` and `install.sh`), tests,
  ReleaseSafe build), `release <x.y.z>` (`mise-tasks/release`), `dist`
  (`mise-tasks/dist`: stripped ReleaseSafe archives for x86_64 and aarch64
  Linux (static musl) and macOS, `smith-cli_<version>_{amd64,arm64}.deb`
  built by nfpm from `packaging/nfpm.yaml` with completions, the source
  tarball `smith-<version>.tar.gz` (`git archive`), and `SHA256SUMS` over
  all of them), `aur <x.y.z>` (`mise-tasks/aur`: renders
  `packaging/arch/{smith-cli,smith-cli-bin}/PKGBUILD.in` and their
  `.SRCINFO` into `dist/aur` with the published release's checksums, or a
  local `SHA256SUMS` with `--sums`), `coverage` (`mise-tasks/coverage`:
  `zig build coverage` runs the tests under kcov, which must be installed,
  and it prints the files below 100% and the total; the HTML report lands in
  `zig-out/coverage`).
- **CI**: `.github/workflows/ci.yml` runs the gate on Forgejo Actions and,
  through the mirror, on GitHub Actions. A `v*` tag runs
  `.github/workflows/release.yml`: the gate, `mise run dist` (archives, debs and
  source tarball are all uploaded), then the release
  notes from `CHANGELOG.md`, published with `gh release create` on GitHub and
  with `smith release create` itself on Forgejo (the job token, or a
  `RELEASE_TOKEN` secret). The Forgejo runner reaches its server as
  `http://server:3000`, so that step writes smith a `hosts.zon` naming it
  with its scheme before `SMITH_TOKEN` can apply. `actions/checkout` is
  pinned to a commit that GitHub and Forgejo's action mirrors share.
- **Installer**: `install.sh` (POSIX sh, curl or wget, https only) installs
  the latest release, or `--version`, for the machine's OS and architecture
  from GitHub or `--from forgejo`, checked against the release's
  `SHA256SUMS` (corruption, not tampering: both come from the same place).
  It runs from `main` on its last line, so a cut download runs nothing, and
  stages the binary under a random name before renaming it into place.
  `--dev` builds master's tip from its source tarball (trusted to TLS) with
  Zig from `PATH`, mise, or a ziglang.org download checked against checksums
  pinned in the script. A Zig bump updates `zig_version` and those
  checksums (from ziglang.org's `download/index.json`); the gate catches a
  stale `zig_version`, not stale checksums. `mise-tasks/installer-check`
  runs the script offline against a `file://` fixture release
  (`SMITH_INSTALL_URL`): an install, the up-to-date path, a checksum
  mismatch, a missing release, no `HOME`, a truncated script.

## Sources

- `.mise.toml`
- `install.sh`, `mise-tasks/installer-check`
- `build.zig`, `build.zig.zon`
- `src/main.zig`
- `mise-tasks/release`
- `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- `mise-tasks/dist`
- `mise-tasks/coverage`
- `mise-tasks/aur`, `mise-tasks/packaging-check`, `packaging/`
