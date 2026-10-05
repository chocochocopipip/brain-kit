#!/usr/bin/env bash
# 見回りの前確認（Orca の automation の --precheck に渡す）。仕事があるときだけ 0 を返す。
#   precheck.sh <label> [open の PR も見るなら pr]
#   例: precheck.sh <レビューラベル> pr     … レビュー待ちの PR が 1 本でもあれば 0
#       precheck.sh <開発ラベル>            … 開発に渡された issue が 1 本でもあれば 0
# リポジトリは brain の .brain-kit/config.json から読む。gh で読むだけ。bash 3.2 で動く。
set -u
label="${1:?label が要る}"
kind="${2:-issue}"
cfg="<brain>/.brain-kit/config.json"
cfg="${cfg/#\~/$HOME}"
repos="$(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1])).get("repos",[])))' "$cfg" 2>/dev/null)" || exit 1
[ -n "$repos" ] || exit 1
for r in $repos; do
  if [ "$kind" = pr ]; then
    n="$(gh pr list -R "$r" --label "$label" --state open --json number --jq 'length' 2>/dev/null || echo 0)"
  else
    n="$(gh issue list -R "$r" --label "$label" --state open --json number --jq 'length' 2>/dev/null || echo 0)"
  fi
  [ "${n:-0}" -gt 0 ] 2>/dev/null && exit 0
done
exit 1
