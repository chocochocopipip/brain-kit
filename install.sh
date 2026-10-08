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
#   ./install.sh --practice           初日の練習（任意・ローカルのみ。本物のプロジェクトには触らない）
#   ./install.sh --practice-status    練習の段と工程表を見る
#   ./install.sh --practice-cleanup [--dry-run] [--yes]  練習だけを消す（--dry-run は消す場所だけ出す）
#   --practice-dir <dir>              練習の場所（既定 ~/brain-kit-practice）
#   ./install.sh --doctor             何も変えず、版・人格・古いもの・手で直したもの・CLI・Orca・gh を表で出す
#
#   --lang ja|en : 持ち主の言語。新規は最初に聞く。--update --lang で変更できる。
#   --release-permissions / --no-release-permissions : リリース担当だけに許可の一覧を入れる／外す（既定は入れない。更新でも使える）
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
ACTION=install; MODE=""; CODEX=""; YES=0; TARGET=""; OWNER_LANG=""; HELP=0
LOCALE_LANG="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
case "$LOCALE_LANG" in ja*) DEFAULT_LANG=ja ;; *) DEFAULT_LANG=en ;; esac
# Help and parse errors honor --lang regardless of argument order.
prev=""
for arg; do
  if [ "$prev" = --lang ]; then OWNER_LANG="$arg"; fi
  prev="$arg"
done
msg() { if [ "${OWNER_LANG:-$DEFAULT_LANG}" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
value_required() { msg "error: $1 に値が要る" "error: $1 requires a value" >&2; exit 2; }
PYARGS=()
PRACTICE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --practice) ACTION=practice; shift ;;
    --practice-cleanup) ACTION=practice-cleanup; shift ;;
    --practice-status) ACTION=practice-status; shift ;;
    --practice-dir|--brain)
      [ $# -ge 2 ] || value_required "$1"
      if [ "$1" = --brain ]; then
        PYARGS+=(--brain "$2"); PRACTICE_ARGS+=(--brain "$2")
      else
        PRACTICE_ARGS+=(--dir "$2")
      fi
      shift 2 ;;
    --uninstall) ACTION=uninstall; shift ;;
    --update)   ACTION=update; shift ;;
    --resolve)  ACTION=resolve; shift ;;
    --rollback) ACTION=rollback; shift ;;
    --doctor)   ACTION=doctor; shift ;;
    --lang)     [ $# -ge 2 ] || value_required "$1"; OWNER_LANG="$2"; shift 2 ;;
    --mode)     [ $# -ge 2 ] || value_required "$1"; MODE="$2"; shift 2 ;;
    --codex)    CODEX=yes; PYARGS+=(--codex); shift ;;
    --no-codex) CODEX=no; shift ;;
    --yes|-y)   YES=1; PYARGS+=(--yes); PRACTICE_ARGS+=(--yes); shift ;;
    --partner|--dev|--review|--release|--partner-id|--dev-id|--review-id|--release-id|--user|--projects|--repos|--edited|--from|--stall-hours)
      [ $# -ge 2 ] || value_required "$1"
      PYARGS+=("$1" "$2"); shift 2 ;;
    --dry-run)  PYARGS+=(--dry-run); PRACTICE_ARGS+=(--dry-run); shift ;;
    --release-permissions|--no-release-permissions|--brain-merge|--no-worktrees|--diff|--keep)
      PYARGS+=("$1"); shift ;;
    -h|--help) HELP=1; shift ;;
    -*) msg "使えない引数: $1" "Unknown argument: $1" >&2; exit 2 ;;
    *)
      if [ "$ACTION" != resolve ] || [ -n "$TARGET" ]; then
        msg "使えない引数: $1" "Unknown argument: $1" >&2; exit 2
      fi
      TARGET="$1"; PYARGS+=(--target "$1"); shift ;;
  esac
done
case "$OWNER_LANG" in ''|ja|en) ;; *) msg 'error: --lang は ja か en' 'error: --lang must be ja or en' >&2; exit 2 ;; esac
if [ "$HELP" = 1 ]; then
  if [ "${OWNER_LANG:-$DEFAULT_LANG}" = en ]; then
    cat <<'HELP'
brain-kit installer
Usage: ./install.sh [--lang ja|en] [--mode local|base] [--yes]
  --partner NAME --dev NAME --review NAME --release NAME
  --partner-id ID --dev-id ID --review-id ID --release-id ID
  --user NAME --projects a,b --repos owner/repo,...
  --brain DIR --brain-merge --codex --no-codex --no-worktrees
  --update [--lang ja|en] [--dry-run] [--diff] [--edited new|keep]
  --resolve FILE [--from FILE | --keep] [--dry-run]
  --uninstall [--dry-run] [--yes]
  --rollback [--dry-run] | --doctor | --version
  --practice | --practice-status | --practice-cleanup [--dry-run] [--yes]
  --practice-dir DIR (default ~/brain-kit-practice; first-day practice, local only)
  --release-permissions | --no-release-permissions (permission list for the release persona only; off by default)
