# release

| Command | Endpoints |
|---|---|
| `release list` | `GET /repos/{o}/{r}/releases` |
| `release view [<tag>]` | `GET .../releases/tags/{tag}`, or `.../releases/latest` |
| `release create <tag> [<files>...]` | `POST .../releases`, then one upload per file |
| `release edit <tag>` | `PATCH .../releases/{id}` |
| `release upload <tag> <files>...` | `POST .../releases/{id}/assets?name=` (multipart `attachment`); `--clobber` deletes the old asset first |
| `release download [<tag>]` | each asset's `browser_download_url` |
| `release delete <tag>` | `DELETE .../releases/{id}`, and `DELETE .../tags/{tag}` with `--cleanup-tag` |
| `release delete-asset <tag> <name>` | `DELETE .../releases/{id}/assets/{asset}` |

- `list` marks the newest release that is neither a draft nor a
  pre-release as Latest.
- `create` checks every file is readable before creating anything; the title
  defaults to the tag; notes come from `--notes` or `--notes-file` (`-` for
  stdin).
- `edit` uses paired flags instead of gh's `--draft=false`: `--draft` /
  `--publish`, `--prerelease` / `--latest`.
- `download` takes `-p` globs (`*`, `?`), writes into `-D` (created if
  needed) and refuses to overwrite without `--clobber`. Asset URLs may
  redirect to object storage on another host; the client follows without the
  token ([../architecture/api-client.md](../architecture/api-client.md)).
- Deleting asks first; without a terminal it needs `--yes`.

## Sources

- `src/cmd/release.zig`
- `src/api.zig` (`Client.upload`)
- `src/tests/release_test.zig`
