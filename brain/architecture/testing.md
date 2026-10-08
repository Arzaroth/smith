# Testing

`mise run test` (or `zig build test`, `-Dtest-filter=<text>` for a subset).
`mise run coverage` measures line coverage of `src/` (tests excluded) with
kcov. Its test binary is built with LLVM: kcov cannot map the self-hosted
backend's debug info to the sources.

- **Unit tests** sit next to the code (parsers, time formatting, URL
  parsing, config merging).
- **Invocation tests** (`src/tests/*_test.zig`) run whole `smith ...` commands
  through `app.run` with a `Harness`:
  - `testing/Mock.zig` is a Forgejo stand-in on 127.0.0.1, served from an
    `io.concurrent` task that gives each connection a task of its own:
    routes by method, exact path, optional query substring and a use count
    (`times`, for polling), with an optional `Location`. It records every
    request (target, body, headers) for assertions. A route answers and
    closes the connection, or with `keep_alive` keeps it for the next
    request, answering a 204 the way Forgejo (Go) does, without a length;
    a kept connection left idle for `Mock.idle_seconds` is cut, which a
    test notices from the time taken. A route with `raw` sends those bytes
    verbatim as the whole response and closes, for answers std's server
    would not write (a corrupt compressed body, a broken chunk).
  - `testing/Harness.zig` gives each test a temporary directory used as the
    git working directory (with `GIT_CEILING_DIRECTORIES` so git never climbs
    into the checkout the tests run from), `TMPDIR`,
    `HOME` and config dir; an empty stdin; `SMITH_EDITOR=true`; a
    `hosts.zon` pointing at the mock, a fixed "now"
    (2026-09-29T12:00:00Z), a git identity, `GIT_CONFIG_NOSYSTEM`, and
    `SMITH_BROWSER=true`. `clone()` makes a repo whose origin is the mock;
    output is captured in memory; `stdin_data` stands in for stdin.
  - `pr checkout` tests fetch for real from a local bare repository that the
    clone reaches through `url.<bare>.insteadOf` (hence remotes being matched
    on their configured URL too).
- `tests/fixtures.zig` holds the canned API objects.
- The harness sets `SMITH_KEYRING=none`, so no test reaches the developer's
  keyring. Keyring tests point `SMITH_KEYRING` at a fake secret-tool script
  written into the temporary directory: a child's program is looked up in
  the test binary's own `PATH`, not in the environment handed to it, so a
  fake placed on the harness `PATH` would lose to the real one.
- A second `Mock` can be started in a test for two-host scenarios
  (environment token scoping, off-host redirects, remote probing).
- `run download` gets a real zip built by the test (one stored entry and its
  CRC), since no zip writer is assumed on the machine.
- Browser logins are driven end to end by a `curl` "browser" script
  (skipped when curl is missing). `--jq` tests point `SMITH_JQ` at a
  stand-in script, so they run whether or not jq is installed. The pager
  test does the same with `SMITH_PAGER`, a command writing to a file,
  never to stdout.
- Nothing touches the network or the developer's config. Child processes must
  not write to the test binary's stdout, which is the build runner's protocol
  pipe; git's output goes to stderr for that reason as well.

## Sources

- `src/testing/Mock.zig`
- `src/testing/Harness.zig`
- `src/tests/`
- `build.zig`
