#!/usr/bin/env bash
# brain-kit が生成する。起動は各人格につき 1 回、確認はプロセス一覧だけ。
set -u
ids=() names=() labels=() dirs=() scripts=()
# @personas@

usage() {
  echo '使い方: start-all [--tmux|--tabs|--print] [--status] [--wait 秒] [--help]'
}
error() { printf '%s\n' "$*" >&2; exit 2; }
backend="${BRAIN_KIT_START_WITH:-auto}"
reason='環境変数で指定'
status=0
seconds=20
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tmux|--tabs|--print) backend="${1#--}"; reason='引数で指定' ;;
    --status) status=1 ;;
    --wait)
      [ "$#" -ge 2 ] || error '--wait には秒数が要る'
      shift
      case "$1" in ''|*[!0-9]*) error '--wait は 0 以上の整数にする' ;; esac
      # 算術の桁あふれと 8 進数扱いを避ける。
      [ "${#1}" -le 6 ] || error '--wait は 999999 秒まで'
      seconds=$((10#$1)) ;;
    --help) usage; exit 0 ;;
    *) usage >&2; error "知らない引数: $1" ;;
  esac
  shift
done
case "$backend" in auto|tmux|tabs|print) ;; *) error 'BRAIN_KIT_START_WITH は tmux / tabs / print にする' ;; esac

refresh() { procs="$(ps -Ao pid=,args=)" || error 'プロセス一覧を読めない'; }
running() {
  printf '%s\n' "$procs" | awk -v wanted="/$1" '
    { $1=""; if (index($0, "claude") && $NF == wanted) found=1 }
    END { exit !found }'
}
prior=()
for ((i=0; i<${#ids[@]}; i++)); do prior[i]=0; done
table() {
  local i state missing=0
  printf '\n名前\t/id\t状態\n'
  for ((i=0; i<${#ids[@]}; i++)); do
    state='まだ見えない'
    if running "${ids[i]}"; then
      if [ "${prior[i]}" = 1 ] || [ "$status" = 1 ]; then state='すでに動いていた'; else state='起動した'; fi
    else missing=1
    fi
    printf '%s（%s）\t/%s\t%s\n' "${names[i]}" "${labels[i]}" "${ids[i]}" "$state"
  done
  if [ "$missing" = 1 ]; then
    echo 'まだ見えない人格のために start-all をもう一度実行しない。'
    echo 'そのタブ／ウィンドウを見て、start-all --status で確かめる。'
  fi
  return "$missing"
}
if [ "$status" = 1 ]; then
  echo '確認: プロセス一覧だけ（起動しない）'
  refresh
  table
  exit $?
fi

terminal=''
detect_tabs() {
  local candidate
  if [ "$(uname -s)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
    terminal=Terminal
    [ "${TERM_PROGRAM:-}" != iTerm.app ] || terminal=iTerm2
  elif [ "$(uname -s)" = Linux ]; then
    if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v wt.exe >/dev/null 2>&1; then terminal=wt.exe
    elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      for candidate in gnome-terminal konsole xfce4-terminal; do
        if command -v "$candidate" >/dev/null 2>&1; then terminal="$candidate"; break; fi
      done
    fi
  fi
  [ -n "$terminal" ]
}
if [ "$backend" = auto ]; then
  if [ -n "${TMUX:-}" ]; then backend=tmux; reason='tmux の中'
  elif command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
    backend=tmux; reason='tmux のセッションがある'
  elif detect_tabs; then backend='tabs'; reason="端末が使える: $terminal"
  elif command -v tmux >/dev/null 2>&1; then backend=tmux; reason='tmux のセッションを新しく作る'
  else backend=print; reason='使える端末が見つからない'
  fi
fi
if [ "$backend" = tmux ]; then
  command -v tmux >/dev/null 2>&1 || error 'tmux が無い。--tabs または --print を使う'
elif [ "$backend" = tabs ]; then
  detect_tabs || error '使える端末が無い。--tmux または --print を使う'
fi
printf '起動方法: %s（%s）\n' "$backend" "$reason"
[ "$terminal" != Terminal ] || echo 'Terminal.app では人格ごとに新しいウィンドウを開く。'
session="${BRAIN_KIT_TMUX_SESSION:-brain-kit}"
# shell と AppleScript の引用は別々に行う。
# 置き換え先は変数に入れる（bash 3.2 は置き換え先に書いた引用符を正しく扱えない）。
quote() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
apple_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}
launch() {
  local id="$1" dir="$2" script="$3" cmd escaped
  cmd="cd $(quote "$dir") && exec $(quote "$script")"
  case "$backend" in
    tmux)
      if tmux has-session -t "$session" >/dev/null 2>&1; then
        tmux new-window -d -t "$session:" -n "$id" -c "$dir" "$cmd"
      else tmux new-session -d -s "$session" -n "$id" -c "$dir" "$cmd"
      fi ;;
    tabs)
      case "$terminal" in
        Terminal)
          escaped="$(apple_quote "$cmd")"
          osascript -e "tell application \"Terminal\" to do script \"$escaped\"" ;;
        iTerm2)
          escaped="$(apple_quote "$cmd")"
          osascript -e "tell application \"iTerm2\"
if (count of windows) = 0 then
  create window with default profile
else
  tell current window to create tab with default profile
end if
tell current session of current window to write text \"$escaped\"
end tell" ;;
        wt.exe) wt.exe -w 0 new-tab wsl.exe -d "$WSL_DISTRO_NAME" -- bash -lc "$cmd" ;;
        gnome-terminal) gnome-terminal --tab -- bash -lc "$cmd" ;;
        konsole) konsole --new-tab -e bash -lc "$cmd" ;;
        xfce4-terminal) xfce4-terminal --tab -x bash -lc "$cmd" ;;
      esac ;;
  esac
}
trusted() {
  python3 - "$1" <<'PY'
import json, os, sys
try:
    path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.environ["HOME"], ".claude.json")
    with open(path, encoding="utf-8") as f:
        accepted = json.load(f)["projects"][sys.argv[1]]["hasTrustDialogAccepted"] is True
