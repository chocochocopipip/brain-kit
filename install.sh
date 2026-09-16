#!/usr/bin/env bash
# brain-kit installer
#
#   ./install.sh --partner <相棒名> [--brain <dir>] [--yes]
#
# やること:
#   1. $BRAIN（既定 $HOME/brain）を作り、brain-template/ の骨格を置く。既にあれば止まる
#   2. $HOME/.claude/CLAUDE.md, skills/{<相棒名>,dev,grilling}, hooks/* を置く
#      （既存があれば backup ディレクトリへ退避してから上書きの確認）
#   3. $HOME/.claude/settings.json に hooks / statusLine / enabledPlugins をマージする（丸ごと上書きしない）
#   4. $BRAIN を git init して初回コミット
#
# ユーザー名やパスは決め打ちしない。すべて $HOME 起点。
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARTNER="partner"
BRAIN="${BRAIN_DIR:-$HOME/brain}"
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --partner) PARTNER="$2"; shift 2 ;;
    --brain)   BRAIN="$2"; shift 2 ;;
    --yes|-y)  YES=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$PARTNER" in
  ""|*/*|*" "*) echo "error: --partner に空文字・スラッシュ・空白は使えない" >&2; exit 2 ;;
esac

CLAUDE_DIR="$HOME/.claude"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$CLAUDE_DIR/backup-brain-kit-$STAMP"

say()     { printf '\033[1m%s\033[0m\n' "$*"; }
confirm() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [[ "${a:-}" =~ ^[yY] ]]; }
need()    { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 が要る" >&2; exit 1; }; }

need git; need python3
command -v node   >/dev/null 2>&1 || echo "warn: node が無い。SessionEnd フック（brain-digest.js）が動かない"
command -v claude >/dev/null 2>&1 || echo "warn: claude CLI が無い。フックの自動要約は生の依頼一覧にフォールバックする"

# 置き換え: <相棒名> → $PARTNER（指定したファイル群のみ）
fill() { # fill <file>...   （for f; は位置引数を順に回す bash の省略形）
  local f
  for f; do python3 - "$PARTNER" "$f" <<'PY'
import sys, io
name, f = sys.argv[1], sys.argv[2]
s = io.open(f, encoding="utf-8").read()
t = s.replace("<相棒名>", name)
if t != s:
    io.open(f, "w", encoding="utf-8").write(t)
PY
  done
}

# 既存ファイル/ディレクトリを退避してから置く
place() { # place <src> <dst>
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    mkdir -p "$BACKUP"
    cp -a "$dst" "$BACKUP/"
    echo "  既存を退避: $dst -> $BACKUP/"
    confirm "  $dst を上書きする？" || { echo "  skip: $dst"; return 0; }
    rm -rf "$dst"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  echo "  置いた: $dst"
}

# ---------------------------------------------------------------- 1. brain
say "[1/4] brain: $BRAIN"
if [ -e "$BRAIN" ]; then
  echo "error: $BRAIN が既にある。別の場所にするなら --brain <dir>。" >&2
  exit 1
fi
cp -a "$KIT/brain-template" "$BRAIN"
mv "$BRAIN/partner" "$BRAIN/$PARTNER"
fill $(find "$BRAIN" -type f -name '*.md')
echo "  相棒名: $PARTNER  → $BRAIN/$PARTNER/"

# ---------------------------------------------------------------- 2. ~/.claude
say "[2/4] Claude Code: $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/hooks"

place "$KIT/claude/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

place "$KIT/claude/skills/partner"  "$CLAUDE_DIR/skills/$PARTNER"
if [ -f "$CLAUDE_DIR/skills/$PARTNER/SKILL.md" ]; then
  fill "$CLAUDE_DIR/skills/$PARTNER/SKILL.md"
  python3 - "$PARTNER" "$CLAUDE_DIR/skills/$PARTNER/SKILL.md" <<'PY'
import sys, io, re
name, f = sys.argv[1], sys.argv[2]
s = io.open(f, encoding="utf-8").read()
s = re.sub(r"^name: partner$", f"name: {name}", s, count=1, flags=re.M)
io.open(f, "w", encoding="utf-8").write(s)
PY
fi
place "$KIT/claude/skills/dev"      "$CLAUDE_DIR/skills/dev"
[ -f "$CLAUDE_DIR/skills/dev/SKILL.md" ] && fill "$CLAUDE_DIR/skills/dev/SKILL.md"
place "$KIT/claude/skills/grilling" "$CLAUDE_DIR/skills/grilling"

for f in session-end-brain.sh brain-digest.js; do
  place "$KIT/claude/hooks/$f" "$CLAUDE_DIR/hooks/$f"
  chmod +x "$CLAUDE_DIR/hooks/$f" 2>/dev/null || true
done

# ---------------------------------------------------------------- 3. settings.json merge
say "[3/4] settings.json にマージ"
SETTINGS="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS" ]; then
  mkdir -p "$BACKUP"; cp -a "$SETTINGS" "$BACKUP/settings.json"
  echo "  既存を退避: $SETTINGS -> $BACKUP/settings.json"
fi
python3 - "$KIT/claude/settings.snippet.json" "$SETTINGS" <<'PY'
import json, sys, os, io
snip_path, settings_path = sys.argv[1], sys.argv[2]
snip = json.load(io.open(snip_path, encoding="utf-8"))
snip.pop("_comment", None)
cur = {}
if os.path.exists(settings_path):
    try:
        cur = json.load(io.open(settings_path, encoding="utf-8"))
    except Exception as e:
        sys.exit(f"error: {settings_path} が JSON として読めない: {e}")
added = []

# hooks: イベントごとに、同じ command が無いグループだけ追加
hooks = cur.setdefault("hooks", {})
for ev, groups in snip.get("hooks", {}).items():
    have = hooks.setdefault(ev, [])
    existing = {h.get("command") for g in have for h in g.get("hooks", [])}
    for g in groups:
        cmds = {h.get("command") for h in g.get("hooks", [])}
        if cmds & existing:
            continue
        have.append(g); added.append(f"hooks.{ev}")

# statusLine: 無いときだけ
if "statusLine" not in cur and "statusLine" in snip:
    cur["statusLine"] = snip["statusLine"]; added.append("statusLine")

# enabledPlugins: 無いキーだけ
ep = cur.setdefault("enabledPlugins", {})
for k, v in snip.get("enabledPlugins", {}).items():
    if k not in ep:
        ep[k] = v; added.append(f"enabledPlugins.{k}")

# permissions: 既存に permissions が無いときだけ最小例を置く（既存の allow には触らない）
if "permissions" not in cur and "permissions" in snip:
    cur["permissions"] = snip["permissions"]; added.append("permissions(最小例)")

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
io.open(settings_path, "w", encoding="utf-8").write(json.dumps(cur, ensure_ascii=False, indent=2) + "\n")
print("  追加:", ", ".join(added) if added else "なし（すべて既にあった）")
PY

# ---------------------------------------------------------------- 4. git init
say "[4/4] git init: $BRAIN"
git -C "$BRAIN" init -q
git -C "$BRAIN" add -A
git -C "$BRAIN" commit -q -m "brain: 初期化（brain-kit、相棒名=$PARTNER）" \
  || echo "warn: 初回コミットに失敗（git の user.name / user.email を設定してから再実行）"

cat <<MSG

完了。
  brain     : $BRAIN
  相棒      : $BRAIN/$PARTNER/00_核.md   ← まず憲法をここに書く
  skills    : $CLAUDE_DIR/skills/{$PARTNER,dev,grilling}
  hooks     : $CLAUDE_DIR/hooks/session-end-brain.sh（SessionEnd で daily/ に追記）
  設定退避  : ${BACKUP}（退避したものがあれば）

次にやること:
  1. $BRAIN/$PARTNER/00_核.md に相棒の憲法を書く（skill '$PARTNER' はこれを読んで灯る）
  2. $BRAIN/projects/<プロジェクト名>.md を1枚作る
  3. claude を起動して /$PARTNER と打つ
  4. Orca を使うなら ORCA.md を読む。プラグインは README の「プラグイン」を見る
MSG
