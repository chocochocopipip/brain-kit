#!/usr/bin/env bash
# 静的検査（shellcheck）と bash 3.2 / BSD の移植性を確かめる。
#   bash tests/lint.sh [--self-test] [--portability-only] [ファイル...]
set -uo pipefail

portability_only=0
self_test=0
FILES=()
for arg; do
  case "$arg" in
    --portability-only) portability_only=1 ;;
    --self-test) self_test=1 ;;
    *) FILES+=("$arg") ;;
  esac
done
if [ "$portability_only" = 0 ] && ! command -v shellcheck >/dev/null 2>&1; then
  echo 'error: shellcheck が要る' >&2
  exit 2
fi

# 行番号を保ったまま探す。grep の失敗は見逃さない。
rule() {
  local file="$1" label="$2" pattern="$3" out rc line body
  out="$(grep -n -E -- "$pattern" "$file")"; rc=$?
  if [ "$rc" -ge 2 ]; then
    echo 'error: grep が失敗した' >&2
    return 2
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    body="${line#*:}"
    if printf '%s\n' "$body" | grep -q -E '^[[:space:]]*#|# lint-ok: [^[:space:]].*[[:space:]]*$'; then
      continue
    fi
    printf '%s:%s: %s\n' "$file" "${line%%:*}" "$label"
    found=1
  done <<< "$out"
}

portability() {
  local file found=0
  for file; do
    rule "$file" '連想配列' '(^|[^[:alnum:]_])(declare|local|typeset)[[:space:]]+-[[:alpha:]]*A' || return 2
    rule "$file" '配列の一括読み込み' '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)' || return 2 # lint-ok: 検出用の式
    rule "$file" '大文字・小文字の変換' '\$\{[[:alnum:]_]+(\[[^]]*\])?(,,?|\^\^?)' || return 2
    rule "$file" '追記の一括転送' '&>>' || return 2 # lint-ok: 検出用の式
    rule "$file" '標準エラーのパイプ' '\|&' || return 2 # lint-ok: 検出用の式
    rule "$file" '変数の参照名' '(^|[^[:alnum:]_])(declare|local)[[:space:]]+-[[:alpha:]]*n' || return 2
    rule "$file" '変数の変換指定' '\$\{[[:alnum:]_]+(\[[^]]*\])?@[[:alpha:]]\}' || return 2
    rule "$file" '変数の存在判定' '\[\[[[:space:]]+-v([[:space:]]|$)' || return 2
    rule "$file" '待機の先着指定' '(^|[^[:alnum:]_])wait[[:space:]]+-[[:alpha:]]*n([[:space:]]|$)' || return 2
    rule "$file" '新しい組み込み変数' '(^|[^[:alnum:]_])(EPOCHSECONDS|EPOCHREALTIME|SRANDOM)([^[:alnum:]_]|$)' || return 2 # lint-ok: 検出用の式
    rule "$file" 'リンクの絶対化' '(^|[^[:alnum:]_])readlink[[:space:]]+-[[:alpha:]]*f' || return 2
    rule "$file" 'grep の拡張形式' '(^|[^[:alnum:]_])grep[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*-[[:alpha:]]*P' || return 2
    rule "$file" 'sed の退避指定なし' "(^|[^[:alnum:]_])sed[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*-i([[:space:]]+([^[:space:]']|'[^'])|[[:space:]]*$)" || return 2
    rule "$file" 'date の日付指定' '(^|[^[:alnum:]_])date[[:space:]]+-d([[:space:]]|$)' || return 2
    rule "$file" 'stat の書式指定' '(^|[^[:alnum:]_])stat[[:space:]]+-c([[:space:]]|$)' || return 2
    rule "$file" 'xargs の空入力指定' '(^|[^[:alnum:]_])xargs[[:space:]]+-r([[:space:]]|$)' || return 2
    rule "$file" 'find の書式指定' '(^|[^[:alnum:]_])find[[:space:]].*-printf([[:space:]]|$)' || return 2
    # macOS の bash 3.2 は UTF-8 のロケールで、変数名の直後の全角文字を名前の続きと読む（unbound variable）
    LC_ALL=C rule "$file" '変数の直後の全角文字' "\\\$[A-Za-z_][A-Za-z0-9_]*"$'[\x80-\xff]' || return 2
  done
  return "$found"
}

checks() {
  local rc=0 result
  if [ "$portability_only" = 0 ]; then
    shellcheck -- "$@" || rc=1
  fi
  portability "$@"; result=$?
  [ "$result" = 0 ] || rc="$result"
  return "$rc"
}

if [ "$self_test" = 1 ]; then
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/brain-kit-lint.XXXXXX")" || exit 2
  trap 'rm -rf "$TMP"' EXIT
  # 文字列のまま書き、検査先で展開させる。
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'rm $1' >"$TMP/引用.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'rm $1' \
    'declare -A values' 'mapfile values' "sed -i 's/a/b/' f" 'readlink -f f' 'echo "$1"' 'echo "（$HOME）"' >"$TMP/違反.sh" # lint-ok: 違反の見本
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1"' >"$TMP/正常.sh"
  # コメントと理由付きの除外も確かめる。
  printf '%s\n' '# mapfile values' 'true # mapfile values # lint-ok: 検査から除く見本' >>"$TMP/正常.sh" # lint-ok: 除外の見本
  checks "$TMP/違反.sh" >"$TMP/結果" 2>&1; rc=$?
  [ "$rc" = 1 ] || { echo 'NG: 違反を検出できない'; exit 1; }
  for label in '連想配列' '配列の一括読み込み' 'sed の退避指定なし' 'リンクの絶対化' '変数の直後の全角文字'; do
    grep -q -F ": $label" "$TMP/結果" || { echo "NG: $label を検出できない"; exit 1; }
  done
  if [ "$portability_only" = 0 ]; then
    checks "$TMP/引用.sh" >"$TMP/引用結果" 2>&1; rc=$?
    if [ "$rc" != 1 ] || ! grep -q -F 'SC2086' "$TMP/引用結果"; then
      echo 'NG: shellcheck の違反を検出できない'; exit 1
    fi
  fi
  checks "$TMP/正常.sh" || { echo 'NG: 正常な例が通らない'; exit 1; }
  echo 'ok: lint の自己テスト'
  exit 0
fi

if [ "${#FILES[@]}" = 0 ]; then
  # NUL 区切りで受け取り、日本語や空白のある名前も保つ。
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/brain-kit-lint.XXXXXX")" || exit 2
  trap 'rm -rf "$TMP"' EXIT
  git ls-files -z >"$TMP/一覧" || exit 2
  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    first=''
    IFS= read -r first <"$file" || true
    if printf '%s\n' "$first" | grep -q -E '^#![[:space:]]*(/[^[:space:]]*/(ba)?sh|/[^[:space:]]*/env[[:space:]]+(ba)?sh)([[:space:]]|$)'; then
      FILES+=("$file")
    fi
  done <"$TMP/一覧"
fi
[ "${#FILES[@]}" -gt 0 ] || { echo 'ok: 対象なし'; exit 0; }
checks "${FILES[@]}"
