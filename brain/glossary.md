# Glossary

- **Host**: a Forgejo instance, named by the hostname its web UI and API
  answer on (`git.example.com`). Config and tokens are keyed by it.
- **SSH host**: the hostname git uses over SSH when it differs from the host
  (`box.example.com`). Remote URLs are mapped back to their host through it.
- **Repo reference**: `owner/repo`, optionally prefixed `host/`, as taken by
  `-R` and `repo clone`.
- **Run**: a Forgejo Actions workflow run. Its jobs carry the logs.
- **Checks**: the combined commit status of a commit, which any CI can post,
  Forgejo Actions included.
- **Gate**: `mise run check`; must be green before a merge or release.
