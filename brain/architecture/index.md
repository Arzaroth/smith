# Architecture

How the pieces fit, from the command line down to the wire.

| Doc | Covers |
|---|---|
| [cli.md](cli.md) | Command tree, flag parsing, dispatch, exit codes, the context |
| [config.md](config.md) | `hosts.zon`, tokens, SSH hosts, environment overrides |
| [api-client.md](api-client.md) | Requests, auth header and redirects, errors, pagination, decoding |
| [repo-resolution.md](repo-resolution.md) | `-R` and git remotes to host and `OWNER/REPO` |
| [output.md](output.md) | Tables, colour, stdout vs stderr, times, browser |
| [testing.md](testing.md) | Mock Forgejo, harness, fixtures |

## Sources

- `src/`
