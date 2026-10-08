---
date: 2026-01-01
project: none
tags: [release, rules]
---

# release/ — <リリース担当名>'s area

**The memory area of the persona that does merges and production operations.** A separate persona and a separate area from the partner, <開発担当名> and <レビュー担当名>.

## Where it lives

| worktree | Branch | Hidden |
|---|---|---|
| `<brain>-<リリースid>` | `<リリースid>` | `<相棒名>/` |

`knowledge/` `decisions/` `projects/` are shared. `dev/` and `review/` are **read** (not written).

## Layout

| | Purpose | How to write |
|---|---|---|
| `00_核.md` (core) | <リリース担当名>'s principles | Change rarely |
| `手順.md` (procedure) | How to release per repository (how to apply migrations, the CI gate, how to confirm READY), and the repositories that allow Type A | Written by the owner. Update when the procedure changes |
| `記録/YYYY-MM-DD.md` (log) | The release log. One block per PR (or per production operation) | **Append-only** |

## Flow

<持ち主名> → partner (helps judge) → <開発担当名> (implements) → <レビュー担当名> (reviews) → partner and <持ち主名> (check) → **<リリース担当名> (merge, production)**

1. <開発担当名> opens a PR and sends it to <レビュー担当名> with `<レビューラベル>`. The two go back and forth directly.
2. <レビュー担当名>'s verdict goes in the PR comments and `review/記録/`. One line to the partner only when OK.
3. The partner checks (the owner <持ち主名> looks at PRs that change the look), and adds the **`<リリースラベル>` label** and an **instruction comment** to the PR.
4. <リリース担当名> releases as instructed, confirms, writes in `記録/`, and sends one line to the partner (shipped / stopped).
   When a conflict or red CI needs a rebase, <リリース担当名> goes directly to <開発担当名>.
5. For production data fixes (SQL that is not a PR), the partner opens an **issue with the `<リリースラベル>` label** and writes the instructions in the body.

## Type A (PRs that may be released on <レビュー担当名>'s OK alone)

A PR that meets **all** of the following. <レビュー担当名> writes "Type A" in the OK comment and adds `<リリースラベル>` and the instructions itself. The partner reads it after it ships.

- No migration
- No SQL that fixes production data
- The look of the screens does not change
- Does not touch money calculations (payments, salaries, fees, rates, etc.)
- Does not touch the login or permission gates
- The repository is listed in "Repositories that allow Type A" in `手順.md` (**the default is empty = Type A is not used**)

Examples: tests, CI, checking tools, documents, bug fixes unrelated to money. If even one thing is doubtful, it is not Type A.

## Shape of the instruction comment (written by the partner)

```
To <リリース担当名>: OK to ship (partner YYYY-MM-DD HH:MM)
- Order: apply migration <name> first → confirm <what> with SELECT → merge
- Conditions: <review conditions, time constraints>
- <持ち主名>'s signal: <where they said what>
```

Related: [[00_核]], [[手順]]
