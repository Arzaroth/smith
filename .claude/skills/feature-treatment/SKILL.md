---
name: feature-treatment
description: Ship a finished smith feature branch the full way - rebase onto master, run a max-effort multi-agent code review, fix everything confirmed, update the brain/ knowledge base, pass the gate, merge, and cut a release. Use when the user says "feature treatment", "treat this branch", "review and merge this feature", or names a worktree/branch to ship.
---

# Feature treatment

The pipeline a finished feature branch goes through before it lands: **rebase ->
max review -> fix -> update brain -> gate -> merge -> release -> clean up**. The
point is that nothing merges without an adversarial review and a green gate.

The branch to treat comes from the argument (a branch or worktree name). If none
given, find it: `wt list` - the feature branch is the non-`master` one, its
worktree under `~/repos/smith.worktrees/<branch>`. Confirm which one if
ambiguous.

## 1. Rebase onto master

```bash
cd ~/repos/smith.worktrees/<branch>
git rebase master
```
Resolve conflicts if any. The branch must sit directly on top of `master` so the
review and the merge see only this feature's diff. Check its layers still read
one at a time (mechanical, then behaviour, then tests and docs) and that it stays
under 149 files: `git diff --name-only master..HEAD | wc -l`.

## 2. Max-effort review (parallel finders)

Get the review diff: `git diff master...HEAD`.

Spawn **independent finder subagents in parallel** (one Agent tool call with
several invocations), each over the same diff with a different lens. Scale the
count to the feature (4-5 is typical):

- **Correctness** - line-by-line; inverted conditions, off-by-one, wrong
  endpoint or HTTP method, query parameters Forgejo ignores or names
  differently (check `https://<host>/swagger.v1.json`), pagination that stops
  after one page, response fields read that the API does not send, exit codes.
- **Memory and Zig pitfalls** - every allocation has an owner and is freed on
  both paths (`defer` / `errdefer`); no slice kept past the buffer or arena it
  points into; writers flushed; integer casts that can trap on API values
  (`@intCast` on an id or count); `catch unreachable` on anything that can fail
  at runtime; std APIs used as 0.16 defines them, not as older Zig did.
- **Security** - the token never reaches argv, logs, error messages, `--json`
  output or a URL; the config file is created 0600; git is invoked with an
  argument vector, never through a shell, and a user or API value starting with
  `-` cannot become a git option (use `--`); TLS verification is never turned
  off; `api` passthrough cannot be pointed at another host with the token.
- **gh parity / UX** - flag names and short forms match `gh`, output matches
  its shape on a TTY and stays machine-readable off one, errors say what to do
  next, `--help` covers every flag, TTY-only prompts never fire when piped.
- **Tests** - does the mock-server test cover the error paths (401, 404, 422,
  empty list, pagination), and do git-touching tests run in temporary repos
  with no real `HOME`?

Each finder returns findings as JSON objects `{file, line, severity, summary,
failure_scenario}`, verified (quote the line), most-severe first. Tell them NOT
to fix anything. Then optionally run one **sweep** finder that has the merged
list and hunts only for gaps.

## 3. Fix what's confirmed

Triage the findings. Fix every **confirmed correctness / memory / security**
issue and the worthwhile quality ones. For anything real-but-out-of-scope, add a
`TODO.md` line rather than dropping it. Re-verify a claim before fixing -
finders surface plausible-but-wrong items too. Fixes land as new layers on top:
`[<branch>] fix(<area>): max-review fixes - <one-line summary>`.

## 4. Update the brain

Bring `brain/` in line with what this feature changed - it ships in the SAME
merge, not as a follow-up. Apply the **brain** skill; the essentials:

- New command group -> `brain/features/<group>.md` (commands, flags, endpoints,
  gh differences, ending with `## Sources`), a row in `brain/features/index.md`
  and the catalog in `brain/BRAIN.md`.
- Changed a layer (config, client, resolution, output) -> update its
  `brain/architecture/*.md`.
- New non-obvious decision -> `brain/decisions.md` with its why. New term ->
  `brain/glossary.md`.
- Tick the shipped items in `ROADMAP.md` and add the `CHANGELOG.md`
  `[Unreleased]` entries if the branch has not already.

Quick check before committing: every relative link in a touched brain doc
resolves to a real file.

## 5. Gate (must be green before merge)

```bash
mise run fmt
mise run check        # zig fmt --check, shellcheck, tests, ReleaseSafe build
```

## 6. Merge

Once smith can open and merge pull requests (ROADMAP P1), dogfood it:

```bash
git push -u origin <branch>
smith pr create --fill
smith pr checks --watch
smith pr merge --merge --delete-branch
```

Until then, fast-forward locally and push:

```bash
cd ~/repos/smith
git merge --ff-only <branch>
git push origin master
```

## 7. Release

Run the **release** skill. Pick the bump: **minor** for new commands or flags,
**patch** for fix-only. Stash any unrelated dirty files (e.g. the user's
`TODO.md`/`ROADMAP.md` edits) so the tree is clean, then restore them after.

## 8. Clean up

```bash
wt remove <branch>
```

## Done when

The feature is on `master`, the brain reflects the change, the gate was green, a
tag is pushed, and the worktree is gone. Report the version and a one-line
summary of what was fixed in review.
