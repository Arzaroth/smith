# Repository resolution

Which host and `OWNER/REPO` a command acts on (`repo.resolve`):

1. `-R [HOST/]OWNER/REPO`, `-R HOST:OWNER/REPO` or a clone URL (`repo.parseSpec`;
   `HOST:PORT/OWNER/REPO` keeps the port). Without a host, the default host.
2. Otherwise the git remotes of the current clone, `upstream` first, then
   `origin`, then the rest. The first remote whose host is configured (by
   `name` or `ssh_host`) wins. An https remote on an unknown host is the
   fallback, so public instances work without logging in; an unknown SSH host
   is not, since its web hostname cannot be guessed.

Each remote is read twice (`git.remotes`): the URL git fetches from (after
`insteadOf`) and the URL as configured, and either may identify the forge.
`git.parseRemoteUrl` understands scp-style (`git@host:o/r.git`), `ssh://`
with a port, and `http(s)://` with credentials or a path prefix.

`repo.remoteFor` finds the remote pointing at a given repository, which `pr
checkout` fetches from.

## Sources

- `src/repo.zig`
- `src/git.zig`