Language is asked first on interactive installs. Without --lang, non-interactive installs
use the language recorded on this machine, else Japanese. Existing installs keep their record.
Use --update --dry-run --lang en to preview a language change.
Owner notes are not translated. File and folder names stay unchanged.
HELP
  else
    sed -n '2,41p' "$0"
  fi
  exit 0
fi

say() { printf '\033[1m%s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { msg "error: $1 が要る" "error: $1 is required" >&2; exit 1; }; }
interactive() { [ "$YES" != 1 ] && { [ "${BRAIN_KIT_INTERACTIVE:-}" = 1 ] || [ -t 0 ]; }; }
confirm() {
  [ "$YES" = 1 ] && return 0
  interactive || return 1
  printf '%s [y/N] ' "$1"
  read -r a || a=""
  [[ "${a:-}" =~ ^[yY] ]]
}
# 空の配列を bash 3.2 の set -u で展開すると落ちるので、この形で渡す
kit() { python3 "$KIT/lib/kit.py" "$@" ${PYARGS[@]+"${PYARGS[@]}"}; }

practice() { python3 "$KIT/lib/practice.py" "$@" ${PRACTICE_ARGS[@]+"${PRACTICE_ARGS[@]}"}; }

if [ "$ACTION" = install ] && [ -z "$OWNER_LANG" ]; then
  if interactive; then
    for _ in 1 2; do
      printf 'Language / 言語 — en = English, ja = 日本語 [%s]: ' "$DEFAULT_LANG"
      read -r answer || answer=""
      answer="$(printf '%s' "${answer:-$DEFAULT_LANG}" | tr '[:upper:]' '[:lower:]')"
      case "$answer" in
        en|english|e|1) OWNER_LANG=en; break ;;
        ja|japanese|日本語|j|2) OWNER_LANG=ja; break ;;
      esac
    done
    if [ -z "$OWNER_LANG" ]; then
      printf '%s\n' 'Invalid language / 言語を選べない: en / ja' >&2
      exit 2
    fi
  else
    # 聞けないときは、この機の記録（前に選んだ言語）、無ければ日本語
    OWNER_LANG="$(python3 -c '
import json, sys
try:
    lang = json.load(open(sys.argv[1], encoding="utf-8")).get("lang")
except Exception:
    lang = None
print(lang if lang in ("ja", "en") else "ja")
' "$HOME/.claude/brain-kit/manifest.json" 2>/dev/null)" || OWNER_LANG=ja
    case "$OWNER_LANG" in ja|en) ;; *) OWNER_LANG=ja ;; esac
  fi
fi
[ -z "$OWNER_LANG" ] || PYARGS+=(--lang "$OWNER_LANG")
need python3
case "$ACTION" in
  practice) need git; practice start; exit $? ;;
  practice-status) need git; practice status; exit $? ;;
  practice-cleanup) need git; practice cleanup; exit $? ;;
  doctor) kit doctor; exit $? ;;
  uninstall) kit uninstall; exit $? ;;
  rollback) kit rollback; exit $? ;;
  update) need git; kit update; exit $? ;;
  resolve) need git; kit resolve; exit $? ;;
esac

need git
command -v node >/dev/null 2>&1 || msg 'warn: node が無い。SessionEnd フック（brain-digest.js）が動かない' 'warn: node is missing. The SessionEnd hook (brain-digest.js) will not work'
command -v claude >/dev/null 2>&1 || msg 'warn: claude CLI が無い。フックの自動要約は生の依頼一覧にフォールバックする' 'warn: claude CLI is missing. Hook summaries will fall back to the raw request list'

say "$(msg '[0/6] どこで動かすか' '[0/6] Choose where to run')"
if [ -z "$MODE" ]; then
  if interactive; then
    printf '%s' "$(msg 'どこで動かす？ local=この機だけ / base=この機を母艦にして外から繋ぐ [local]: ' 'Where to run? local=this machine / base=host here and connect remotely [local]: ')"
    read -r MODE || MODE=""
  fi
  MODE="${MODE:-local}"
