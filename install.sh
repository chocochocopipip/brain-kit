#!/usr/bin/env bash
# brain-kit installer（対話式。引数で与えた項目は聞かない。--yes で全部既定）
#
#   ./install.sh [--partner <相棒名>] [--dev <開発担当名>] [--user <持ち主の呼び名>]
#                [--projects "a,b,c"] [--repos "owner/repo,..."] [--brain <dir>] [--yes]
#
# やること:
#   1. $BRAIN（既定 $HOME/brain）を作り、brain-template/ の骨格を置く。既にあれば止まる
#      <相棒名> <開発担当名> <持ち主名> を置換し、projects/<名前>.md と dev/状況/<repo>.md を作る
#   2. $HOME/.claude/CLAUDE.md, skills/{<相棒名>,<開発担当名>,setup,grilling}, hooks/* を置く
#      （既存があれば backup ディレクトリへ退避してから上書きの確認）
#   3. $HOME/.claude/settings.json に hooks / statusLine / enabledPlugins をマージする（丸ごと上書きしない）
#   4. gh があり認証済みなら、--repos の各リポジトリに issue ラベルを作る
#   5. $BRAIN を git init して初回コミット
#
# ユーザー名やパスは決め打ちしない。すべて $HOME 起点。
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARTNER=""; DEV=""; OWNER=""; PROJECTS=""; REPOS=""
BRAIN="${BRAIN_DIR:-$HOME/brain}"
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --partner)  PARTNER="$2"; shift 2 ;;
    --dev)      DEV="$2"; shift 2 ;;
    --user)     OWNER="$2"; shift 2 ;;
    --projects) PROJECTS="$2"; shift 2 ;;
    --repos)    REPOS="$2"; shift 2 ;;
    --brain)    BRAIN="$2"; shift 2 ;;
    --yes|-y)   YES=1; shift ;;
    -h|--help)  sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()     { printf '\033[1m%s\033[0m\n' "$*"; }
