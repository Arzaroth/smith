# label, milestone

**label** (`/repos/{o}/{r}/labels`): `list`, `create <name>` (`-c rrggbb`,
with or without `#`; a random colour otherwise; `-d`, `--exclusive` for a
scoped label), `edit <name>` (`-n` renames), `delete <name>`, and `clone
<source-repo>`, which creates the source's labels missing here and, with
`--force`, overwrites those that exist. Labels are found by name,
case-insensitively.

**milestone** (`/repos/{o}/{r}/milestones`): `list` (`-s open|closed|all`,
with progress as closed/total), `view`, `create <title>` (`--due
YYYY-MM-DD`, stored as the end of that day in UTC, `-d`), `edit`, `close`,
`reopen`, `delete`. A milestone is named by title or id: Forgejo's
`/milestones/{id}` accepts either.

`issue list`, `issue create`, `issue edit` and `pr create` take
`-m/--milestone`, resolved to an id through the same endpoint before
anything is written.

## Sources

- `src/cmd/label.zig`
- `src/cmd/milestone.zig`
- `src/cmd/common.zig` (`milestoneId`)
- `src/tests/planning_test.zig`
