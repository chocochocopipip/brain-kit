---
date: 2026-01-01
project: none
tags: [review, rules]
---

# review/ — <レビュー担当名>'s area

**The memory area of the persona that reads PRs and doubts them.** A separate persona and a separate area from the partner, <開発担当名> and <リリース担当名>.

## Where it lives

| worktree | Branch | Hidden |
|---|---|---|
| `<brain>-<レビューid>` | `<レビューid>` | `<相棒名>/` |

`knowledge/` `decisions/` `projects/` `daily/` are shared. `dev/` is **read** (not written).

## Layout

| | Purpose | How to write |
|---|---|---|
| `00_核.md` (core) | <レビュー担当名>'s principles | Change rarely |
| `規準.md` (criteria) | The review checklist. **Versioned** | When a miss happens, add an item and link the past PR it should have caught |
| `記録/YYYY-MM-DD.md` (log) | The review log. One block per review | **Append-only** |
| `規準の版/v<N>.md` (criteria versions) | A copy of the criteria from before a version bump | Copy before bumping the version. Never rewrite the copy |
| `読み直し/YYYY-MM.md` (re-read) | The monthly re-read of past PRs with the answers hidden | <レビュー担当名> writes it. The answers are in the partner's area; do not read them |
| `評価/YYYY-MM.md` (evaluation) | The report card the partner writes (template: `評価/_テンプレート.md`) | The partner appends once a day. <レビュー担当名> only reads it |

## Two disciplines

**The log is append.** Never rewrite a verdict afterwards. Correct it with a new block.
**The criteria are managed by version.** When you add or change an item, bump the version and write the reason (which PR's miss it came from). Write the version used in the log.

## Flow

1. <開発担当名> opens a PR and adds the `<レビューラベル>` label.
2. <レビュー担当名> reads it with the current version of `規準.md` and writes on the PR a **verdict** (OK / NG) and **numbered findings**. One block in `記録/`.
3. If NG, <開発担当名> fixes it and asks again on the same PR. The back-and-forth with <開発担当名> is direct, not through the partner.
4. If OK, one line to the partner. The partner and <持ち主名> check it, then hand it to <リリース担当名> with `<リリースラベル>` and an instruction comment.
   For **Type A** (`release/README.md`), <レビュー担当名> hands it directly to <リリース担当名>, and the partner reads it afterwards.
5. Once a day the partner scores in `評価/` (misses / false findings / concreteness / time taken). Once a month, past PRs that contain known defects are re-read with the answers hidden (`読み直し/README.md`).

Related: [[00_核]], [[規準]]
