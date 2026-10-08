#!/usr/bin/env bash
# 渡す前の漏れチェック。固有名詞はこのリポジトリに書かない（書いた瞬間にそれ自体が漏れになる）。
#   ./check.sh <ユーザー名> <プロジェクト名> <相棒名> ...     引数の語を探す
#   BRAIN_KIT_CHECK_WORDS_FILE=<file> ./check.sh              ファイルの語（1 行 1 語、# はコメント）も探す
#                                                              既定 ~/.config/brain-kit/check-words.txt（在れば）
#   CI は secret BRAIN_KIT_CHECK_WORDS（1 行 1 語）をファイルにして渡す（.github/workflows/check.yml）
# .git/ は対象外。終了コードは 0 = 漏れなし、1 = 何か見つかった。
# macOS の grep（BSD）や BusyBox でも動くように、find で集めて grep -n -i -E/-F だけを使う。grep が失敗したら 2 で止まる。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# 記号や単語を直書きすると自分にヒットするので、組み立てる
at="$(printf '\100')"
w1="tok"; w2="en"; w3="sec"; w4="ret"; w5="pass"; w6="word"; w7="api"; w8="key"
BUILTIN=(
  "[[:alnum:]._%+-]+${at}[[:alnum:].-]+\.[a-z]{2,}"      # メールらしきもの
  "BEGIN [A-Z ]*PRIVATE KEY"                             # 秘密鍵
  "${w1}${w2}|${w3}${w4}|${w5}${w6}|${w7}[_-]?${w8}"     # 認証情報らしき英単語
  "/home/[A-Za-z0-9_-]+|/Users/[A-Za-z0-9_-]+"           # ホームの絶対パス（Linux・macOS）
  "(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.]|$)"    # IP アドレス
)
# 例として書いてよいもの（テストの一時アドレス、plugin キー、漏れチェック自身の語の入れ物の名前）
ALLOW="example\.invalid|BRAIN_KIT_CHECK_WORDS|${at}claude-plugins-official|${at}openai-codex"

found=0
report() { # report <label> <grep の出力>
  if [ -n "$2" ]; then
    found=1
    printf '\n[%s]\n%s\n' "$1" "$2"
  fi
}
# 配布する版の記録は 3 か所で揃える。作業中の節は版の見出しに数えない。
kit_version="$(tr -d '[:space:]' 2>/dev/null < VERSION)"
package_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json 2>/dev/null | sed -n '1p')"
changelog_heading="$(grep '^## v[0-9]' CHANGELOG.md 2>/dev/null | sed -n '1p')"
changelog_version="$(printf '%s\n' "$changelog_heading" | sed -n 's/^## v\([0-9][0-9.]*\)\([[:space:]].*\)\{0,1\}$/\1/p')"
valid_kit=0
if printf '%s\n' "$kit_version" | grep -qE '^[1-9][0-9]*$'; then
  valid_kit=1
else
  report version "VERSION が無いか正の整数ではない: ${kit_version:-（空）}"
fi
if ! printf '%s\n' "$package_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  report version "package.json の version が無いか X.Y.Z ではない: ${package_version:-（空）}"
elif [ "$valid_kit" = 1 ] && [ "${package_version%%.*}" != "$kit_version" ]; then
  report version "package.json の版 $package_version の major が VERSION $kit_version と違う"
fi
if ! printf '%s\n' "$changelog_version" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
  report version "CHANGELOG.md の先頭の版見出しが無いか読めない: ${changelog_heading:-（空）}"
elif [ "$valid_kit" = 1 ] && [ "${changelog_version%%.*}" != "$kit_version" ]; then
  report version "CHANGELOG.md の先頭の版 v$changelog_version の major が VERSION $kit_version と違う"
fi

# 対象のファイル（.git と check.sh を除く）。grep の --exclude-dir は BusyBox に無いので find で集める
FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find . -path ./.git -prune -o -type f ! -name check.sh -print0)
g() { # g <-E|-F> <pattern> : 一致した行。grep が壊れていたら（終了コード 2 以上）止める
  local out rc
  out="$(grep -ni "$1" -- "$2" /dev/null ${FILES[@]+"${FILES[@]}"})"; rc=$?
  if [ "$rc" -ge 2 ]; then echo "error: grep が失敗した（${rc}）。この grep では確かめられない" >&2; exit 2; fi
  printf '%s' "$out"
}
runE() { report "$1" "$(g -E "$2" | grep -viE -- "$ALLOW")"; }
# 語の一致は「ファイル:行」だけ出す（CI のログに語そのものを残さない）
runF() { report "$1" "$(g -F "$2" | cut -d: -f1,2)"; }

for ((i = 0; i < ${#BUILTIN[*]}; i++)); do runE "builtin" "${BUILTIN[i]}"; done
nwords=0
for word; do runF "word: (引数 $((nwords + 1)))" "$word"; nwords=$((nwords + 1)); done   # for word; は位置引数を順に回す

WORDS_FILE="${BRAIN_KIT_CHECK_WORDS_FILE:-$HOME/.config/brain-kit/check-words.txt}"
nfile=0
if [ -f "$WORDS_FILE" ]; then
  while IFS= read -r word || [ -n "$word" ]; do
    word="${word%$'\r'}"
    case "$word" in ""|\#*) continue ;; esac
    nfile=$((nfile + 1))
    runF "word: (ファイルの $nfile 語目)" "$word"   # 語そのものはログに出さない（CI のログも公開される）
  done <"$WORDS_FILE"
fi

if [ "$found" = 0 ]; then
  echo "ok: 版 VERSION=$kit_version / package.json=$package_version / CHANGELOG=v$changelog_version"
  echo "ok: 0 件（引数 $nwords 語 + ファイル $nfile 語 + 組み込みパターン ${#BUILTIN[*]}）"
  exit 0
fi
echo; echo "NG: 上のものを消してから渡す"
exit 1