confirm() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [[ "${a:-}" =~ ^[yY] ]]; }
need()    { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 が要る" >&2; exit 1; }; }
# ask <変数名> <質問> <既定>   引数で与えられていれば聞かない。--yes か非対話なら既定
ask() {
  local var="$1" q="$2" def="$3" cur a
  cur="${!var}"
  [ -n "$cur" ] && return 0
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then printf -v "$var" '%s' "$def"; return 0; fi
  read -r -p "$q${def:+ [$def]}: " a
  printf -v "$var" '%s' "${a:-$def}"
}
valid_name() { case "$1" in ""|*/*|*" "*|*"<"*|*">"*) return 1 ;; esac; }

need git; need python3
command -v node   >/dev/null 2>&1 || echo "warn: node が無い。SessionEnd フック（brain-digest.js）が動かない"
command -v claude >/dev/null 2>&1 || echo "warn: claude CLI が無い。フックの自動要約は生の依頼一覧にフォールバックする"

# ---------------------------------------------------------------- 0. 決めること
say "[0/5] 決めること（空 Enter で既定。あとから brain の中で変えられる）"
ask PARTNER  "相棒の名前（必須）" ""
valid_name "$PARTNER" || { echo "error: 相棒の名前が空か、使えない文字（/ 空白 < >）を含む。--partner <名前> で指定" >&2; exit 2; }
ask DEV      "開発担当の名前（コーディングを任せる人格）" "dev"
valid_name "$DEV" || { echo "error: --dev の名前が不正" >&2; exit 2; }
ask OWNER    "あなたの呼び名（相棒があなたをどう呼ぶか）" "持ち主"
ask PROJECTS "プロジェクト名（カンマ区切り。無ければ空）" ""
ask REPOS    "GitHub リポジトリ owner/repo（カンマ区切り。無ければ空）" ""
echo "  相棒=$PARTNER  開発担当=$DEV  呼び名=$OWNER  projects=${PROJECTS:-なし}  repos=${REPOS:-なし}  brain=$BRAIN"

CLAUDE_DIR="$HOME/.claude"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$CLAUDE_DIR/backup-brain-kit-$STAMP"
TODAY="$(date +%F)"

# 置き換え: <相棒名> <開発担当名> <持ち主名>（for f; は位置引数を順に回す bash の省略形）
fill() {
  local f
  for f; do python3 - "$PARTNER" "$DEV" "$OWNER" "$f" <<'PY'
import sys, io
partner, dev, owner, f = sys.argv[1:5]
s = io.open(f, encoding="utf-8").read()
t = s.replace("<相棒名>", partner).replace("<開発担当名>", dev).replace("<持ち主名>", owner)
if t != s:
    io.open(f, "w", encoding="utf-8").write(t)
PY
  done
}
# カンマ区切りを1行1件に（前後の空白を落とす）
split_csv() { printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true; }

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
say "[1/5] brain: $BRAIN"
if [ -e "$BRAIN" ]; then
  echo "error: $BRAIN が既にある。別の場所にするなら --brain <dir>。会社が違えば別 brain にする。" >&2
  exit 1
fi
cp -a "$KIT/brain-template" "$BRAIN"
mv "$BRAIN/partner" "$BRAIN/$PARTNER"
fill $(find "$BRAIN" -type f -name '*.md')
echo "  相棒: $BRAIN/$PARTNER/   開発担当: $DEV（$BRAIN/dev/）"

# projects/<名前>.md
while IFS= read -r p; do
  f="$BRAIN/projects/$p.md"
  [ -e "$f" ] && continue
  cat >"$f" <<MD
---
date: $TODAY
project: $p
tags: [project]
---

# $p

## 目的
<!-- 何のためのプロジェクトか。1〜3行 -->

## 現在地
<!-- いまどこまで来ているか。動いたら書き換える -->

## 権限
<!-- エージェントに許すこと。書かなければ「PR まで、マージしない」 -->
- PR まで。マージしない

## 関連
<!-- リポジトリ、決定ノート、人 -->
MD
  echo "  projects/$p.md"
done < <(split_csv "$PROJECTS")

# dev/状況/<repo>.md（_テンプレート.md から）
while IFS= read -r r; do
  short="${r##*/}"
  f="$BRAIN/dev/状況/$short.md"
  [ -e "$f" ] && continue
  python3 - "$BRAIN/dev/状況/_テンプレート.md" "$f" "$short" "$r" "$TODAY" <<'PY'
import sys, io
src, dst, short, full, today = sys.argv[1:6]
s = io.open(src, encoding="utf-8").read()
s = s.replace("<repo>", short).replace("2026-01-01", today)
s = s.replace(f"# {short}\n", f"# {short}\n\nリポジトリ: `{full}`\n", 1)
io.open(dst, "w", encoding="utf-8").write(s)
PY
  echo "  dev/状況/$short.md（$r）"
done < <(split_csv "$REPOS")

# ---------------------------------------------------------------- 2. ~/.claude
say "[2/5] Claude Code: $CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/hooks"

place "$KIT/claude/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

# skill を置いて、プレースホルダと name: を埋める
install_skill() { # install_skill <kit-dir-name> <installed-name>
  local src="$1" name="$2" dst="$CLAUDE_DIR/skills/$2"
  place "$KIT/claude/skills/$src" "$dst"
  [ -f "$dst/SKILL.md" ] || return 0
  fill "$dst/SKILL.md"
  python3 - "$name" "$dst/SKILL.md" <<'PY'
import sys, io, re
name, f = sys.argv[1], sys.argv[2]
s = io.open(f, encoding="utf-8").read()
s = re.sub(r"^name: .*$", f"name: {name}", s, count=1, flags=re.M)
io.open(f, "w", encoding="utf-8").write(s)
PY
}
install_skill partner  "$PARTNER"
install_skill dev      "$DEV"
install_skill setup    setup
install_skill grilling grilling

for f in session-end-brain.sh brain-digest.js; do
  place "$KIT/claude/hooks/$f" "$CLAUDE_DIR/hooks/$f"
  chmod +x "$CLAUDE_DIR/hooks/$f" 2>/dev/null || true
done

# ---------------------------------------------------------------- 3. settings.json merge
say "[3/5] settings.json にマージ"
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

# ---------------------------------------------------------------- 4. issue ラベル
say "[4/5] issue ラベル"
LABELS="from-chat needs-triage agent-ready agent-working $DEV question"
if [ -z "$REPOS" ]; then
  echo "  --repos が無いのでスキップ"
elif ! command -v gh >/dev/null 2>&1; then
  echo "  gh が無いのでスキップ。後で各リポジトリに作る: $LABELS"
elif ! gh auth status >/dev/null 2>&1; then
  echo "  gh が未認証（gh auth login）なのでスキップ。後で各リポジトリに作る: $LABELS"
else
  while IFS= read -r r; do
    case "$r" in */*) ;; *) echo "  skip: $r は owner/repo 形式ではない"; continue ;; esac
    for l in $LABELS; do
      if gh label create "$l" -R "$r" --force >/dev/null 2>&1; then :; else echo "  warn: $r に $l を作れなかった"; fi
    done
    echo "  $r: $LABELS"
  done < <(split_csv "$REPOS")
fi

# ---------------------------------------------------------------- 5. git init
say "[5/5] git init: $BRAIN"
git -C "$BRAIN" init -q
git -C "$BRAIN" add -A
git -C "$BRAIN" commit -q -m "brain: 初期化（brain-kit、相棒=$PARTNER、開発担当=$DEV）" \
  || echo "warn: 初回コミットに失敗（git の user.name / user.email を設定してから再実行）"

cat <<MSG

完了。
  brain     : $BRAIN
  相棒      : $BRAIN/$PARTNER/00_核.md（憲法）  02_関係.md（声・持ち主）
  開発担当  : $BRAIN/dev/00_核.md（$DEV の原則）  dev/状況/（リポジトリごとの現在地）
  skills    : $CLAUDE_DIR/skills/{$PARTNER,$DEV,setup,grilling}
  hooks     : $CLAUDE_DIR/hooks/session-end-brain.sh（SessionEnd で daily/ に追記）
  設定退避  : $BACKUP（退避したものがあれば）

次にやること:
  1. cd $BRAIN && claude を起動して /setup と打つ
     → 相棒が順にインタビューして、あなたのこと・声・プロジェクト・開発担当の分担を brain に書く
  2. 終わったら /$PARTNER で相棒として灯る。開発は /$DEV
  3. Orca を使うなら ORCA.md。プラグインは README の「プラグイン」
MSG
