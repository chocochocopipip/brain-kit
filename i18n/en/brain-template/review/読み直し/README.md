---
date: 2026-01-01
project: none
tags: [review, re-read]
---

# Re-read (once a month, answers hidden)

Have <レビュー担当名> read past PRs with known defects again **without telling it the answers**, and see whether the current criteria catch them.
It is a regression check of whether the criteria are growing. The partner scores the results in `評価/`.

## Flow

1. **The partner picks** (start of the month, 3 to 5 PRs): PRs under "Misses" or "Defects found in production" in the evaluation, and the "past PRs" in `規準.md`.
   Mix in one PR with no defect too (to see false findings). Avoid PRs that appear in this month's or last month's `評価/` (<レビュー担当名> reads them at startup)
2. **The answers go in the partner's area**: `<相棒名>/21_読み直しの答え.md` (where each defect was and what it was).
   The partner's area does not appear in <レビュー担当名>'s worktree. <レビュー担当名> does not read it
3. **Hand over only `repo#PR` and the head to read (the sha from when the defect was in).** Do not say whether there is a defect, or its type
4. **<レビュー担当名> reads**: with the current criteria version, by the usual procedure. No comments on the PR.
   Do not look at later commits, comments, issues, or that PR's row in `評価/` (they show the answer).
   Write the results in `読み直し/YYYY-MM.md` (copy [[読み直し/_テンプレート]])
5. **The partner matches them up**: compare with the answers, and write caught / missed / false findings in `21_読み直しの答え.md` and in the monthly section of `評価/YYYY-MM.md`.
   Tell <レビュー担当名> the types it missed, and let it decide whether to add them to the criteria (if added, bump the version: [[規準の版/README]])

Related: [[規準]], [[評価/README]]
