#!/usr/bin/env bash
# 実走テスト（サンドボックス HOME）。新規・v8 → v10・v9 → v10・v10 → v10、--dry-run、手で直したファイルの 3 択、
# --rollback、--doctor を、日本語と英語の名前で通す。bash 3.2（macOS 標準）で動く書き方だけを使う。
#
#   /bin/bash tests/e2e.sh       # macOS なら標準の bash 3.2 で。git の履歴（v8・v9 のコミット）が要る。浅い clone なら git fetch --unshallow
#
# 何も外に出さない: gh は PATH から外し（ラベルは飛ばす）、HOME は一時ディレクトリ。
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V8=ed99c56
V9=bc98adc
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brain-kit-e2e.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=kit-test GIT_AUTHOR_EMAIL=kit-test@example.invalid
export GIT_COMMITTER_NAME=kit-test GIT_COMMITTER_EMAIL=kit-test@example.invalid
# gh と claude を見えなくする（ラベル作成・要約を走らせない）
SAFE_PATH="$TMP/bin"
mkdir -p "$SAFE_PATH"
ln -s "$BASH" "$SAFE_PATH/bash"    # このテストを走らせている bash（macOS なら /bin/bash の 3.2）を使う
for c in sh python3 git env mktemp cat sed grep tr cp rm mkdir ls find sort diff head tail wc chmod dirname basename date hostname uname printf test true false tar ln mv awk cut xargs touch rmdir stat id sleep readlink tee uniq less; do
  p="$(command -v "$c" 2>/dev/null || true)"
  [ -n "$p" ] && [ ! -e "$SAFE_PATH/$c" ] && ln -s "$p" "$SAFE_PATH/$c"
done
export PATH="$SAFE_PATH"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
ng()   { fail=$((fail + 1)); printf '  NG   %s\n' "$*"; }
check() { # check <説明> <コマンド...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else ng "$d"; fi
}
section() { printf '\n== %s\n' "$*"; }

# snap <home> : ~/.claude（退避を除く）と brain の作業ツリーの一覧と sha256
snap() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
home = sys.argv[1]
out = []
for top in (".claude", "brain"):
    base = os.path.join(home, top)
    for root, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d != ".git" and not d.startswith("backup-brain-kit-"))
        for f in sorted(files):
            p = os.path.join(root, f)
            if os.path.islink(p):
                continue
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()[:12]
            mode = "x" if os.access(p, os.X_OK) else "-"
            out.append("%s %s %s" % (h, mode, os.path.relpath(p, home)))
print("\n".join(out))
PY
}
# owner_snap <home> <partner> : 持ち主のもの（kit のものと .brain-kit を除く brain の全部）
owner_snap() {
  snap "$1" | grep ' brain/' | grep -v -e ' brain/\.brain-kit/' -e ' brain/CLAUDE.md$' -e ' brain/README.md$' \
    -e ' brain/dev/README.md$' -e ' brain/dev/状況/_テンプレート.md$' -e ' brain/review/README.md$' \
    -e ' brain/review/記録/README.md$' -e ' brain/review/評価/README.md$' -e ' brain/release/README.md$' \
    -e ' brain/release/記録/README.md$'
}

old_kit() { # old_kit <sha> <dir>
  mkdir -p "$2"
  git -C "$KIT" archive "$1" | tar -x -C "$2"
}
# old_install <sha> <home> <install.sh の引数...>
old_install() {
  local sha="$1" home="$2"; shift 2
  local k="$TMP/kit-$sha"
  [ -d "$k" ] || old_kit "$sha" "$k"
  mkdir -p "$home"
  HOME="$home" bash "$k/install.sh" "$@" </dev/null >"$home.old.log" 2>&1 || { echo "old install ($sha) failed:"; cat "$home.old.log"; exit 1; }
}
new() { HOME="$1" bash "$KIT/install.sh" "${@:2}"; }
commits() { git -C "$1/brain" rev-list --count HEAD; }

