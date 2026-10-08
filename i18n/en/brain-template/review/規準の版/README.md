---
date: 2026-01-01
project: none
tags: [review, criteria]
---

# Criteria versions (copies of earlier versions)

Before bumping the version of `規準.md`, copy its full text from before the bump here as `v<N>.md` (N = the version before the bump). **Never rewrite the copies.**
This is so you can read later which items "criteria version N" in the log pointed to at the time.

## How to bump the version (<レビュー担当名>)

1. `cp review/規準.md review/規準の版/v<N>.md`
2. Add or change items in `規準.md`. Change "version N" in the heading to N+1
3. One line in `## Version history` (version, date, what changed, the PR that triggered it)
4. Link the missed PR under "past PRs" of the added item. Linked PRs become candidates for the monthly re-read ([[読み直し/README]])

Decide whether to add an item from the partner's evaluation (`評価/`) and the re-read results. Do not add by guesswork.
