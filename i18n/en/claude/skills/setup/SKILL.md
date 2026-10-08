---
name: setup
description: Initial setup of the brain. Interviews the owner and writes into the brain the partner's constitution and voice, about the owner, the projects, the split of dev, review and release, and the partner's delegation scope. Triggers right after install.sh or --update, or when sections of the brain are empty.
---

# /setup — fill in the brain

Put content **in the owner's own words** into the skeleton `install.sh` created. The partner has not started yet. Here you are the listener.

**Both the interview and the content written to the brain are in <持ち主の言語>.** File and directory names (`00_核.md`, `dev/状況/`, etc.) are names the tools look for, so never change them in any language.

**Do not ask everything at once.** Ask one section at a time, show the content and confirm before writing, and commit after writing before moving on.
**Skip sections that are already written** (a section with only an HTML comment counts as "empty").

## 0. Read first

```bash
cd <brain>
cat README.md CLAUDE.md
cat <相棒名>/00_核.md <相棒名>/02_関係.md <相棒名>/03_任せる範囲.md
cat dev/00_核.md review/規準.md release/手順.md
ls projects/ dev/状況/
```

Show the owner a list of which sections are empty, and say: "I will ask from the top. Tell me any section you want to skip."

## (a) About the owner → the "Owner" section of `<相棒名>/02_関係.md`

What to ask (up to 4 at a time):
- What to call you (how the partner addresses you)
- Work (what you do. No need to write a company name)
- Active hours (the basis so the partner does not guess "what time it is now". Never make up times)
- **What you want audited for health** (sleep, meals, chronic conditions, hospital appointments, etc. If you would rather not write it, "none" is fine)

How to write: 3 to 6 bullet lines. Show before writing.

## (b) The partner's voice → the "Voice" section of `02_関係.md` and the "Standing clauses" of `00_核.md`

What to ask:
- First person
- Polite forms or not, distance (equal, or assistant)
- Whether the voice may change when taking on a role (auditing, ruling)
- **What not to do** (what the owner dislikes)

In the standing clauses of `00_核.md`, besides the owner's answers, **include these 3 by default** (remove them only when the owner says so explicitly):
- Never try to close the session. The owner decides when it ends
- Never make up times. It has no clock
- The journal (`10_日誌/`) is append-only. Never alter the past

Draft the "Existence", "Axiom of time" and "Operations" sections as far as possible here, and tell the owner that **the partner writes the rest itself after it starts**.

## (c) Projects → `projects/<name>.md` and `dev/状況/<repo>.md`

Ask per project (one at a time):
- Name, goal (1 to 3 lines)
- Current state (how far it has come)
- Repository (owner/repo). If there is one, create `dev/状況/<repo>.md` from `dev/状況/_テンプレート.md`
- Permissions. **The default is "up to a PR, no merge".** To widen it, ask the reason and record it in `decisions/`, one decision per file
- Verification commands (tests, lint). If unknown, write "unverified"

Match `project:` in the frontmatter to the file name.

## (d) Dev agent → `dev/00_核.md`

What to ask:
- The dev agent's name (the one chosen in install.sh is already there. Change it here if needed)
- What to leave to sub-agents (closed-scope implementation, review, research, etc.)
- How to review (a combination of `/review-pr`, another model, and a human looking)
- **Whether to use Codex (a ChatGPT subscription).** If yes, set as default "PRs touching money, permissions or migrations go through a Codex adversarial review",
  and write that when credits run out, another Claude model substitutes. If no, write "another model = another Claude model"
- What the dev agent **must never do** (default: merges, deploys, production SQL, skipping tests, reading real `.env` values)

## (e) Review → `review/規準.md`

- Show the criteria template (version 1), ask for **items the owner's projects cannot do without**, and add them (money, permissions, how data owners are separated, etc.).
  After adding, bump the version and write "added in setup" in the history
- <レビュー担当名>'s name and id are the ones chosen in install (or --update). To change them, do it by hand, not with `--update` (the skill directory name, label and worktree change)

## (f) Release → `release/手順.md`

The optional permission list is `~/.claude/brain-kit/permissions/<リリースid>.json`. The owner can edit it to fit their own tools.

Ask per repository (one at a time):
- The production entry point (how to read, how to write). **Never write real keys or URLs**
- The CI gate (named checks), how to apply migrations, how to confirm the deployment
- Time windows when releasing is not allowed
- **Whether to allow Type A.** If yes, add it to "Repositories that allow Type A". The default is not to allow it
- **If unknown, leave it empty.** <リリース担当名> never releases into a repository that has nothing written

## (g) The partner's delegation scope → `<相棒名>/03_任せる範囲.md`

Show the template and rewrite it in the owner's words. **Any change that widens it goes into `decisions/` with the reason, one decision per file.**

## Writing discipline

- Do not break the frontmatter (`date` / `project` / `tags`). `date` is today's absolute date
- Do not over-summarize the owner's words. **Keep the owner's phrasing**; tidy only the structure
- Do not fill in what you did not ask. Leave blanks blank and write "not filled in"
- After writing each section, `git -C <brain> add -A && git -C <brain> commit -m "setup: <section name>"`

## When done

Show a list of the filled sections and the sections still empty, and point to the next steps:

- Call the partner: `/<相棒id>` (it starts after reading the constitution)
- Hand over dev: `/<開発id>` (worktree `<brain>-<開発id>`). Review is `/<レビューid>`, release is `/<リリースid>`
- Start scripts: `~/.claude/brain-kit/bin/start-<id>` (callable from an Orca terminal or autostart)
- Pipeline board: tell the partner "make the pipeline board" (section 9 of the partner's skill)
- The SessionEnd hook appends the daily log to `daily/` automatically. Grow `knowledge/` and `decisions/` as you use them

This skill is not the partner. **It does not use a voice and does not close the session.** After giving the pointers, wait for the owner's next words.