fi
case "$MODE" in local|base) ;; *) msg 'error: --mode は local か base' 'error: --mode must be local or base' >&2; exit 2 ;; esac
if [ "$MODE" = base ]; then
  machine="$(hostname 2>/dev/null || echo '?')"
  msg "  base: この機（${machine}）を母艦にする。brain も Claude Code もここに置く。" "  base: use this machine ($machine) as the host for brain and Claude Code."
  msg '        手元の PC からではなく、母艦の上（SSH か WSL のターミナル）で実行していること。' '        Run on the host (SSH or WSL terminal), not on your local PC.'
  confirm "$(msg '  いま母艦の上にいる？' '  Are you on the host now?')" || { msg '  母艦に入ってから実行する。手元の PC なら --mode local' '  Run on the host. For your local PC, use --mode local'; exit 1; }
fi
if [ -z "$CODEX" ]; then
  if interactive; then
    printf '%s' "$(msg 'ChatGPT／Codex の契約がある？ 連携する？ (yes/no) [no]: ' 'Have a ChatGPT/Codex subscription? Enable integration? (yes/no) [no]: ')"
    read -r CODEX || CODEX=""
  fi
  case "${CODEX:-no}" in y|Y|yes|YES) CODEX=yes; PYARGS+=(--codex) ;; *) CODEX=no ;; esac
fi

kit install

# ---------------------------------------------------------------- Codex（任意）
if [ "$CODEX" = yes ]; then
  say "$(msg '[Codex] 連携' '[Codex] Integration')"
  if command -v codex >/dev/null 2>&1; then
    installed="$(codex --version 2>/dev/null | head -1)"
    msg "  済み: codex $installed" "  Installed: codex $installed"
  else
    CODEX_PKG="@openai/codex"
    msg '  codex CLI が無い。npm で入れる:' '  codex CLI is missing. Install with npm:'
    echo "  \$ npm i -g $CODEX_PKG"
    if command -v npm >/dev/null 2>&1; then
      if confirm "$(msg '  実行する？' '  Proceed?')"; then
        npm i -g "$CODEX_PKG" || msg '  warn: npm i -g に失敗。手で入れる' '  warn: npm i -g failed. Install manually'
      else
        msg "  skip（あとで: npm i -g ${CODEX_PKG}）" "  skip (later: npm i -g ${CODEX_PKG})"
      fi
    else
      msg "  npm が無い。node/npm を入れてから: npm i -g $CODEX_PKG" "  npm is missing. Install node/npm, then: npm i -g $CODEX_PKG"
    fi
  fi
  msg '  ログインは手で（ブラウザ認証）: codex login' '  Log in manually (browser authentication): codex login'
  msg '  claude を起動して /plugin で codex が有効になっているか見る（marketplace の取得に少し時間がかかる）' '  Start claude and check /plugin for codex (fetching the marketplace may take a moment)'
fi

# ---------------------------------------------------------------- 初日の練習（任意）
if [ -t 0 ] && [ "$YES" != 1 ]; then
  if confirm "$(msg '初日の練習をする？ 捨ててよいローカルのリポジトリで issue を 1 つ 4 人に通して見せる（GitHub にも本物のプロジェクトにも触らない。あとで --practice-cleanup で消せる）' 'Try the first-day practice? One issue goes through all 4 personas in a throwaway local repository (touches neither GitHub nor real projects; remove later with --practice-cleanup)')"; then
    practice start || msg '練習は中断した。あとで --practice で再開できる' 'Practice stopped. Resume later with --practice'
  fi
else
  msg '初日の練習（任意）: ./install.sh --practice（あとで --practice-cleanup で消す）' 'First-day practice (optional): ./install.sh --practice (remove later with --practice-cleanup)'
fi

# ---------------------------------------------------------------- base
if [ "$MODE" = base ]; then
  say "$(msg '[base] この機を母艦にする' '[base] Set up this machine as the host')"
  if [ ! -x "$KIT/setup-base.sh" ]; then
    msg '  setup-base.sh が見つからない。base 機でこのリポジトリを clone して ./setup-base.sh を実行する' '  setup-base.sh is missing. Clone this repository on the host and run ./setup-base.sh'
  elif [ "$YES" = 1 ]; then
    exec "$KIT/setup-base.sh" --yes
  elif confirm "$(msg '  続けて ./setup-base.sh を実行する？（sudo / apt / ネット取得あり）' '  Continue with ./setup-base.sh? (uses sudo / apt / network downloads)')"; then
    exec "$KIT/setup-base.sh"
  else
    msg "  あとで: cd $KIT && ./setup-base.sh   （--dry-run で中身だけ見られる）" "  Later: cd $KIT && ./setup-base.sh   (preview with --dry-run)"
  fi
fi