# ------------------------------------------------------------------ 1. 新規（英語の名前）
section "新規 v10（英語の名前）"
H="$TMP/new-en"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --repos "example/app" --projects "app" --yes </dev/null >"$H.log" 2>&1
check "install が 0 で終わる" test $? -eq 0
check "config に版 10" grep -q '"version": 10' "$H/brain/.brain-kit/config.json"
for s in aoi ren mio sora setup grilling; do check "skill $s" test -f "$H/.claude/skills/$s/SKILL.md"; done
check "skill の name: が id" grep -q '^name: mio$' "$H/.claude/skills/mio/SKILL.md"
check "相棒の領域 Aoi/" test -f "$H/brain/Aoi/00_核.md"
check "持ち主の名前が入る" grep -q '持ち主: Ken' "$H/brain/Aoi/00_核.md"
for a in dev review release; do check "領域 $a/" test -d "$H/brain/$a"; done
for w in ren mio sora; do check "worktree brain-$w" test -d "$H/brain-$w"; done
check "worktree で相棒の領域が見えない" test ! -e "$H/brain-ren/Aoi"
check "起動スクリプト" test -x "$H/.claude/brain-kit/bin/start-mio"
check "状況カード" test -f "$H/brain/dev/状況/app.md"
check "projects/app.md" test -f "$H/brain/projects/app.md"
check "brain にコミット" test "$(commits "$H")" -ge 1
check "印が残っていない（~/.claude）" sh -c "! grep -r -e '<相棒名>' -e '<開発担当名>' -e '<レビュー担当名>' -e '<リリース担当名>' -e '<相棒id>' '$H/.claude/skills'"
check "印が残っていない（brain）" sh -c "! grep -r -e '<相棒名>' -e '<開発担当名>' -e '<レビュー担当名>' -e '<リリース担当名>' '$H/brain' --include=*.md"
new "$H" --doctor >"$H.doctor" 2>&1
check "--doctor が 0" test $? -eq 0
check "--doctor に版" grep -q 'v10' "$H.doctor"
before="$(snap "$H")"; c0="$(commits "$H")"
new "$H" --update </dev/null >"$H.up" 2>&1
check "v10 → v10 が 0" test $? -eq 0
check "v10 → v10 で何も変わらない（ファイル）" test "$before" = "$(snap "$H")"
check "v10 → v10 で何も変わらない（コミット）" test "$c0" = "$(commits "$H")"
check "v10 → v10 の表示「なし」" grep -q '変わったもの: なし' "$H.up"
check "もう一度 install すると止まる" sh -c "! HOME='$H' bash '$KIT/install.sh' --yes </dev/null"

# ------------------------------------------------------------------ 2. 新規（日本語の名前、id は既定）
section "新規 v10（日本語の名前）"
H="$TMP/new-ja"
mkdir -p "$H"
new "$H" --partner 光 --dev 匠 --review 澪 --release 湊 --user けん --yes </dev/null >"$H.log" 2>&1
check "install が 0" test $? -eq 0
for s in partner dev review release; do check "日本語名 → 既定 id の skill $s" test -f "$H/.claude/skills/$s/SKILL.md"; done
check "相棒の領域 光/" test -f "$H/brain/光/00_核.md"
check "skill に表示名" grep -q '澪' "$H/.claude/skills/review/SKILL.md"
check "日本語の id は通さない" sh -c "! HOME='$TMP/x' bash '$KIT/install.sh' --partner 光 --partner-id 光 --yes </dev/null"

# ------------------------------------------------------------------ 3. v9 → v10（日本語の名前）
section "v9 → v10（日本語の名前）"
H9="$TMP/v9-ja"
old_install "$V9" "$H9" --partner 光 --dev 匠 --user けん --repos "example/app" --projects app --yes
check "v9 の install が通る" test -f "$H9/.claude/skills/光/SKILL.md"
# 持ち主が書いたもの（核・日誌・決定・プロジェクト）
printf '\n## 存在\n持ち主が書いた一行。\n' >>"$H9/brain/光/00_核.md"
mkdir -p "$H9/brain/光/10_日誌"; printf -- '---\ndate: 2026-01-02\nproject: none\ntags: [日誌]\n---\n日誌\n' >"$H9/brain/光/10_日誌/2026-01-02_a.md"
printf -- '---\ndate: 2026-01-02\nproject: app\ntags: [decision]\n---\n決定\n' >"$H9/brain/decisions/2026-01-02-x.md"
git -C "$H9/brain" add -A >/dev/null && git -C "$H9/brain" commit -qm owner >/dev/null
own0="$(owner_snap "$H9")"; all0="$(snap "$H9")"

new "$H9" --doctor >"$H9.doctor0" 2>&1
check "--doctor が v9 と判定" grep -q 'v9（版の記録なし' "$H9.doctor0"

new "$H9" --update --dry-run </dev/null >"$H9.dry" 2>&1
check "--dry-run が 0" test $? -eq 0
check "--dry-run は何も変えない" test "$all0" = "$(snap "$H9")"
check "--dry-run に「上げるもの」" grep -q '上げるもの' "$H9.dry"
check "--dry-run に「触らないもの」" grep -q '触らないもの' "$H9.dry"
check "--dry-run に差分" grep -q '^+++ 新: ' "$H9.dry"
check "--dry-run で版を判定" grep -q 'v9（版の記録なし' "$H9.dry"

