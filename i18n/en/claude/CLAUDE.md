# Global rules

## Language

Always reply to the owner in <持ち主の言語> (also after the context is summarized). PRs, commits and messages to other personas may stay in the language of that repository.

## Running brain (`~/brain`)

`~/brain` is a personal Obsidian vault. It collects daily logs, project status, decisions and knowledge.

### When starting work
- Before starting a task, check the related notes in `~/brain`. At minimum, look at these three:
  - The most recent daily note in `~/brain/daily/` (how far you got last time)
  - `~/brain/projects/<project-name>.md` (the current state of the project)
  - Related decision notes in `~/brain/decisions/` (do not reopen policies that are already decided)
- To search, `grep -ril "<keyword>" ~/brain` is fast.
- If you are about to propose something that contradicts an existing decision, read that decision note first. If you overturn it, state the reason.

### When recording
- Record important decisions and lessons in `~/brain`. Do not let them end inside the conversation.
  - Settled policies, technology choices and trade-offs → `~/brain/decisions/YYYY-MM-DD-summary.md`, **one decision per file**
  - Reusable procedures and research results → `~/brain/knowledge/`
  - Changes to a project's current state → update `~/brain/projects/<project-name>.md`
  - That day's work log → `~/brain/daily/YYYY-MM-DD.md` (the SessionEnd hook appends to it automatically)
- Do not write down trivial day-to-day work. Only what is worth referring to later.

### brain format rules (always follow)
- **Frontmatter is required**: put YAML frontmatter with `date` / `project` / `tags` at the top of every note.
  ```yaml
  ---
  date: 2026-08-29        # Absolute date. Never use relative expressions
  project: my-app          # none if not applicable
  tags: [decision, infra]  # never empty
  ---
  ```
- **One note, one topic**: when topics multiply, split the file (only `daily/` may be appended chronologically).
- **Link with `[[wikilink]]`**: always refer to other notes as `[[note-name]]`. Never use relative paths or URLs.
  The link target may not exist yet.
- **decisions: one per file**: never combine several decisions in one file. Write background / decision / reason / rejected options / impact.
- For details, see `~/brain/README.md`. When in doubt, that file is authoritative.

### Automation
`~/.claude/hooks/session-end-brain.sh` appends a summary to the daily note at SessionEnd and commits to `~/brain`.
If you edit `~/brain` by hand, also commit it.
