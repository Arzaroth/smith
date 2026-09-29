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
- Commands allocate from the invocation's arena (`ctx.alloc`) and free
  nothing individually; code outside it (the mock, pure helpers under test)
  owns its memory and uses `errdefer`.
- Zig analyses only what is referenced: a function nothing calls is never
  compiled, errors included. `main.zig`'s test block walks every module
  (`refAll`) so `zig build test` compiles all of it.
- Known std 0.16 traps, all worked around in `api.zig`: the HTTP client
  never sends `privileged_headers`, keeps the authorization header across a
  redirect to another host, asserts when a POST is sent without a body, and
  on releasing a request reads a DELETE's length-less 204 until the server
  hangs up.
  `refAllDeclsRecursive` is gone; `json.ObjectMap` is unmanaged (`.empty`,
  allocator per call). `EAGAIN` from `accept` is a debug panic, so end a
  blocking accept by shutting the socket from another task (`oauth.expire`).
- A child process's program is found through smith's own `PATH`, not the
  `environ_map` it is given: a test cannot shadow a real tool by putting a
  fake on the harness `PATH`. Point at the fake by absolute path instead
  (`SMITH_KEYRING`, `SMITH_BROWSER`).

## Tests

Tests never touch the network or the developer's real config: HTTP goes to a
mock server started inside the test, git runs in temporary repositories, and
`HOME` and the config directory point at a temporary directory
(`src/testing/Harness.zig`, see `brain/architecture/testing.md`).

- A new command gets invocation tests in `src/tests/`, registered in
  `main.zig`'s test block: the mock routes it calls, the request bodies it
  sends, and its output and exit code.
- Child processes must never write to the test binary's stdout: it is the
  build runner's protocol pipe, and a stray write hangs `zig build test`
  with no output. A silent hang means exactly that; bisect with
  `zig build test -Dtest-filter=<name>`.
- Every harness command runs git in the temporary directory, with
  `GIT_CEILING_DIRECTORIES` stopping git from climbing into the checkout
  the tests run from; never set `ctx.cwd` to null in a test.
- The harness sets `SMITH_KEYRING=none`; a test must never reach the
  developer's keyring, browser, editor or config.

## Conventions

- `CHANGELOG.md` `[Unreleased]` gets an entry with every user-facing change.
- Before finishing: `mise run fmt`, then `mise run check` (the gate).
- Releases go through `mise run release <x.y.z>` (the `release` skill).
- Commits use the global git identity with no `Co-Authored-By` or session
  trailers.
