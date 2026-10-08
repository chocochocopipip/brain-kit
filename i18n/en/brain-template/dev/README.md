---
date: 2026-01-01
project: none
tags: [dev, rules]
---

# dev/ — <開発担当名>'s area

**The memory area of the persona that looks across all development.** A separate persona and a separate area from the partner.

## Purpose of this area

Keep only the **minimum handover state** needed to run many projects at once.
No conversation logs, no design history. The only goal is that **"whoever opens it next can start work in 5 minutes."**

## Layout

| | Purpose | How to write |
|---|---|---|
| `00_核.md` (core) | <開発担当名>'s principles. The core of how it acts | Change rarely |
| `状況/<repo>.md` (status) | The current state of development in each repository | **Replace-only. 50 lines max** |
| `状況/_テンプレート.md` (template) | The card template | Copy it for a repository you touch for the first time |
| `報告/YYYY-MM-DD.md` (reports) | Reports for the partner to read | **Append-only** |

## Two disciplines (this is all)

**The status card is "replace".** It has no past. **Write only the current state.**
Delete old in-progress items. Delete a blocker once it is cleared. **Do not let it grow. If it goes over 50 lines (including frontmatter and headings), something is extra.**

**Reports are "append".** Never break the time order. Treated the same as the partner's journal.

> The partner's journal is append-only (never alter the past).
> <開発担当名>'s status is replace-only (hold only the current state).
> **The roles differ, so the disciplines are opposite.**

## Who may write

- **<開発担当名> (dev session)**: may write `状況/` and `報告/`. Updating `00_核.md` needs discussion
- **The partner**: **only reads** `報告/`. Never writes in `dev/`
- **Other agents**: read only

`<相棒名>/` and `dev/` never write into each other. **Different personas get different areas.**

## Creating a status card

Create it by copying `状況/_テンプレート.md`. **Create it when you first touch a repository.**
Do not create cards for repositories you have not touched (an empty card lies).

## A worktree per persona

install (and `--update`, which adds the four personas) creates them. Orca lines up agents per worktree.

| Worktree | Branch | Who | Hidden |
|---|---|---|---|
| `<brain>` | main | partner (sees everything) | nothing |
| `<brain>-<開発id>` | `<開発id>` | <開発担当名> | `<相棒名>/` |
| `<brain>-<レビューid>` | `<レビューid>` | <レビュー担当名> | `<相棒名>/` |
| `<brain>-<リリースid>` | `<リリースid>` | <リリース担当名> | `<相棒名>/` |

Only the partner's persona area is hidden. `knowledge/` `decisions/` `projects/` `daily/` are shared.
After writing, commit in your own worktree and merge into main with `git -C <brain> merge --no-edit <your id>`.
Start with `~/.claude/brain-kit/bin/start-<id>` (it merges main into that worktree, then starts `claude`).

To create one by hand (when installed with `--no-worktrees`):

```bash
git -C <brain> worktree add <brain>-<開発id> -b <開発id>
cd <brain>-<開発id>
git sparse-checkout init --no-cone          # Do this first. If you forget, cone mode breaks it
printf '/*\n!/<相棒名>/\n' | git sparse-checkout set --stdin
```

> **Never remove it from the tree.** If you delete it on the branch, merging into main deletes it on main too.
> Separate only what is visible; do not separate the history.
>
> If a branch name and a directory name are the same, `git` fails with `ambiguous argument`.
> Spell out the branch as `refs/heads/<name>` and the path as `-- <name>/`.
>
> `decisions/` written on another branch are invisible to the others until merged into main. Merge before handing over.

Related: [[00_核]]
