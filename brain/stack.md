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
  `mise-tasks/packaging-check` (shellcheck of the PKGBUILD templates,
  `smith-cli`'s `zig` bounds against the minor version `.mise.toml` pins,
  and a package changelog entry for every release in `CHANGELOG.md`),
  tests,
  ReleaseSafe build), `release <x.y.z>` (`mise-tasks/release`), `dist`
  (`mise-tasks/dist`: stripped ReleaseSafe archives for x86_64 and aarch64
  Linux (static musl, PIE) and macOS, `smith-cli_<version>_{amd64,arm64}.deb`
  and `smith-cli-<version>-1.{x86_64,aarch64}.rpm` built by nfpm from
  `packaging/nfpm.yaml` with completions, the man page (`smith help man`)
  and a changelog made from `CHANGELOG.md` by `packaging/changelog.awk`, the source
  tarball `smith-<version>.tar.gz` (`git archive` of HEAD, without what
  `.gitattributes` marks `export-ignore`), and `SHA256SUMS` over
  all of them; the archives carry `smith.1` and `completions/`; given
  targets it builds only theirs, and the source tarball with `--source`),
  `arch` (`mise-tasks/arch`, on Arch as a regular user after `dist`:
  `smith-cli-bin` for x86_64 and aarch64 from the musl archives, `smith-cli`
  from the source tarball when the system's Zig is the pinned minor, and
  `smith-<version>-pkgbuild.tar.gz` with both rendered PKGBUILDs),
  `aur <x.y.z>` (`mise-tasks/aur`: renders
  `packaging/arch/{smith-cli,smith-cli-bin}/PKGBUILD.in` and their
  `.SRCINFO` into `dist/aur` with the published release's checksums, or a
  local `SHA256SUMS` with `--sums`), `coverage` (`mise-tasks/coverage`:
  `zig build coverage` runs the tests under kcov, which must be installed,
  and it prints the files below 100% and the total; the HTML report lands in
  `zig-out/coverage`).
- **CI**: `.github/workflows/ci.yml` runs the gate on Forgejo Actions and,
  through the mirror, on GitHub Actions, where it also runs the tests on
  arm64 Linux, Apple silicon and Intel macOS. `.github/workflows/release.yml`
  runs on GitHub only ([decision](decisions.md#one-release-build-on-github-for-both-forges-2026-10-16)),
  for a `v*` tag, `workflow_dispatch` with a tag, or, without publishing, a
  branch push touching the packaging:
  - **build**, one runner per target: the gate on x86_64 Linux, the tests
    elsewhere, `mise run dist <target>` (x86_64 Linux adds the source
    tarball), and the binary's `--version` against `build.zig.zon` (and the
    tag, when publishing).
  - **arch**, in an `archlinux` container: `mise run arch` on the Linux
    archives, keeping `smith-cli-bin` and the PKGBUILD tarball.
  - **checksums**: with the `SMITH_GPG_KEY` and `SMITH_GPG_PASSPHRASE`
    secrets and `packaging/smith.asc` committed, `rpmsign` signs the rpms,
    the Arch packages get detached `.sig`s and the public key goes along as
    `smith-release-key.asc`; then `SHA256SUMS` over everything and
    `SHA256SUMS.asc`. Without the key the files stay unsigned, which a
    release refuses once `packaging/smith.asc` is committed. Ubuntu's rpm
    wants `/usr/bin/gpg2`, so `__gpg` points at `gpg`. The key's own home,
    as for wyrmyon, is the maintainer's `~/.config/smith`: a `gnupg/`
    keyring and `release-signing.{fingerprint,passphrase,public.asc,
    secret.asc,revoke.asc}`, the last to publish if the key ever leaks.
  - **verify-linux** (x86_64, arm64) and **verify-macos** (both): the
    signatures (`gpg --verify`, `rpm -K` on Fedora, `pacman-key --verify`),
    the `.deb` on Debian 12, the `.rpm` on Fedora (`rpm -V`), the Arch
    package (`pacman -Qkk`), and `install.sh` against the files as a
    `file://` release.
  - **release**: notes from `CHANGELOG.md`; a GitHub draft with every file,
    then published as latest; then the same on Forgejo with `smith release
    create --draft` and `release edit --publish --latest`, using the
    release's own x86_64 binary and the `FORGEJO_RELEASE_TOKEN` secret, which
    is checked before anything is published.
  `actions/checkout` is pinned to a commit that GitHub and Forgejo's action
  mirrors share.
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
- `mise-tasks/aur`, `mise-tasks/arch`, `mise-tasks/packaging-check`, `packaging/`
