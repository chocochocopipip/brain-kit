#!/usr/bin/env bash
# brain-kit installer（対話式。引数で与えた項目は聞かない。--yes で全部既定）
#
# 新しく入れる:
#   ./install.sh [--mode local|base] [--partner <名前>] [--dev <名前>] [--review <名前>] [--release <名前>]
#                [--partner-id <英字>] [--dev-id <英字>] [--review-id <英字>] [--release-id <英字>]
#                [--user <持ち主の呼び名>] [--projects "a,b"] [--repos "owner/repo,..."]
#                [--brain <dir>] [--brain-merge] [--codex] [--no-worktrees] [--yes]
#
# 更新する（すでに使っている人。v1〜v9 の版の記録が無い入れ方も、ファイルの形から見分ける）:
#   ./install.sh --update --dry-run   足すもの・上げるもの・触らないもの・手で直したもの、と差分を出す。何も変えない
#   ./install.sh --update             kit のもの（skill・規約・台本・フック）だけを上げる。持ち主のものには触らない
#                                     相棒と開発の名前は引き継ぐ。新しく足すレビューとリリースだけ名前を聞く
#                                     （--review <名前> --release <名前> でも渡せる）
#                                     両方が変わったファイルは残し、.new と衝突資料を置く。
#                                     kit 版に置き換えるなら --edited new（退避あり）
#                                     持ち主の道具の名前と重なりも資料に出す（中身は読まない）
#   ./install.sh --resolve <file> [--from <merged file>]   解消結果を記録する。省略時は今の内容
#   ./install.sh --resolve --keep <file>                 今の内容を保って解消する
#                                     settings.json も指定できる。--dry-run で書く前に確認する
#   ./install.sh --uninstall [--dry-run] [--yes]  ~/.claude の kit だけを外す。brain は触らない
#   ./install.sh --rollback           直前の resolve・更新・install を退避から戻す。--dry-run で中身だけ
#   ./install.sh --version            brain-kit の版だけを表示する
#   ./install.sh --doctor             何も変えず、版・人格・古いもの・手で直したもの・CLI・Orca・gh を表で出す
#
#   --codex : ChatGPT／Codex の契約がある人向け。Codex CLI が無ければ npm i -g @openai/codex（確認してから）、
#             codex login は案内のみ、settings.json に Codex plugin の marketplace と plugin キーを足す
#   --brain-merge : ~/brain が既にあるとき（brain-kit ではない自前の vault）、無いものだけを足す。
#                   同名の kit の .md があれば <名前>.brain-kit.md として横に置く
#   --mode local : この機で Claude Code + brain を動かす（既定）
#   --mode base  : この機を常時稼働の母艦にする。最後に ./setup-base.sh を続けて実行する
#
# 名前は 4 人とも作るときに決める（相棒・開発・レビュー・リリース）。日本語でよい。
# 英字でない名前は、skill 名・ブランチ・ラベル・起動スクリプトに使う英字 id を別に聞く。
# ユーザー名やパスは決め打ちしない。すべて $HOME 起点。本体は lib/kit.py（Python 3.8 以上、標準ライブラリだけ）。
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ほかの引数より優先し、python3 / git が無くても版を読める。
for arg; do
  if [ "$arg" = --version ]; then
    printf 'brain-kit v%s\n' "$(tr -d '[:space:]' <"$KIT/VERSION")"
    exit 0
  fi
done
ACTION=install; MODE=""; CODEX=""; YES=0; TARGET=""
PYARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION=uninstall; shift ;;
    --update)   ACTION=update; shift ;;
    --resolve)  ACTION=resolve; shift ;;
    --rollback) ACTION=rollback; shift ;;
    --doctor)   ACTION=doctor; shift ;;
    --mode)     [ $# -ge 2 ] || { echo "error: --mode に値が要る" >&2; exit 2; }; MODE="$2"; shift 2 ;;
    --codex)    CODEX=yes; PYARGS+=(--codex); shift ;;
    --no-codex) CODEX=no; shift ;;
    --yes|-y)   YES=1; PYARGS+=(--yes); shift ;;
    --partner|--dev|--review|--release|--partner-id|--dev-id|--review-id|--release-id|--user|--projects|--repos|--brain|--edited|--from)
      [ $# -ge 2 ] || { echo "error: $1 に値が要る" >&2; exit 2; }
      PYARGS+=("$1" "$2"); shift 2 ;;
    --brain-merge|--no-worktrees|--dry-run|--diff|--keep)
      PYARGS+=("$1"); shift ;;
    -h|--help)  sed -n '2,35p' "$0"; exit 0 ;;
    -*) echo "使えない引数: $1" >&2; exit 2 ;;
    *)
      if [ "$ACTION" != resolve ] || [ -n "$TARGET" ]; then
        echo "使えない引数: $1" >&2; exit 2
      fi
      TARGET="$1"; PYARGS+=(--target "$1"); shift ;;
  esac
