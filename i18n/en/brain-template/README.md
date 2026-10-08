# brain

A personal Obsidian vault. It gathers work logs, decisions and learnings in one place.

## Directory layout

| Directory | Purpose |
| --- | --- |
| `daily/` | Daily log. One file per day, `YYYY-MM-DD.md`. The Claude Code SessionEnd hook appends to it automatically |
| `projects/` | The state, goal and current state of each project. One file per project |
| `decisions/` | Records of decisions. **One decision per file** |
| `knowledge/` | Reusable knowledge, procedures and research results |
| `archive/` | Past exports and originals. Read only |
| `inbox.md` | A place for unsorted notes. Sort it into the directories above regularly and empty it |
| `<相棒名>/` | The partner's memory area. **Read-only for everyone except the partner itself** (`90_原本/` (originals) may not be altered even by the partner) |
| `dev/` | <開発担当名>'s memory area. The current state of development and the reports. Rules in [[dev/README]] |
| `review/` | <レビュー担当名>'s memory area. Review criteria (versioned), log and evaluation. Rules in [[review/README]] |
| `release/` | <リリース担当名>'s memory area. Release procedures and the log. Rules in [[release/README]] |
| `.brain-kit/` | Record of the brain-kit version and names (`config.json`). Updates (`--update`) read and write it. Do not edit by hand |

## Rules

### 1. One note, one topic
Write only one topic in one file. When topics grow, split the file and connect them with `[[wikilink]]`.
`daily/` is the exception: append the day's events in time order.

### 2. Frontmatter is required
Put YAML frontmatter at the top of every note, and always include the three keys `date` / `project` / `tags`.

```markdown
---
date: 2026-01-01        # Date (YYYY-MM-DD). For past events, the date of the event, not the date of writing
project: my-app          # Related project. none for cross-cutting content
tags: [setup, ci]        # At least one. Lowercase kebab-case
---
```

- `date`: always an absolute date. Never write relative words such as "yesterday" or "last week"
- `project`: match a note name in `projects/`. `none` if nothing applies
- `tags`: never an empty array. If unsure how to classify, use one broad tag

### 3. Connect related notes with `[[wikilink]]`
Always refer to other notes as `[[note name]]` (never as relative paths or URLs).

- The link target need not exist yet. An unwritten link marks "the next note to write"
- When a term, person or project name appears in the text, link it as long as a matching note exists
- From the daily log, always link the projects and decision notes touched that day

### 4. One decision per file in decisions
One file per decision. The file name is `YYYY-MM-DD-summary-of-the-decision.md`.
Never put several decisions in one file. The body must contain at least this:

```markdown
---
date: 2026-01-01
project: my-app
tags: [decision, infra]
---

# Chose Postgres as the database

## Background
What the problem was, and when and who decided.

## Decision
What was decided. One or two sentences, stated firmly.

## Reasons
Why this was chosen.

## Options not taken
Options considered but not taken, and why.

## Impact
What this decision changes. Related: [[my-app]]
```

When a decision is reversed, do not delete the original file. Append a `## Withdrawn` section and put a `[[wikilink]]` to the new decision note.

### 5. Handling the inbox
You may jot down any idea in `inbox.md` first. This is the only place exempt from the frontmatter rule.
About once a week, move its contents into notes in the right directories and empty `inbox.md` again.

## File naming
- Lowercase kebab-case (Japanese note names may stay in Japanese)
- `daily/` is `YYYY-MM-DD.md`
- `decisions/` is `YYYY-MM-DD-summary.md`
- `projects/` is the project name itself (e.g. `my-app.md`)

## Automation
The Claude Code SessionEnd hook (`~/.claude/hooks/session-end-brain.sh`) appends "what was done, decisions, open issues"
to `daily/YYYY-MM-DD.md` at the end of each session, and commits this repository automatically.
You may tidy the auto-appended sections by hand later. Cut important decisions out into `decisions/`.
