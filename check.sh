#!/usr/bin/env bash
# 渡す前の漏れチェック。固有名詞は引数で渡す（このファイルに書かない）。
#   ./check.sh <ユーザー名> <プロジェクト名> <相棒名> ...
# .git/ は対象外。終了コードは 0 = 漏れなし、1 = 何か見つかった。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# 記号や単語を直書きすると自分にヒットするので、組み立てる
at="$(printf '\100')"
w1="tok"; w2="en"; w3="sec"; w4="ret"; w5="pass"; w6="word"; w7="api"; w8="key"
BUILTIN=(
  "[[:alnum:]._%+-]+${at}[[:alnum:].-]+\.[a-z]{2,}"      # メールらしきもの
  "BEGIN [A-Z ]*PRIVATE KEY"                             # 秘密鍵
  "${w1}${w2}|${w3}${w4}|${w5}${w6}|${w7}[_-]?${w8}"     # 認証情報らしき英単語
  "/home/[A-Za-z0-9_-]+"                                 # 絶対パス
  "\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b"                      # IP アドレス
)

found=0
run() { # run <label> <regex>
  local label="$1" re="$2" out
  out="$(grep -rniE --exclude-dir=.git --exclude=check.sh -- "$re" . || true)"
  if [ -n "$out" ]; then
    found=1
    printf '\n[%s]\n%s\n' "$label" "$out"
  fi
}

for ((i=0; i<${#BUILTIN[*]}; i++)); do run "builtin" "${BUILTIN[i]}"; done
for word; do run "word: $word" "$word"; done   # for word; は位置引数を順に回す

if [ "$found" = 0 ]; then
  echo "ok: 0 件（引数 $# 語 + 組み込みパターン）"
  exit 0
fi
echo; echo "NG: 上のものを消してから渡す"
exit 1