cp -R "$H9" "$TMP/v9-keep" ; cp -R "$H9" "$TMP/v9-new" ; cp -R "$H9" "$TMP/v9-diff"; cp -R "$H9" "$TMP/v9-rb"

new "$H9" --update --review 澪 --review-id mio --release 湊 --release-id minato </dev/null >"$H9.up" 2>&1
check "v9 → v10 が 0" test $? -eq 0
check "持ち主のものは 1 バイトも変わらない" test "$own0" = "$(owner_snap "$H9" | grep -v -e ' brain/review/' -e ' brain/release/' -e ' brain/光/03_' -e ' brain/光/20_')"
check "相棒の skill は同じ名前のまま" test -f "$H9/.claude/skills/光/SKILL.md"
check "開発の skill は同じ名前のまま" test -f "$H9/.claude/skills/匠/SKILL.md"
check "新しい skill mio" test -f "$H9/.claude/skills/mio/SKILL.md"
check "新しい skill minato" test -f "$H9/.claude/skills/minato/SKILL.md"
check "レビューの領域を足した" test -d "$H9/brain/review"
check "版の記録を書いた" grep -q '"version": 10' "$H9/brain/.brain-kit/config.json"
check "v9 の名前を記録" grep -q '"name": "光"' "$H9/brain/.brain-kit/config.json"
check "開発ラベルは v9 の名前のまま" grep -q '"label": "匠"' "$H9/brain/.brain-kit/config.json"
check "リポジトリを状況カードから拾う" grep -q 'example/app' "$H9/brain/.brain-kit/config.json"
check "退避を作った" sh -c "ls -d '$H9'/.claude/backup-brain-kit-* >/dev/null"
check "CHANGELOG を出した" grep -q '## v10' "$H9.up"
check "新しく使えるものを出した" grep -q '新しく使えるもの' "$H9.up"
check "worktree（mio）" test -d "$H9/brain-mio"
s1="$(snap "$H9")"; c1="$(commits "$H9")"
new "$H9" --update </dev/null >"$H9.up2" 2>&1
check "2 回目の更新が 0" test $? -eq 0
check "2 回目は何も変わらない（ファイル）" test "$s1" = "$(snap "$H9")"
check "2 回目は何も変わらない（コミット）" test "$c1" = "$(commits "$H9")"
new "$H9" --doctor >"$H9.doctor1" 2>&1
check "更新後の --doctor が 0" test $? -eq 0
check "更新後の --doctor に 4 人" grep -q 'リリース 湊' "$H9.doctor1"

# ------------------------------------------------------------------ 4. 手で直した kit のファイル（3 択）
section "手で直した kit のファイル（v9 → v10）"
for v in keep new diff; do
  printf '\n## 自分で足した節\n手で直した。\n' >>"$TMP/v9-$v/.claude/skills/匠/SKILL.md"
done
edited_before="$(cat "$TMP/v9-keep/.claude/skills/匠/SKILL.md")"
# 対話なし → 今のまま、一覧を最後に出す
new "$TMP/v9-keep" --update --yes </dev/null >"$TMP/keep.log" 2>&1
check "対話なし: 0" test $? -eq 0
check "対話なし: 今のまま" test "$edited_before" = "$(cat "$TMP/v9-keep/.claude/skills/匠/SKILL.md")"
check "対話なし: 一覧を出す" grep -q '今のままにしたもの' "$TMP/keep.log"
check "対話なし: 手で直したものに挙がる" grep -q '手で直したもの' "$TMP/keep.log"
check "対話なし: ほかの kit は上がる" grep -q 'レビュー' "$TMP/v9-keep/.claude/skills/光/SKILL.md"
sk="$(snap "$TMP/v9-keep")"
new "$TMP/v9-keep" --update </dev/null >"$TMP/keep2.log" 2>&1
check "今のまま → 2 回目は聞かずに何も変えない" test "$sk" = "$(snap "$TMP/v9-keep")"
# 対話: n（新しい版にする）
printf 'n\n' | BRAIN_KIT_INTERACTIVE=1 HOME="$TMP/v9-new" bash "$KIT/install.sh" --update --review 澪 --review-id mio --release 湊 --release-id minato >"$TMP/new.log" 2>&1
check "n: 0" test $? -eq 0
check "n: 新しい版になる" sh -c "! grep -q '自分で足した節' '$TMP/v9-new/.claude/skills/匠/SKILL.md'"
check "n: 退避に手で直した版がある" sh -c "grep -rq '自分で足した節' '$TMP'/v9-new/.claude/backup-brain-kit-*/files"
# 対話: d（差分を見る）→ k（今のまま）
printf 'd\nk\n' | BRAIN_KIT_INTERACTIVE=1 HOME="$TMP/v9-diff" bash "$KIT/install.sh" --update --review 澪 --review-id mio --release 湊 --release-id minato >"$TMP/diff.log" 2>&1
check "d→k: 0" test $? -eq 0
check "d: 差分を出した" grep -q '^-手で直した。' "$TMP/diff.log"
check "d→k: 今のまま" grep -q '自分で足した節' "$TMP/v9-diff/.claude/skills/匠/SKILL.md"