done

say()     { printf '\033[1m%s\033[0m\n' "$*"; }
need()    { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 が要る" >&2; exit 1; }; }
confirm() { [ "$YES" = 1 ] && return 0; [ -t 0 ] || return 1; read -r -p "$1 [y/N] " a; [[ "${a:-}" =~ ^[yY] ]]; }
# 空の配列を bash 3.2 の set -u で展開すると落ちるので、この形で渡す
kit() { python3 "$KIT/lib/kit.py" "$@" ${PYARGS[@]+"${PYARGS[@]}"}; }

need python3
case "$ACTION" in
  doctor)   kit doctor; exit $? ;;
  uninstall) kit uninstall; exit $? ;;
  rollback) kit rollback; exit $? ;;
  update)   need git; kit update; exit $? ;;
  resolve)  need git; kit resolve; exit $? ;;
esac

need git
command -v node   >/dev/null 2>&1 || echo "warn: node が無い。SessionEnd フック（brain-digest.js）が動かない"
command -v claude >/dev/null 2>&1 || echo "warn: claude CLI が無い。フックの自動要約は生の依頼一覧にフォールバックする"

say "[0/6] どこで動かすか"
if [ -z "$MODE" ]; then
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then MODE=local; else read -r -p "どこで動かす？ local=この機だけ / base=この機を母艦にして外から繋ぐ [local]: " MODE; MODE="${MODE:-local}"; fi
fi
case "$MODE" in local|base) ;; *) echo "error: --mode は local か base" >&2; exit 2 ;; esac
if [ "$MODE" = base ]; then
  echo "  base: この機（$(hostname 2>/dev/null || echo '?')）を母艦にする。brain も Claude Code もここに置く。"
  echo "        手元の PC からではなく、母艦の上（SSH か WSL のターミナル）で実行していること。"
  confirm "  いま母艦の上にいる？" || { echo "  母艦に入ってから実行する。手元の PC なら --mode local"; exit 1; }
fi
if [ -z "$CODEX" ]; then
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then CODEX=no; else read -r -p "ChatGPT／Codex の契約がある？ 連携する？ (yes/no) [no]: " CODEX; fi
  case "${CODEX:-no}" in y|Y|yes|YES) CODEX=yes; PYARGS+=(--codex) ;; *) CODEX=no ;; esac
fi

kit install

# ---------------------------------------------------------------- Codex（任意）
if [ "$CODEX" = yes ]; then
  say "[Codex] 連携"
  if command -v codex >/dev/null 2>&1; then
    echo "  済み: codex $(codex --version 2>/dev/null | head -1)"
  else
    CODEX_PKG="@openai/codex"
    echo "  codex CLI が無い。npm で入れる:"
    echo "  \$ npm i -g $CODEX_PKG"
    if command -v npm >/dev/null 2>&1; then
      if confirm "  実行する？"; then npm i -g "$CODEX_PKG" || echo "  warn: npm i -g に失敗。手で入れる"; else echo "  skip（あとで: npm i -g ${CODEX_PKG}）"; fi
    else
      echo "  npm が無い。node/npm を入れてから: npm i -g $CODEX_PKG"
    fi
  fi
  echo "  ログインは手で（ブラウザ認証）: codex login"
  echo "  claude を起動して /plugin で codex が有効になっているか見る（marketplace の取得に少し時間がかかる）"
fi

# ---------------------------------------------------------------- base
if [ "$MODE" = base ]; then
  say "[base] この機を母艦にする"
  if [ ! -x "$KIT/setup-base.sh" ]; then
    echo "  setup-base.sh が見つからない。base 機でこのリポジトリを clone して ./setup-base.sh を実行する"
  elif [ "$YES" = 1 ]; then
    exec "$KIT/setup-base.sh" --yes
  elif confirm "  続けて ./setup-base.sh を実行する？（sudo / apt / ネット取得あり）"; then
    exec "$KIT/setup-base.sh"
  else
    echo "  あとで: cd $KIT && ./setup-base.sh   （--dry-run で中身だけ見られる）"
  fi
fi
