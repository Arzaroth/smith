# smith

A Forgejo CLI with `gh`'s command surface, in Zig. Start with
`brain/BRAIN.md` to find how anything works; the plan is `ROADMAP.md`,
deferred chores are `TODO.md`.

## The brain

`brain/` is the committed knowledge base: stack, architecture, features,
decisions, glossary. Navigate it through `brain/BRAIN.md` and the two
`index.md` files rather than grepping the tree; the `brain` skill has the
full routine.

- Keep it true to the code. A change that makes a brain doc wrong fixes that
  doc in the same branch.
- The code wins: if the brain disagrees with reality, correct the brain.

## Zig 0.16

The standard library changes between Zig releases and most examples online
target older ones (`std.io`, `GeneralPurposeAllocator`, the old `main`).
Before using a std API, read it in the pinned toolchain's source
(`mise exec -- zig env` prints `std_dir`) rather than writing it from memory.

- `main` takes `std.process.Init`; I/O goes through `init.io` and buffered
  `Io.File.Writer`s, which must be flushed.
- Tests use `std.testing.allocator`, which fails a test on a leak; every
  allocation has an owner and an `errdefer` on the failure path.

## Tests

Tests never touch the network or the developer's real config: HTTP goes to a
mock server started inside the test, git runs in temporary repositories, and
`HOME`/`XDG_CONFIG_HOME` point at a temporary directory.

## Conventions

- `CHANGELOG.md` `[Unreleased]` gets an entry with every user-facing change.
- Before finishing: `mise run fmt`, then `mise run check` (the gate).
- Releases go through `mise run release <x.y.z>` (the `release` skill).
- Commits use the global git identity with no `Co-Authored-By` or session
  trailers.
