---
name: release
description: Cut a smith release, the whole shebang - docs sweep (CHANGELOG, README, ROADMAP ticks, brain), then mise run release (version bump in build.zig.zon, gate, commit, annotated tag, push). Use when the user says "cut a release", "release", or "the whole release shebang".
---

# Release shebang

Everything between "the code is done" and "the tag is pushed". The heavy lifting
lives in `mise run release <x.y.z>`; the value of this skill is the docs sweep
before it.

## 1. Pre-flight

- Working tree clean, on `master`, up to date with origin.
- Find the previous version: `git describe --tags --abbrev=0` (tags are `vX.Y.Z`;
  the first release has none, diff against the root commit).
- Pick the next semver. While smith is 0.x: minor for new commands or flags,
  patch for fix-only.

## 2. Docs sweep (review everything against `git diff v<last>..HEAD`)

- **CHANGELOG.md `[Unreleased]`** must cover every user-visible change since the
  last tag (entries are added per-commit during development, so this is usually
  a completeness check against `git log v<last>..HEAD --oneline`). Keep a
  Changelog categories: Added / Changed / Fixed / Removed / Security.
- **README.md**: the usage examples and status line - update if the release adds
  commands, flags, config keys or environment variables.
- **ROADMAP.md**: tick the items this release ships (`- [x]`), keeping their
  decision notes.
- **brain/**: every shipped command group has its `brain/features/*.md` and a row
  in `brain/features/index.md` and the `BRAIN.md` catalog (the **brain** skill).
- Commit the docs sweep as `[master] docs(release): ...` (the release task
  requires a clean tree).

## 3. Cut it

```bash
mise run release <x.y.z> --dry-run   # preview the changelog section
mise run release <x.y.z>             # the real thing
```

The task: refuses off `master` or on a dirty tree, moves `[Unreleased]` into a
dated `## [x.y.z]` section, bumps `.version` in `build.zig.zon`, runs the gate
(`mise run check`) and checks `smith --version` reports the new version, commits
`[master] chore(release): x.y.z`, creates annotated tag `vx.y.z`, and pushes with
`--follow-tags`.

If the task dies mid-gate it leaves the CHANGELOG/build.zig.zon bump
uncommitted: `git checkout -- CHANGELOG.md build.zig.zon`, fix the cause, re-run.

## 4. Verify

- `git tag -l 'v*' | tail -1` and `grep '\.version' build.zig.zon` agree.
- `zig-out/bin/smith --version` prints the new version.
- The tag starts `.github/workflows/release.yml` on GitHub (releases are
  GitHub's alone; Forgejo's copy skips itself): `gh run watch -R
  Arzaroth/smith`. It builds and tests on every platform, signs, installs the
  packages, then publishes a draft and makes it latest once every file is up.
- Check the release carries the archives (Linux, macOS, Windows zips), the
  `.deb`, `.rpm`, `.msi` and Arch packages with their `.sig`s, the PKGBUILD
  and source tarballs, `SHA256SUMS`, `SHA256SUMS.asc` and
  `smith-release-key.asc`: `gh release view vX.Y.Z -R Arzaroth/smith`.
- If signing fails, check the `SMITH_GPG_KEY` and `SMITH_GPG_PASSPHRASE`
  secrets against `~/.config/smith/release-signing.*`.
