---
name: brain
description: Use and maintain the brain/ knowledge base - the committed docs describing how smith works (stack, architecture, features, decisions, glossary). Invoke when the user asks how/where something works ("how does repo resolution work", "where is the token stored", "explain pr checkout"), when onboarding, or when asked to update, audit, or fix the brain after a change. Read brain/BRAIN.md first; navigate via the indexes, not a whole-tree grep.
---

# The brain

`brain/` is the committed knowledge base: how smith works, written so you can
answer without reading the source. Use it as the first stop for understanding,
and keep it true to the code.

## Navigating (to answer a question)

1. Open `brain/BRAIN.md` - the entry index. It has a topic table and a **Find by
   question** table.
2. Drill via the sub-indexes: `brain/architecture/index.md` (the how: argument
   parsing, config, HTTP client, repo resolution, output, tests) and
   `brain/features/index.md` (the what: one doc per command group). Don't grep
   the whole tree; the indexes are the routing layer.
3. Land on the leaf doc. It is self-contained and ends with a `## Sources` list
   of the real code paths - follow those only if the doc isn't enough or you
   suspect drift.
4. Terms -> `brain/glossary.md`. Rationale / "why" -> `brain/decisions.md`.
   Toolchain and tasks -> `brain/stack.md`.

Structure:

```
brain/BRAIN.md                 root index + find-by-question + feature catalog
brain/stack.md  glossary.md  decisions.md
brain/architecture/index.md    one doc per layer
brain/features/index.md        one doc per command group (auth, repo, pr, ...)
```

## Maintaining (after a change)

The brain is load-bearing and the rule is in `CLAUDE.md` ("The brain"). The code
is the source of truth - if a doc disagrees with reality, fix the doc.

- A change that makes a brain doc wrong fixes that doc in the **same branch**.
- New command group -> add `brain/features/<group>.md` (commands, flags, the
  Forgejo endpoints each one calls, gh differences), then a row in
  `brain/features/index.md` and the catalog in `brain/BRAIN.md`. New layer ->
  add or update a `brain/architecture/*.md` and its index row.
- New non-obvious decision -> append it to `brain/decisions.md` with its "why"
  and date. New term -> `brain/glossary.md`.
- Style: dense, skimmable, present tense, normal prose. No em-dashes.
  Cross-link siblings with relative markdown links. Cite source paths instead
  of restating code. End each doc with `## Sources`.

## Auditing (drift check on request)

When asked to verify the brain matches reality:

1. Scope it to the relevant leaf doc(s) - don't re-audit everything.
2. For each, read the `## Sources` paths and confirm the doc's claims still hold
   (command names, flags, endpoints, config keys, file locations, behaviour).
3. Where they diverge, the code wins: correct the doc. Note what you changed.
4. If a whole layer moved or a command group shipped/was removed, update the
   indexes (`BRAIN.md`, the two `index.md`) too so navigation stays accurate.

For a broad audit, fan out read-only agents (one per architecture or feature
doc) that each diff their doc against its `## Sources`, then apply the fixes.
