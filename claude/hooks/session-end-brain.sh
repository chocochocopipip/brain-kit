#!/usr/bin/env bash
# SessionEnd hook: summarize the finished Claude Code session and append it to
# the daily note in ~/brain, then commit.
#
# Input : SessionEnd hook JSON on stdin (session_id, transcript_path, cwd, reason)
# Output: appends to ~/brain/daily/YYYY-MM-DD.md and commits in ~/brain
# Log   : ~/.claude/hooks/brain-hook.log
#
# Never fails the session: every path exits 0.

set -uo pipefail

BRAIN="${BRAIN_DIR:-$HOME/brain}"
HOOK_DIR="$HOME/.claude/hooks"
LOG="$HOOK_DIR/brain-hook.log"
SUMMARY_MODEL="${BRAIN_HOOK_MODEL:-haiku}"
SUMMARY_TIMEOUT="${BRAIN_HOOK_TIMEOUT:-60}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || :; }

# Recursion guard: the summarizer below is itself a `claude` run, which fires
# its own SessionEnd hook. That child sees this variable and stops immediately.
if [ "${BRAIN_HOOK_RUNNING:-}" = "1" ]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"

read_field() {
  printf '%s' "$INPUT" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{const o=JSON.parse(s);const v=o[process.argv[1]];process.stdout.write(v==null?"":String(v));}catch{}
    });' "$1" 2>/dev/null
}

TRANSCRIPT="$(read_field transcript_path)"
SESSION_ID="$(read_field session_id)"
SESSION_CWD="$(read_field cwd)"
REASON="$(read_field reason)"

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  log "skip: no transcript (session=$SESSION_ID reason=$REASON)"
  exit 0
fi

if [ ! -d "$BRAIN" ]; then
  log "skip: brain vault not found at $BRAIN"
  exit 0
fi

DIGEST="$(node "$HOOK_DIR/brain-digest.js" "$TRANSCRIPT" 2>/dev/null)"
if [ -z "$DIGEST" ]; then
  log "skip: empty digest (session=$SESSION_ID reason=$REASON)"
  exit 0
fi

PROMPT='あなたは開発者の作業ログ係です。以下は Claude Code の1セッションの記録です。
このセッションの要約を日本語の Markdown で書いてください。出力は本文のみ。前置き・後書き・コードフェンスは書かないこと。

次の3つの見出しをこの順で必ず含めること:

### やったこと
実際に完了した作業を箇条書きで。ファイルパスやコマンドなど具体名を含める。推測で補わない。

### 決定事項
このセッションで決まった方針・選択とその理由を箇条書きで。決定がなければ「- なし」と書く。

### 未解決事項
残っている課題・ブロッカー・次にやるべきことを箇条書きで。なければ「- なし」と書く。

制約:
- 記録にない事実を書かない。実行されなかったことを完了したように書かない。
- 全体で30行以内に収める。
- ツールを一切使わず、そのまま回答する。

--- セッション記録 ---
'

SUMMARY=""
if command -v claude >/dev/null 2>&1; then
  SUMMARY="$(
    printf '%s%s\n' "$PROMPT" "$DIGEST" |
    BRAIN_HOOK_RUNNING=1 timeout "$SUMMARY_TIMEOUT" claude -p \
      --model "$SUMMARY_MODEL" \
      --disallowedTools "Bash" "Edit" "Write" "Read" "Glob" "Grep" "Task" "WebFetch" "WebSearch" \
      2>>"$LOG"
  )" || SUMMARY=""
fi

if [ -z "$(printf '%s' "$SUMMARY" | tr -d '[:space:]')" ]; then
  log "warn: summarizer produced nothing; falling back to raw prompt list (session=$SESSION_ID)"
  SUMMARY="$(printf '%s' "$DIGEST" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const asks=s.split("\n\n").filter(p=>p.startsWith("## USER\n"))
        .map(p=>p.slice(8).split("\n")[0].slice(0,160));
      process.stdout.write(
        "### やったこと\n- (自動要約に失敗。以下はこのセッションの依頼内容)\n" +
        asks.map(a=>"- "+a).join("\n") +
        "\n\n### 決定事項\n- 未記録（手動で補完すること）\n\n### 未解決事項\n- このセッションの要約が自動生成できなかった\n");
    });' 2>/dev/null)"
fi

DATE="$(date +%F)"
NOTE="$BRAIN/daily/$DATE.md"
TIME="$(date +%H:%M)"

# New daily note: write the frontmatter the vault rules require.
if [ ! -f "$NOTE" ]; then
  cat >"$NOTE" <<EOF
---
date: $DATE
project: none
tags: [daily, claude-code]
---

# $DATE

EOF
fi

{
  printf '\n## %s Claude Code セッション\n\n' "$TIME"
  printf -- '- 作業ディレクトリ: `%s`\n' "${SESSION_CWD:-unknown}"
  printf -- '- セッションID: `%s`\n' "${SESSION_ID:-unknown}"
  printf -- '- 終了理由: `%s`\n\n' "${REASON:-unknown}"
  printf '%s\n' "$SUMMARY"
} >>"$NOTE"

cd "$BRAIN" 2>/dev/null || { log "error: cannot cd to $BRAIN"; exit 0; }

if [ ! -d "$BRAIN/.git" ]; then
  log "warn: $BRAIN is not a git repo; note appended but not committed"
  exit 0
fi

git add -A >>"$LOG" 2>&1
if git diff --cached --quiet; then
  log "ok: nothing to commit (session=$SESSION_ID)"
  exit 0
fi

if git commit -q -m "daily($DATE): Claude Code session $TIME" >>"$LOG" 2>&1; then
  log "ok: committed session=$SESSION_ID reason=$REASON note=$NOTE"
else
  log "error: git commit failed (session=$SESSION_ID)"
fi

exit 0
