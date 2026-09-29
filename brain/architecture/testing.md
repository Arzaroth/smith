# Testing

`mise run test` (or `zig build test`, `-Dtest-filter=<text>` for a subset).

- **Unit tests** sit next to the code (parsers, time formatting, URL
  parsing, config merging).
- **Invocation tests** (`src/tests/*_test.zig`) run whole `smith ...` commands
  through `app.run` with a `Harness`:
  - `testing/Mock.zig` is a Forgejo stand-in on 127.0.0.1, served from an
    `io.concurrent` task: routes by method, exact path, optional query
    substring and a use count (`times`, for polling), with an optional
    `Location`. It records every request (target, body, authorization) for
    assertions; one request per connection.
  - `testing/Harness.zig` gives each test a temporary directory used as
    `HOME` and config dir, a `hosts.zon` pointing at the mock, a fixed "now"
    (2026-09-29T12:00:00Z), a git identity, `GIT_CONFIG_NOSYSTEM`, and
    `SMITH_BROWSER=true`. `clone()` makes a repo whose origin is the mock;
    output is captured in memory; `stdin_data` stands in for stdin.
  - `pr checkout` tests fetch for real from a local bare repository that the
    clone reaches through `url.<bare>.insteadOf` (hence remotes being matched
    on their configured URL too).
- `tests/fixtures.zig` holds the canned API objects.
- Nothing touches the network or the developer's config. Child processes must
  not write to the test binary's stdout, which is the build runner's protocol
  pipe; git's output goes to stderr for that reason as well.

## Sources

- `src/testing/Mock.zig`
- `src/testing/Harness.zig`
- `src/tests/`
- `build.zig`
