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
  needed) and refuses to overwrite without `--clobber`. Each asset streams
  to a temporary file renamed into place. An asset's name must be a plain
  file name (no `/`, `\`, `..` or leading `-`), since uploaders choose it.
  Asset URLs may point or redirect to another host (external assets, object
  storage); the token goes only to the API's own
  ([../architecture/api-client.md](../architecture/api-client.md)).
- `upload` and `create` stream each file from disk; `--clobber` opens the
  new file before deleting the old asset, so a typo loses nothing.
- Deleting asks first; without a terminal it needs `--yes`.

## Sources

- `src/cmd/release.zig`
- `src/api.zig` (`Client.uploadFile`, `Client.download`)
- `src/tests/release_test.zig`
