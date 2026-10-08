# Patrol templates (Orca automations. Optional)

Orca automations are **schedule-triggered only** (there are no webhooks). Use `--precheck` to "run the main job only when there is work" (the main job runs only on exit 0).
These are templates. **Check the actual commands with `orca automations --help` before** creating them (arguments can change between versions).

## Rules

- **Never use `--workspace-mode new-per-run`.** The path changes every time and triggers the folder trust dialog every time. Use the persona's worktree (`<brain>-<id>`) as a fixed one and set `existing`
- **`status: completed` does not even mean "it started".** Check the contents with `orca terminal read`
- Patrols only go as far as **reading, filing issues and opening PRs**. Merges and production operations are done by <リリース担当名>, started by hand, when there is a label and an instruction comment
- Never configure human gates (adding `agent-ready`, permission dialogs) to pass automatically

## Precheck

`~/.claude/brain-kit/automations/precheck.sh <label> [pr]`: looks with `gh` at the repositories in brain's `.brain-kit/config.json`, and returns 0 if there is at least one open item with that label.

| Patrol | Precheck | Main job (what it starts) | Guideline |
|---|---|---|---|
| Dev | `precheck.sh <開発ラベル>` | `~/.claude/brain-kit/bin/start-<開発id>` (worktree `<brain>-<開発id>`) | Every 1-2 hours |
| Review | `precheck.sh <レビューラベル> pr` | `~/.claude/brain-kit/bin/start-<レビューid>` | Every 30 minutes to 1 hour |
| Pipeline board | None | Ask the partner to "update the pipeline board" (in a `/<相棒id>` session) | First thing in the morning |

## Shape (template)

```bash
# Example: start <レビュー担当名> only when there are PRs waiting for review
orca automations create \
  --name "<レビューid>-patrol" \
  --schedule "*/30 * * * *" \
  --workspace-mode existing --worktree "<brain>-<レビューid>" \
  --precheck "$HOME/.claude/brain-kit/automations/precheck.sh <レビューラベル> pr" \
  --command "$HOME/.claude/brain-kit/bin/start-<レビューid>"
# check the argument names with orca automations create --help

orca automations list
orca automations runs <id>
```

## Heavy tests

When dev or review runs tests, passing them through `~/.claude/brain-kit/bin/heavy-lock <command>` lets the next one in only when there is free memory (optional).
Change the concurrency limit and the estimate per run with environment variables (see the comments inside).