# ------------------------------------------------------------------ 5. --rollback
section "--rollback（v9 → v10 → 戻す）"
H="$TMP/v9-rb"
r0="$(snap "$H")"
new "$H" --update --yes </dev/null >"$H.up" 2>&1
check "更新: 0" test $? -eq 0
u1="$(snap "$H")"
check "更新で変わった" test "$r0" != "$u1"
new "$H" --rollback --dry-run </dev/null >"$H.rbdry" 2>&1
check "--rollback --dry-run は何も変えない" test "$u1" = "$(snap "$H")"
check "--rollback --dry-run に戻すものの一覧" grep -q '戻す: ' "$H.rbdry"
new "$H" --rollback </dev/null >"$H.rb" 2>&1
check "--rollback: 0" test $? -eq 0
check "--rollback で更新前に戻る（~/.claude と brain）" test "$r0" = "$(snap "$H")"
check "--rollback で worktree を外す" test ! -e "$H/brain-review"
check "もう戻すものは無い" sh -c "! HOME='$H' bash '$KIT/install.sh' --rollback </dev/null"
new "$H" --update --yes </dev/null >"$H.up2" 2>&1
check "戻したあと、もう一度更新できる" grep -q '"version": 10' "$H/brain/.brain-kit/config.json"

# ------------------------------------------------------------------ 6. v8 → v10（英語の名前）
section "v8 → v10（英語の名前）"
H8="$TMP/v8-en"
old_install "$V8" "$H8" --partner Aoi --dev Ren --user Ken --yes
check "v8 の install が通る" test -f "$H8/.claude/skills/Aoi/SKILL.md"
o8="$(owner_snap "$H8")"
new "$H8" --doctor >"$H8.doctor0" 2>&1
check "--doctor が v8 系と判定" grep -q 'v8（版の記録なし\|v6〜v8（版の記録なし' "$H8.doctor0"
new "$H8" --update --review Mio --release Sora </dev/null >"$H8.up" 2>&1
check "v8 → v10 が 0" test $? -eq 0
check "v8: 手で直したものは無い" sh -c "! grep -q '今のままにしたもの' '$H8.up'"
check "v8: 持ち主のものは変わらない" test "$o8" = "$(owner_snap "$H8" | grep -v -e ' brain/review/' -e ' brain/release/' -e ' brain/Aoi/03_' -e ' brain/Aoi/20_')"
check "v8: skill mio" test -f "$H8/.claude/skills/mio/SKILL.md"
check "v8: 相棒の skill が上がった" grep -q 'レビュー' "$H8/.claude/skills/Aoi/SKILL.md"
s8="$(snap "$H8")"
new "$H8" --update </dev/null >/dev/null 2>&1
check "v8: 2 回目は何も変わらない" test "$s8" = "$(snap "$H8")"

# ------------------------------------------------------------------ 7. heavy-lock（任意の道具）
section "heavy-lock"
HL="$KIT/claude/brain-kit/bin/heavy-lock"
export HEAVY_LOCK_DIR="$TMP/hl" HEAVY_LOCK_NEED_GB=0 HEAVY_LOCK_FLOOR_GB=0 HEAVY_LOCK_RAMP=1 HEAVY_LOCK_SLOTS=1
check "heavy-lock が本体を走らせる" sh -c "'$BASH' '$HL' sh -c 'echo ran > \"$TMP/hl.out\"' && grep -q ran '$TMP/hl.out'"
"$BASH" "$HL" sh -c 'exit 3' 2>/dev/null; rc=$?
check "heavy-lock が本体の終了コードを返す" test "$rc" = 3
check "heavy-lock が枠を返す" test ! -d "$TMP/hl/slot-1"
check "heavy-lock が空きメモリを読める" sh -c "HEAVY_LOCK_FLOOR_GB=0 '$BASH' '$HL' true 2>&1 | grep -q '空き [0-9]'"

printf '\n%d ok, %d NG\n' "$pass" "$fail"
[ "$fail" = 0 ]