except (OSError, ValueError, KeyError, TypeError):
    accepted = False
sys.exit(0 if accepted else 1)
PY
}
noted=()
trust_note() {
  local dir="$1" id="$2" seen place
  for seen in ${noted[@]+"${noted[@]}"}; do [ "$seen" != "$dir" ] || return 0; done
  noted+=("$dir")
  trusted "$dir" && return 0
  place="start-$id のタブ／ウィンドウ"
  [ "$backend" != tmux ] || place="tmux ウィンドウ $id"
  printf '%s: 初回のフォルダ確認（%s）。\n' "$place" "$dir"
  echo '「Do you trust the files in this folder?（このフォルダを信頼しますか）」'
  echo '最初の選択肢「Yes, proceed / Yes, I trust this folder」で Enter。'
  echo '同じフォルダでは 1 回だけ。'
}
refresh
for ((i=0; i<${#ids[@]}; i++)); do
  if running "${ids[i]}"; then
    prior[i]=1
    printf '%s: すでに動いていた。もう一度起動しない。\n' "${names[i]}"
  elif [ "$backend" = print ]; then
    printf '新しい端末タブを開いて実行: %s\n' "$(quote "${scripts[i]}")"
  else
    trust_note "${dirs[i]}" "${ids[i]}"
    launch "${ids[i]}" "${dirs[i]}" "${scripts[i]}" || printf '%s: 起動を頼めなかった。再試行せず一覧で確かめる。\n' "${names[i]}" >&2
  fi
done
if [ "$backend" = print ]; then echo 'その後の確認: start-all --status'; exit 0; fi
if [ "$backend" = tmux ]; then
  if [ -n "${TMUX:-}" ]; then printf '見る: tmux switch-client -t %q\n' "$session"
  else printf '見る: tmux attach -t %q\n' "$session"
  fi
  echo '移動: Ctrl-b のあとウィンドウ番号、または Ctrl-b w。'
fi
for ((elapsed=0; ; elapsed++)); do
  refresh
  missing=0
  for ((i=0; i<${#ids[@]}; i++)); do
    running "${ids[i]}" || missing=1
  done
  if [ "$missing" = 0 ] || [ "$elapsed" -ge "$seconds" ]; then break; fi
  sleep 1
done
if [ "$backend" = tmux ]; then
  for ((i=0; i<${#ids[@]}; i++)); do
    [ "${prior[i]}" = 0 ] || continue
    if tmux capture-pane -p -t "$session:${ids[i]}" 2>/dev/null | grep -qi trust; then
      printf 'ウィンドウ %s はフォルダ確認で待っている。\n' "${ids[i]}"
      printf '接続してウィンドウ %s に移り、Yes で Enter。\n' "${ids[i]}"
    fi
  done
fi
table
