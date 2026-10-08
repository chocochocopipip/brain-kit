#!/usr/bin/env bash
# 実走テスト（サンドボックス HOME）。新規・v8 → v10・v9 → v10・v10 → v10、--dry-run、base・3-way・衝突の保全、
# --rollback、--doctor を、日本語と英語の名前で通す。bash 3.2（macOS 標準）で動く書き方だけを使う。
#
#   /bin/bash tests/e2e.sh       # macOS なら標準の bash 3.2 で。git の履歴（v8・v9 のコミット）が要る。浅い clone なら git fetch --unshallow
#
# 何も外に出さない: gh は PATH から外し（ラベルは飛ばす）、HOME は一時ディレクトリ。
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KV="$(tr -d '[:space:]' <"$KIT/VERSION")"   # 今の版（VERSION）
V8=ed99c56
V9=bc98adc
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brain-kit-e2e.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=kit-test GIT_AUTHOR_EMAIL=kit-test@example.invalid
export GIT_COMMITTER_NAME=kit-test GIT_COMMITTER_EMAIL=kit-test@example.invalid
# gh と claude を見えなくする（ラベル作成・要約を走らせない）
NPM="$(command -v npm 2>/dev/null || true)"   # tarball の節だけで使う（PATH を絞る前に探す）
NODE="$(command -v node 2>/dev/null || true)"
SAFE_PATH="$TMP/bin"
mkdir -p "$SAFE_PATH"
ln -s "$BASH" "$SAFE_PATH/bash"    # このテストを走らせている bash（macOS なら /bin/bash の 3.2）を使う
for c in sh python3 git env mktemp cmp cat sed grep tr cp rm mkdir ls find sort diff head tail wc chmod dirname basename date hostname uname printf test true false tar ln mv awk cut xargs touch rmdir stat id sleep readlink tee uniq less; do
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
    -e ' brain/release/記録/README.md$' -e ' brain/review/評価/_テンプレート.md$' -e ' brain/review/規準の版/README.md$' \
    -e ' brain/review/読み直し/README.md$' -e ' brain/review/読み直し/_テンプレート.md$'
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
check "config に今の版" grep -q "\"version\": $KV" "$H/brain/.brain-kit/config.json"
check "brain に .gitignore がある（点なしの gitignore から）" test -f "$H/brain/.gitignore"
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
for f in review/規準の版/README.md review/読み直し/README.md review/読み直し/_テンプレート.md review/評価/_テンプレート.md \
  Aoi/20_振り返り.md Aoi/21_読み直しの答え.md; do check "自分を直す雛形 $f" test -f "$H/brain/$f"; done
check "読み直しの答えはレビューの worktree から見えない" test ! -e "$H/brain-mio/Aoi/21_読み直しの答え.md"
check "読み直しの使い方はレビューの worktree から見える" test -f "$H/brain-mio/review/読み直し/README.md"
check "読み直しの使い方に相棒の名前" grep -q 'Aoi/21_読み直しの答え.md' "$H/brain/review/読み直し/README.md"
check "brain にコミット" test "$(commits "$H")" -ge 1
check "印が残っていない（~/.claude）" sh -c "! grep -r -e '<相棒名>' -e '<開発担当名>' -e '<レビュー担当名>' -e '<リリース担当名>' -e '<相棒id>' '$H/.claude/skills'"
check "印が残っていない（brain）" sh -c "! grep -r -e '<相棒名>' -e '<開発担当名>' -e '<レビュー担当名>' -e '<リリース担当名>' '$H/brain' --include=*.md"
new "$H" --doctor >"$H.doctor" 2>&1
check "--doctor が 0" test $? -eq 0
check "--doctor に版" grep -q "v$KV" "$H.doctor"
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
check "持ち主のものは 1 バイトも変わらない" test "$own0" = "$(owner_snap "$H9" | grep -v -e ' brain/review/' -e ' brain/release/' -e ' brain/光/03_' -e ' brain/光/20_' -e ' brain/光/21_')"
check "相棒の skill は同じ名前のまま" test -f "$H9/.claude/skills/光/SKILL.md"
check "開発の skill は同じ名前のまま" test -f "$H9/.claude/skills/匠/SKILL.md"
check "新しい skill mio" test -f "$H9/.claude/skills/mio/SKILL.md"
check "新しい skill minato" test -f "$H9/.claude/skills/minato/SKILL.md"
check "レビューの領域を足した" test -d "$H9/brain/review"
check "版の記録を書いた" grep -q "\"version\": $KV" "$H9/brain/.brain-kit/config.json"
check "v9 の名前を記録" grep -q '"name": "光"' "$H9/brain/.brain-kit/config.json"
check "開発ラベルは v9 の名前のまま" grep -q '"label": "匠"' "$H9/brain/.brain-kit/config.json"
check "リポジトリを状況カードから拾う" grep -q 'example/app' "$H9/brain/.brain-kit/config.json"
check "退避を作った" sh -c "ls -d '$H9'/.claude/backup-brain-kit-* >/dev/null"
check "CHANGELOG を出した" grep -q '## v10' "$H9.up"
check "CHANGELOG に今の版の節" grep -q "## v$KV" "$H9.up"
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

# ------------------------------------------------------------------ 4. 手で直した kit のファイル
section "手で直した kit のファイル（v9 → v10）"
for v in keep new diff; do
  printf '\n## 自分で足した節\n手で直した。\n' >>"$TMP/v9-$v/.claude/skills/匠/SKILL.md"
done
edited_before="$(cat "$TMP/v9-keep/.claude/skills/匠/SKILL.md")"
new "$TMP/v9-keep" --update --yes </dev/null >"$TMP/keep.log" 2>&1
check "対話なし: 0" test $? -eq 0
check "対話なし: 今のまま" test "$edited_before" = "$(cat "$TMP/v9-keep/.claude/skills/匠/SKILL.md")"
check "対話なし: 衝突を出す" grep -q '両方が変えたもの' "$TMP/keep.log"
check "対話なし: .new を置く" test -f "$TMP/v9-keep/.claude/skills/匠/SKILL.md.new"
check "対話なし: bundle" sh -c "ls '$TMP/v9-keep'/.claude/brain-kit/conflicts/*/README.md"
check "対話なし: base 不明" sh -c "grep -q 'base 不明' '$TMP/v9-keep'/.claude/brain-kit/conflicts/*/README.md"
check "対話なし: ほかの kit は上がる" grep -q 'レビュー' "$TMP/v9-keep/.claude/skills/光/SKILL.md"
sk="$(snap "$TMP/v9-keep")"
mt="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$TMP/v9-keep/.claude/skills/匠/SKILL.md.new" 2>/dev/null)"
new "$TMP/v9-keep" --update </dev/null >"$TMP/keep2.log" 2>&1
check "衝突 → 2 回目は何も変えない" test "$sk" = "$(snap "$TMP/v9-keep")"
check "衝突 → .new を書き直さない" test -n "$mt"
check "衝突 → .new の更新時刻も同じ" test "$mt" = "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$TMP/v9-keep/.claude/skills/匠/SKILL.md.new" 2>/dev/null)"
new "$TMP/v9-new" --update --edited new --yes </dev/null >"$TMP/new.log" 2>&1
check "--edited new: 0" test $? -eq 0
check "--edited new: 新しい版になる" sh -c "! grep -q '自分で足した節' '$TMP/v9-new/.claude/skills/匠/SKILL.md'"
check "--edited new: 退避に手で直した版がある" sh -c "grep -rq '自分で足した節' '$TMP'/v9-new/.claude/backup-brain-kit-*/files"
printf 'n\n' | BRAIN_KIT_INTERACTIVE=1 HOME="$TMP/v9-diff" bash "$KIT/install.sh" --update --diff --review 澪 --review-id mio --release 湊 --release-id minato >"$TMP/diff.log" 2>&1
check "対話環境でも上書きしない" grep -q '自分で足した節' "$TMP/v9-diff/.claude/skills/匠/SKILL.md"
check "--diff: 差分を出した" grep -q '^-手で直した。' "$TMP/diff.log"
check "更新の 3 択は聞かない" sh -c "! grep -q '\[n\]' '$TMP/diff.log'"

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
check "戻したあと、もう一度更新できる" grep -q "\"version\": $KV" "$H/brain/.brain-kit/config.json"

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
check "v8: 持ち主のものは変わらない" test "$o8" = "$(owner_snap "$H8" | grep -v -e ' brain/review/' -e ' brain/release/' -e ' brain/Aoi/03_' -e ' brain/Aoi/20_' -e ' brain/Aoi/21_')"
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

# ------------------------------------------------------------------ 8. 3-way（次の版）
section "3-way（次の版）"
NEXT="$TMP/kit-next"
mkdir -p "$NEXT"
while IFS= read -r -d '' f; do
  mkdir -p "$NEXT/$(dirname "$f")"
  cp "$KIT/$f" "$NEXT/$f"
done < <(git -C "$KIT" ls-files --cached --others --exclude-standard -z)
python3 - "$NEXT" <<'PYNEXT'
import os, sys
k = sys.argv[1]
for role in ("partner", "dev"):
    with open(os.path.join(k, "claude/skills", role, "SKILL.md"), "a") as f:
        f.write("\n次の版の末尾。\n")
p = os.path.join(k, "claude/skills/review/SKILL.md")
s = open(p).read()
s = s.replace("---", "---\n次の版の行。", 1)
open(p, "w").write(s)
p = os.path.join(k, "kitfiles.tsv")
s = open(p).readlines()
open(p, "w").writelines(l for l in s if not l.startswith(("claude/brain-kit/bin/heavy-lock\t", "claude/brain-kit/automations/README.md\t", "brain-template/dev/README.md\t")))
os.remove(os.path.join(k, "brain-template/dev/README.md"))
PYNEXT
next_update() { HOME="$1" bash "$NEXT/install.sh" --update --no-worktrees "${@:2}"; }
for seed in base seed; do
  H="$TMP/three-$seed"
  mkdir -p "$H"
  new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
  check "3-way $seed: install に base" test -f "$H/.claude/brain-kit/base/.claude/skills/aoi/SKILL.md"
  check "3-way $seed: brain に base" test -f "$H/brain/.brain-kit/base/CLAUDE.md"
  if [ "$seed" = seed ]; then
    rm -rf "$H/.claude/brain-kit/base" "$H/brain/.brain-kit/base"
    printf '\n持ち主の行。\n' >>"$H/.claude/skills/sora/SKILL.md"
    owner0="$(cat "$H/.claude/skills/sora/SKILL.md")"
    new "$H" --update --no-worktrees >"$H.seed" 2>&1
    check "seed: 未変更ファイルの base を補う" test -f "$H/.claude/brain-kit/base/.claude/skills/aoi/SKILL.md"
    check "seed: 不明な base は作らない" test ! -e "$H/.claude/brain-kit/base/.claude/skills/sora/SKILL.md"
    check "seed: 持ち主を上書きしない" test "$owner0" = "$(cat "$H/.claude/skills/sora/SKILL.md")"
    check "seed: 不明は衝突" test -f "$H/.claude/skills/sora/SKILL.md.new"
    # 一致に戻ったときも base を補う
    cp "$H/.claude/skills/sora/SKILL.md.new" "$H/.claude/skills/sora/SKILL.md"
    rm "$H/.claude/skills/sora/SKILL.md.new"
    new "$H" --update --no-worktrees >"$H.same" 2>&1
    check "seed: same も base を補う" test -f "$H/.claude/brain-kit/base/.claude/skills/sora/SKILL.md"
  fi
  python3 - "$H" <<'PYOWNER'
import os, sys
h = sys.argv[1]
for role in ("ren", "mio"):
    p = os.path.join(h, ".claude/skills", role, "SKILL.md")
    s = open(p).read()
    s = ("持ち主の先頭。\n" + s) if role == "ren" else s.replace("---", "---\n持ち主の行。", 1)
    open(p, "w").write(s)
PYOWNER
  printf '\n持ち主の末尾。\n' >>"$H/.claude/skills/sora/SKILL.md"
  printf '\n持ち主の末尾。\n' >>"$H/.claude/brain-kit/automations/README.md"
  rm "$H/brain/dev/README.md"
  mkdir -p "$H/.claude/skills/my-agent" "$H/.claude/agents"
  printf '持ち主の skill\n' >"$H/.claude/skills/my-agent/SKILL.md"
  printf '持ち主の agent\n' >"$H/.claude/agents/my-agent.md"
  cp "$H/.claude/brain-kit/manifest.json" "$H.manifest-before"
  before="$(snap "$H")"
  dirs0="$(find "$H/.claude/brain-kit" "$H/brain/.brain-kit" -type d | sort)"
  backups="$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  next_update "$H" --dry-run >"$H.dry" 2>&1
  rc=$?; check "3-way $seed: dry-run が 0" test "$rc" -eq 0
  [ "$rc" -eq 0 ] || cat "$H.dry"
  check "3-way $seed: dry-run は何も変えない" test "$before" = "$(snap "$H")"
  check "3-way $seed: dry-run も衝突の件数を出す" grep -q '衝突: 2 件' "$H.dry"
  check "3-way $seed: dry-run は退避も作らない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  for cls in '上げるもの（kit だけが変わった）' '持ち主だけが変えたもの' '両方が変えたもの' 'kit から外れたもの'; do
    check "3-way $seed: dry-run $cls" grep -q "$cls" "$H.dry"
  done
  next_update "$H" >"$H.up" 2>&1
  rc=$?; check "3-way $seed: update が 0" test "$rc" -eq 0
  [ "$rc" -eq 0 ] || cat "$H.up"
  check "3-way $seed: kit だけを更新" grep -q '次の版の末尾' "$H/.claude/skills/aoi/SKILL.md"
  check "3-way $seed: 非重複でも持ち主を残す" grep -q '^持ち主の先頭。' "$H/.claude/skills/ren/SKILL.md"
  check "3-way $seed: 非重複でも .new" test -f "$H/.claude/skills/ren/SKILL.md.new"
  check "3-way $seed: 重複でも .new" test -f "$H/.claude/skills/mio/SKILL.md.new"
  check "3-way $seed: 持ち主だけなら .new 無し" test ! -e "$H/.claude/skills/sora/SKILL.md.new"
  check "3-way $seed: 持ち主だけならそのまま" grep -q '持ち主の末尾' "$H/.claude/skills/sora/SKILL.md"
  check "3-way $seed: 外れた未変更ファイルは消す" test ! -e "$H/.claude/brain-kit/bin/heavy-lock"
  check "3-way $seed: 外れた変更済みファイルは残す" grep -q '持ち主の末尾' "$H/.claude/brain-kit/automations/README.md"
  check "3-way $seed: 外れた欠落ファイルは足さない" test ! -e "$H/brain/dev/README.md"
  check "3-way $seed: 外れた base は消す" test ! -e "$H/.claude/brain-kit/base/.claude/brain-kit/bin/heavy-lock"
  check "3-way $seed: 外れた変更済み base も消す" test ! -e "$H/.claude/brain-kit/base/.claude/brain-kit/automations/README.md"
  check "3-way $seed: 外れた欠落ファイルの base も消す" test ! -e "$H/brain/.brain-kit/base/dev/README.md"
  check "3-way $seed: 外れた manifest も消す" sh -c "! grep -q 'heavy-lock' '$H/.claude/brain-kit/manifest.json'"
  check "3-way $seed: 残すものを表示" grep -q 'automations/README.md.*残す' "$H.up"
  check "3-way $seed: 未登録 skill はそのまま" test "$(cat "$H/.claude/skills/my-agent/SKILL.md")" = '持ち主の skill'
  check "3-way $seed: 未登録 agent はそのまま" test "$(cat "$H/.claude/agents/my-agent.md")" = '持ち主の agent'
  check "3-way $seed: 機械マージは clean" sh -c "grep -q 'clean' '$H'/.claude/brain-kit/conflicts/*/README.md"
  check "3-way $seed: 機械マージは衝突印" sh -c "grep -q '1 conflict markers' '$H'/.claude/brain-kit/conflicts/*/README.md"
  check "3-way $seed: 最後に衝突の件数を必ず出す" sh -c "tail -n 5 '$H.up' | grep -q '衝突: 2 件'"
  check "3-way $seed: 最後に .new の一覧を出す" sh -c "tail -n 5 '$H.up' | grep -q 'ren/SKILL.md.new' && tail -n 5 '$H.up' | grep -q 'mio/SKILL.md.new'"
  check "3-way $seed: merged を保存" sh -c "ls '$H'/.claude/brain-kit/conflicts/*/files/claude/.claude/skills/ren/SKILL.md.merged"
  python3 - "$H" <<'PYBASE'
import hashlib, json, os, sys
h = sys.argv[1]
before = json.load(open(h + ".manifest-before"))["files"]
after = json.load(open(os.path.join(h, ".claude/brain-kit/manifest.json")))["files"]
for role in ("ren", "mio", "sora"):
    key = ".claude/skills/" + role + "/SKILL.md"
    assert before[key] == after[key]
    base = open(os.path.join(h, ".claude/brain-kit/base", key), "rb").read()
    assert hashlib.sha256(base).hexdigest() == before[key]["sha"]
PYBASE
  check "3-way $seed: 衝突・持ち主の manifest と base を保つ" test $? -eq 0
  HOME="$H" bash "$NEXT/install.sh" --doctor >"$H.doctor" 2>&1
  check "3-way $seed: doctor に持ち主の変更" grep -q '持ち主だけが変更' "$H.doctor"
  check "3-way $seed: doctor に衝突" grep -q '衝突' "$H.doctor"
  check "3-way $seed: doctor に .new" grep -q 'SKILL.md.new' "$H.doctor"
  after="$(snap "$H")"
  next_update "$H" >"$H.up2" 2>&1
  check "3-way $seed: 再更新も冪等" test "$after" = "$(snap "$H")"
  check "3-way $seed: 再更新でも衝突の件数を出す" sh -c "tail -n 5 '$H.up2' | grep -q '衝突: 2 件'"
  new "$H" --rollback >"$H.rb" 2>&1
  check "3-way $seed: rollback が 0" test $? -eq 0
  check "3-way $seed: rollback はバイト単位で戻す" test "$before" = "$(snap "$H")"
  check "3-way $seed: rollback で作った空ディレクトリも消す" test "$dirs0" = "$(find "$H/.claude/brain-kit" "$H/brain/.brain-kit" -type d | sort)"
done

# ------------------------------------------------------------------ 9. 前の .new が残ったまま、さらに次の版へ更新する
# 決め: .new は「いまの kit の新しい版」を置く場所。中身が違えば今回の新しい版で置き換え、前の .new は退避に残す（止めない）。
section "前の .new が残ったまま次の版へ"
NEXT2="$TMP/kit-next2"
mkdir -p "$NEXT2"
(cd "$NEXT" && tar cf - .) | (cd "$NEXT2" && tar xf -)
printf '\n次の次の版の末尾。\n' >>"$NEXT2/claude/skills/dev/SKILL.md"
H="$TMP/three-base"
next_update "$H" >"$H.up3" 2>&1
check "前の .new: 1 回目の更新で .new" test -f "$H/.claude/skills/ren/SKILL.md.new"
printf '\n持ち主が .new に書いた途中の行。\n' >>"$H/.claude/skills/ren/SKILL.md.new"
ours="$(cat "$H/.claude/skills/ren/SKILL.md")"
mio_new="$(cat "$H/.claude/skills/mio/SKILL.md.new")"
HOME="$H" bash "$NEXT2/install.sh" --update --no-worktrees --dry-run >"$H.dry4" 2>&1
check "前の .new: dry-run で置き換えると出す" grep -q 'ren/SKILL.md.new（前の更新の .new' "$H.dry4"
HOME="$H" bash "$NEXT2/install.sh" --update --no-worktrees >"$H.up4" 2>&1
check "前の .new: 2 回目の更新が 0" test $? -eq 0
check "前の .new: 元のファイルはそのまま" test "$ours" = "$(cat "$H/.claude/skills/ren/SKILL.md")"
check "前の .new: .new は今回の新しい版" grep -q '次の次の版の末尾' "$H/.claude/skills/ren/SKILL.md.new"
check "前の .new: 前の .new は退避に残る" sh -c "grep -rq '持ち主が .new に書いた途中の行' '$H'/.claude/backup-brain-kit-*/files"
check "前の .new: 置き換えたと最後に出す" sh -c "tail -n 5 '$H.up4' | grep -q 'ren/SKILL.md.new（前の更新の .new'"
check "前の .new: 変わらない .new はそのまま" test "$mio_new" = "$(cat "$H/.claude/skills/mio/SKILL.md.new")"
new "$H" --rollback >"$H.rb4" 2>&1
check "前の .new: rollback で前の .new に戻る" grep -q '持ち主が .new に書いた途中の行' "$H/.claude/skills/ren/SKILL.md.new"

# ------------------------------------------------------------------ 10. 工程表のスクショ（shot.py、標準ライブラリだけ）
section "工程表: スクショを db の 1 文書に縮める"
SHOT="$KIT/claude/brain-kit/dashboard/shot.py"
SD="$TMP/shot"
mkdir -p "$SD"
# テスト用の PNG を作る（標準ライブラリだけ）: 大きくて縮みにくい RGB・RGBA・パレット、小さい RGB
cat >"$SD/make.py" <<'PY'
import os, random, struct, sys, zlib
d = sys.argv[1]
def chunk(t, b):
    return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
def png(path, w, h, ctype, px, plte=None):
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += px[y * w * bpp:(y + 1) * w * bpp]
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    if plte:
        out += chunk(b"PLTE", plte)
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(out)
r = random.Random(7)
def noise(n, bits=8):
    return bytes(r.getrandbits(bits) for _ in range(n))
png(os.path.join(d, "big-rgb.png"), 1400, 900, 2, noise(1400 * 900 * 3))
png(os.path.join(d, "big-rgba.png"), 900, 700, 6, noise(900 * 700 * 4))
png(os.path.join(d, "big-pal.png"), 1200, 800, 3, noise(1200 * 800, 4), plte=noise(16 * 3))
png(os.path.join(d, "small.png"), 40, 30, 2, bytes((x * 5) % 256 for x in range(40 * 30 * 3)))
PY
python3 "$SD/make.py" "$SD"
# valid.py <doc.json> <上限> [元の png]: 文書が上限に収まり、data を戻すと PNG として読める（元より小さく、縦横比が同じ）
cat >"$SD/valid.py" <<'PY'
import base64, json, struct, sys, zlib
doc_path, limit = sys.argv[1], int(sys.argv[2])
raw = open(doc_path, "rb").read()
assert len(raw) <= limit, "doc %d > %d" % (len(raw), limit)
doc = json.loads(raw.decode("utf-8"))
pre = "data:image/png;base64,"
assert doc["data"].startswith(pre)
b = base64.b64decode(doc["data"][len(pre):], validate=True)
assert b[:8] == b"\x89PNG\r\n\x1a\n"
i, idat, ihdr = 8, b"", None
while i < len(b):
    n = struct.unpack(">I", b[i:i + 4])[0]
    t, body, crc = b[i + 4:i + 8], b[i + 8:i + 8 + n], struct.unpack(">I", b[i + 8 + n:i + 12 + n])[0]
    assert zlib.crc32(t + body) & 0xffffffff == crc, "crc"
    if t == b"IHDR":
        ihdr = struct.unpack(">IIBBBBB", body)
    elif t == b"IDAT":
        idat += body
    i += 12 + n
    if t == b"IEND":
        break
w, h, depth, ctype, _, _, interlace = ihdr
assert depth == 8 and interlace == 0
bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
assert len(zlib.decompress(idat)) == h * (1 + w * bpp), "IDAT size"
assert doc["w"] == w and doc["h"] == h
if len(sys.argv) > 3:
    sw, sh = struct.unpack(">II", open(sys.argv[3], "rb").read()[16:24])
    assert w < sw and h < sh, "not shrunk"
    assert abs(w / float(h) - sw / float(sh)) < 0.02, "aspect"
PY
cat >"$SD/same.py" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1]))
assert base64.b64decode(d["data"].split(",", 1)[1]) == open(sys.argv[2], "rb").read()
PY
cat >"$SD/meta.py" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ref"] == "example/app#1" and d["caption"] == "test" and d.get("taken_at")
PY
LIM=262144
check "shot.py: 元の PNG が 256KB を超えている（テストの前提）" test "$(wc -c <"$SD/big-rgb.png")" -gt "$LIM"
for f in big-rgb big-rgba big-pal; do
  python3 "$SHOT" "$SD/$f.png" --out "$SD/$f.json" --ref "example/app#1" --caption "test" >"$SD/$f.log" 2>&1
  check "shot.py: $f が 0 で終わる" test $? -eq 0
  check "shot.py: $f が 1 文書（256KB）に収まり、PNG として読め、縮んでいる" python3 "$SD/valid.py" "$SD/$f.json" "$LIM" "$SD/$f.png"
done
python3 "$SHOT" "$SD/big-rgb.png" --out "$SD/tight.json" --max-bytes 60000 >/dev/null 2>&1
check "shot.py: --max-bytes で上限を変えられる" python3 "$SD/valid.py" "$SD/tight.json" 60000 "$SD/big-rgb.png"
python3 "$SHOT" "$SD/small.png" --out "$SD/small.json" >/dev/null 2>&1
check "shot.py: 小さい画像も 0 で終わる" test $? -eq 0
check "shot.py: 小さい画像はそのまま通る（バイト一致）" python3 "$SD/same.py" "$SD/small.json" "$SD/small.png"
check "shot.py: ref・caption・taken_at が文書に入る" python3 "$SD/meta.py" "$SD/big-rgb.json"
check "shot.py: PNG でないものは 0 以外で止まる" sh -c "! python3 '$SHOT' '$SD/make.py' --out '$SD/bad.json' 2>/dev/null"
check "shot.py: 収まらない上限は 0 以外で止まる" sh -c "! python3 '$SHOT' '$SD/big-rgb.png' --out '$SD/none.json' --max-bytes 100 2>/dev/null"
DASH="$KIT/claude/brain-kit/dashboard/index.html"
check "工程表: スクショの段（shots）と判断のボタン（decisions）を読む" sh -c "grep -q 'collection(\"shots\")' '$DASH' && grep -q 'collection(\"decisions\")' '$DASH'"

# ------------------------------------------------------------------ 11. settings の所有記録と旧形式からの補完
section "settings の所有記録と補完"
H="$TMP/settings"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
check "settings: install が 0" test $? -eq 0
python3 - "$H" <<'PY'
import json, sys
m = json.load(open(sys.argv[1] + "/.claude/brain-kit/manifest.json"))["settings"]
assert m["hooks.SessionEnd"] and m["statusLine"]
assert m["enabledPlugins"]["pr-review-toolkit@claude-plugins-official"]
assert "permissions" not in m
PY
check "settings: install で所有項目を記録" test $? -eq 0
# npm はサンドボックスに無い。旧形式の Codex 設定を手で足し、フラグ無しの補完・保持を確かめる。
python3 - "$H" "$KIT" <<'PY'
import json, sys
h, k = sys.argv[1:]
p = h + "/.claude/brain-kit/manifest.json"
m = json.load(open(p)); del m["settings"]
json.dump(m, open(p, "w"), ensure_ascii=False, indent=2)
p = h + "/.claude/settings.json"
s = json.load(open(p))
s["hooks"]["SessionEnd"].insert(0, {"hooks": [{"type": "command", "command": "echo owner-before"}]})
s["model"] = "x"
c = json.load(open(k + "/claude/settings.codex.json"))
for part in ("enabledPlugins", "extraKnownMarketplaces"):
    s.setdefault(part, {}).update(c[part])
json.dump(s, open(p, "w"), ensure_ascii=False, indent=4)
PY
cp "$H/.claude/settings.json" "$H.seed-before"
new "$H" --update --no-worktrees >"$H.seed" 2>&1
check "settings: 補完が 0" test $? -eq 0
check "settings: 補完はバイトを保つ" cmp "$H.seed-before" "$H/.claude/settings.json"
python3 - "$H" <<'PY'
import json, sys
m = json.load(open(sys.argv[1] + "/.claude/brain-kit/manifest.json"))["settings"]
assert m["hooks.SessionEnd"] and m["statusLine"]
assert m["extraKnownMarketplaces"]["openai-codex"]
assert m["enabledPlugins"]["codex@openai-codex"]
assert "echo owner-before" not in m["hooks.SessionEnd"]
PY
check "settings: 所有記録を補完し Codex も保持" test $? -eq 0
before="$(snap "$H")"
new "$H" --update --no-worktrees >"$H.seed2" 2>&1
check "settings: 補完後の再更新は冪等" test "$before" = "$(snap "$H")"

# ------------------------------------------------------------------ 12. settings の次の版・衝突資料・戻し
section "settings の次の版"
NEXTS="$TMP/kit-next-s"
mkdir -p "$NEXTS"
while IFS= read -r -d '' f; do
  mkdir -p "$NEXTS/$(dirname "$f")"
  cp "$KIT/$f" "$NEXTS/$f"
done < <(git -C "$KIT" ls-files --cached --others --exclude-standard -z)
python3 - "$NEXTS" "$H" <<'PY'
import json, sys
k, h = sys.argv[1:]
p = k + "/claude/settings.snippet.json"
s = json.load(open(p))
s["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"] = 120
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 20
s["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"] += " # v2"
for event in ("TeammateIdle", "PostCompact"):
    del s["hooks"][event]
s["hooks"]["Notification"] = [{"hooks": [{"type": "command", "command": "echo notification"}]}]
s["statusLine"]["command"] += " # v2"
s["enabledPlugins"]["example-plugin@claude-plugins-official"] = True
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
p = h + "/.claude/settings.json"
s = json.load(open(p))
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 30
s["hooks"]["PostCompact"][0]["hooks"][0]["timeout"] = 11
s["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo owner-after"}]})
s["hooks"]["PreCompact"] = [{"hooks": [{"type": "command", "command": "echo owner-event"}]}]
s["enabledPlugins"]["owner-plugin@example-market"] = False
json.dump(s, open(p, "w"), ensure_ascii=False, indent=4)
PY
cp "$H/.claude/settings.json" "$H.before"
cp "$H/.claude/brain-kit/manifest.json" "$H.manifest-before"
s_update() { HOME="$1" bash "$NEXTS/install.sh" --update --no-worktrees "${@:2}"; }
before="$(snap "$H")"
backups="$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
s_update "$H" --dry-run >"$H.dry" 2>&1
check "settings: dry-run が 0" test $? -eq 0
check "settings: dry-run は書かない" test "$before" = "$(snap "$H")"
check "settings: dry-run は退避を作らない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
for cls in 'に足すもの' 'で上げるもの' 'から外すもの' 'の衝突（触らない）' 'で残すもの'; do
  check "settings: dry-run $cls" grep -q "settings.json $cls" "$H.dry"
done
check "settings: dry-run の最後に衝突件数" grep -q 'settings.json の衝突: 1 件' "$H.dry"
s_update "$H" >"$H.up" 2>&1
check "settings: 更新が 0" test $? -eq 0
python3 - "$H" "$NEXTS" <<'PY'
import hashlib, json, sys
h, k = sys.argv[1:]
before = json.load(open(h + ".before"))
after = json.load(open(h + "/.claude/settings.json"))
kit = json.load(open(k + "/claude/settings.snippet.json"))
bm = json.load(open(h + ".manifest-before"))["settings"]
am = json.load(open(h + "/.claude/brain-kit/manifest.json"))["settings"]
def digest(v):
    return hashlib.sha256(json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
assert after["hooks"]["SessionEnd"][1] == kit["hooks"]["SessionEnd"][0]
assert after["hooks"]["SessionEnd"][0] == before["hooks"]["SessionEnd"][0]
assert after["hooks"]["Stop"] == before["hooks"]["Stop"]
assert after["hooks"]["UserPromptSubmit"] == kit["hooks"]["UserPromptSubmit"]
assert "TeammateIdle" not in after["hooks"]
assert after["hooks"]["PostCompact"] == before["hooks"]["PostCompact"]
assert after["hooks"]["Notification"] == kit["hooks"]["Notification"]
assert after["statusLine"] == kit["statusLine"]
assert after["enabledPlugins"]["example-plugin@claude-plugins-official"] is True
assert after["hooks"]["PreCompact"] == before["hooks"]["PreCompact"]
assert after["model"] == before["model"] == "x"
assert after["enabledPlugins"]["owner-plugin@example-market"] is False
assert list(after) == list(before)
for part in ("hooks", "enabledPlugins", "extraKnownMarketplaces"):
    assert [key for key in after[part] if key in before[part]] == [key for key in before[part] if key in after[part]]
assert am["hooks.Stop"] == bm["hooks.Stop"]
assert "hooks.TeammateIdle" not in am and "hooks.PostCompact" not in am
for event in ("SessionEnd", "UserPromptSubmit", "Notification"):
    group = kit["hooks"][event][0]
    assert am["hooks." + event] == {group["hooks"][0]["command"]: digest(group)}
assert am["statusLine"] == digest(kit["statusLine"])
assert am["extraKnownMarketplaces"] == bm["extraKnownMarketplaces"]
assert am["enabledPlugins"]["codex@openai-codex"] == bm["enabledPlugins"]["codex@openai-codex"]
PY
check "settings: 更新・削除・位置・持ち主の値と順序・所有記録" test $? -eq 0
check "settings: 衝突を最後に表示" grep -q 'settings.json の衝突: 1 件' "$H.up"
check "settings: 変更済みの削除対象は残すと表示" grep -q 'settings.json で残すもの' "$H.up"
check "settings: 単独の衝突でも資料を作る" sh -c "grep -q '^## settings.json' '$H'/.claude/brain-kit/conflicts/*/README.md"
python3 - "$H" <<'PY'
import glob, json, sys
h = sys.argv[1]
s = open(glob.glob(h + "/.claude/brain-kit/conflicts/*/README.md")[0]).read()
assert '"timeout": 30' in s and '"timeout": 20' in s
m = json.load(open(h + ".manifest-before"))["settings"]["hooks.Stop"]
assert next(iter(m.values())) in s
PY
check "settings: 資料に現在・記録 sha・kit の JSON" test $? -eq 0
after="$(snap "$H")"
backups="$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
s_update "$H" >"$H.up2" 2>&1
check "settings: 同じ版で再更新が 0" test $? -eq 0
check "settings: 再更新は資料も含め冪等" test "$after" = "$(snap "$H")"
check "settings: 再更新は退避を増やさない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
new "$H" --rollback >"$H.rb" 2>&1
check "settings: rollback が 0" test $? -eq 0
check "settings: rollback は元のバイトに戻す" cmp "$H.before" "$H/.claude/settings.json"
check "settings: rollback は資料・manifest も戻す" test "$before" = "$(snap "$H")"

# ------------------------------------------------------------------ 13. settings の削除・未登録・command 変更の境界
section "settings の項目判定の境界"
python3 - "$KIT" "$TMP" <<'PY'
import json, os, runpy, sys
kit, tmp = sys.argv[1:]
ns = runpy.run_path(kit + "/lib/kit.py")
plan = ns["plan_settings"]
g = plan.__globals__
k = tmp + "/settings-cases"
os.makedirs(k + "/claude")
g["KIT"] = k
g["CLAUDE"] = k + "/claude"
p = k + "/claude/settings.json"
def write(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f)
write(k + "/claude/settings.codex.json", {})
def run(ours, theirs, record):
    write(p, ours)
    write(k + "/claude/settings.snippet.json", theirs)
    return plan(False, {"settings": record})
for part in ("hooks.Stop", "enabledPlugins", "extraKnownMarketplaces", "statusLine"):
    def value(n):
        return {"hooks": [{"command": "echo kit", "timeout": n}]} if part.startswith("hooks.") else {"value": n}
    def obj(n):
        if n is None:
            return {}
        if part.startswith("hooks."):
            return {"hooks": {"Stop": [value(n)]}}
        return {part: value(n) if part == "statusLine" else {"example": value(n)}}
    def rec(n):
        v = ns["settings_sha"](value(n))
        return {part: v if part == "statusLine" else {"echo kit" if part.startswith("hooks.") else "example": v}}
    # 記録なしの一致は書き換えず補完。持ち主の statusLine は黙って残す。
    r = run(obj(1), obj(1), {})
    assert not r["changed"] and r["record"] == rec(1), part
    r = run(obj(2), obj(1), {})
    assert not r["changed"] and not r["record"], part
    assert bool(r["conflict"]) == (part != "statusLine"), part
    # 持ち主の削除は再追加せず、kit の変更だけを衝突にする。
    r = run({}, obj(1), rec(1))
    assert not r["changed"] and not r["conflict"] and r["record"] == rec(1), part
    r = run({}, obj(2), rec(1))
    assert not r["changed"] and r["conflict"] and r["record"] == rec(1), part
    r = run({}, {}, rec(1))
    assert not r["changed"] and not r["record"], part
    # 持ち主だけの編集と、両者が同じ値にした場合。
    r = run(obj(2), obj(1), rec(1))
    assert not r["changed"] and not r["conflict"] and r["record"] == rec(1), part
    r = run(obj(2), obj(2), rec(1))
    assert not r["changed"] and r["record"] == rec(2), part
    r = run(obj(1), {}, rec(1))
    assert r["remove"] and not r["record"], part
    assert "hooks" not in json.loads(r["new"]) if part.startswith("hooks.") else True
    r = run(obj(2), {}, rec(1))
    assert not r["changed"] and r["keep"] and not r["record"], part
old = {"hooks": [{"command": "echo old", "timeout": 10}]}
new = {"hooks": [{"command": "echo new", "timeout": 20}]}
record = {"hooks.Stop": {"echo old": ns["settings_sha"](old)}}
for groups in ([], [{"hooks": [{"command": "echo old", "timeout": 30}]}]):
    r = run({"hooks": {"Stop": groups}}, {"hooks": {"Stop": [new]}}, record)
    assert r["conflict"] and not r["changed"] and not r["add"]
    assert r["record"] == record
    # 記録を保存して 2 回目: 持ち主が消したフックを足さず、衝突を出し続ける
    write(p, {"hooks": {"Stop": groups}})
    r2 = plan(False, {"settings": r["record"]})
    assert r2["conflict"] and not r2["changed"] and not r2["add"] and r2["record"] == record
# 同じイベントで command が 2 つ変わったら対応を推測しない（記録はキー順で保存されるので z, a の順でも試す）。
oz = {"hooks": [{"command": "echo z", "timeout": 1}]}
oa = {"hooks": [{"command": "echo a", "timeout": 1}]}
oa_owner = {"hooks": [{"command": "echo a", "timeout": 9}]}
nz = {"hooks": [{"command": "echo z-v2", "timeout": 1}]}
na = {"hooks": [{"command": "echo a-v2", "timeout": 1}]}
rec2 = {"hooks.Stop": {"echo z": ns["settings_sha"](oz), "echo a": ns["settings_sha"](oa)}}
rec2 = json.loads(json.dumps(rec2, sort_keys=True))
for _ in range(2):
    r = run({"hooks": {"Stop": [oz, oa_owner]}}, {"hooks": {"Stop": [nz, na]}}, rec2)
    assert not r["changed"] and not r["add"] and not r["update"] and len(r["conflict"]) == 4
    assert r["record"] == rec2
# 最初以外の hook に同じ command があっても、先に見つかった group を現在値とする。
ours = {"hooks": [{"command": "echo owner"}, {"command": "echo old"}]}
r = run({"hooks": {"Stop": [ours, old]}}, {"hooks": {"Stop": [new]}}, record)
assert r["conflict"] and not r["changed"]
# permissions は所有記録に入れず、既にある値は保つ。
r = run({"permissions": {}}, {"permissions": {"allow": ["Bash(ls:*)"]}}, {})
assert not r["changed"] and not r["record"]
os.remove(p)
write(k + "/claude/settings.snippet.json", {})
r = plan()
assert not r["changed"] and r["new"] is None and not os.path.exists(p)
PY
check "settings: 各種類の削除・補完・持ち主の編集・command 衝突・未作成" test $? -eq 0

# ------------------------------------------------------------------ 14. 持ち主の道具の一覧と名前の重なり
section "相棒に渡す一覧と名前の重なり"
H="$TMP/inventory"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
mkdir -p "$H/.claude/skills/my-agent" "$H/.claude/agents"
printf '持ち主の skill\n' >"$H/.claude/skills/my-agent/SKILL.md"
printf '持ち主の agent\n' >"$H/.claude/agents/my-agent.md"
python3 - "$H" <<'PY'
import json, sys
p = sys.argv[1] + "/.claude/settings.json"
s = json.load(open(p))
s["hooks"]["Stop"][0]["hooks"].append({"command": "echo owner-tool"})
s["hooks"]["OwnerEvent"] = [{"hooks": [{"command": "echo owner-event"}]}]
s["enabledPlugins"]["owner-plugin@example-market"] = True
s["extraKnownMarketplaces"] = {"owner-market": {"source": {"source": "github", "repo": "example/market"}}}
json.dump(s, open(p, "w"), ensure_ascii=False, indent=4)
PY
before="$(snap "$H")"
new "$H" --update --no-worktrees >"$H.inventory" 2>&1
check "一覧: 一覧だけなら資料も変更も無い" test "$before" = "$(snap "$H")"
printf '持ち主のレビュー\n' >"$H/.claude/agents/MIO.md"
printf '\n持ち主の末尾。\n' >>"$H/.claude/skills/ren/SKILL.md"
cp "$H/.claude/settings.json" "$H.settings-before"
next_update "$H" >"$H.up" 2>&1
check "一覧: 衝突と一覧を作る更新が 0" test $? -eq 0
python3 - "$H" <<'PY'
import glob, sys
h = sys.argv[1]
s = open(glob.glob(h + "/.claude/brain-kit/conflicts/*/README.md")[0]).read()
inv = s.split("## 持ち主が足した agent と道具（kit の外。中身は読んでいない）\n", 1)[1].split("## 名前の重なり", 1)[0]
assert "skills: 1 件（my-agent）" in inv
for name in ("my-agent.md", "MIO.md", "hooks.Stop: echo owner-tool", "hooks.OwnerEvent: echo owner-event", "owner-plugin@example-market", "owner-market"):
    assert name in inv, name
collisions = s.split("## 名前の重なり", 1)[1]
assert "agents/MIO.md" in collisions and "MIO-own" in collisions
assert "## 解き方" in s and "--resolve --keep" in s and "settings.json" in s
assert "持ち主の skill" not in inv and "持ち主のレビュー" not in inv
PY
check "一覧: kit を除いた道具・command と大小文字を問わない重なり・解き方" test $? -eq 0
check "一覧: skill の内容を保つ" test "$(cat "$H/.claude/skills/my-agent/SKILL.md")" = '持ち主の skill'
check "一覧: agent の内容を保つ" test "$(cat "$H/.claude/agents/my-agent.md")" = '持ち主の agent'
check "一覧: 重なった agent の内容を保つ" test "$(cat "$H/.claude/agents/MIO.md")" = '持ち主のレビュー'
check "一覧: 設定のバイトを保つ" cmp "$H.settings-before" "$H/.claude/settings.json"
check "一覧: 最後にも重なりと資料の場所" sh -c "tail -n 3 '$H.up' | grep -q '名前の重なり: 1 件' && tail -n 1 '$H.up' | grep -q '衝突の資料:'"
after="$(snap "$H")"
next_update "$H" >"$H.up2" 2>&1
check "一覧: 同じ衝突資料を再利用" test "$after" = "$(snap "$H")"

# ------------------------------------------------------------------ 15. 所有ディレクトリには入れない
section "所有ディレクトリとの重なり"
mkdir -p "$NEXT/claude/skills/extra"
printf '追加の kit skill\n' >"$NEXT/claude/skills/extra/SKILL.md"
printf 'claude/skills/extra/SKILL.md\t~/.claude/skills/extra/SKILL.md\n' >>"$NEXT/kitfiles.tsv"
for kind in without with; do
  H="$TMP/collision-$kind"
  mkdir -p "$H"
  new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
  mkdir -p "$H/.claude/skills/extra"
  printf '持ち主の道具\n' >"$H/.claude/skills/extra/tool.md"
  if [ "$kind" = with ]; then printf '持ち主の skill\n' >"$H/.claude/skills/extra/SKILL.md"; fi
  before="$(snap "$H")"
  backups="$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  next_update "$H" --dry-run >"$H.dry" 2>&1
  check "重なり $kind: dry-run に対象と提案" grep -q 'extra/SKILL.md: 持ち主の方を別名に移すか、kit の方を使わないか' "$H.dry"
  check "重なり $kind: dry-run は書かない" test "$before" = "$(snap "$H")"
  check "重なり $kind: dry-run は退避も作らない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  next_update "$H" >"$H.up" 2>&1
  check "重なり $kind: 更新が 0" test $? -eq 0
  check "重なり $kind: 最後に重なりと提案" sh -c "tail -n 3 '$H.up' | grep -q 'extra/SKILL.md: 持ち主の方を別名に移すか、kit の方を使わないか'"
  python3 - "$H" "$kind" <<'PY'
import glob, json, os, sys
h, kind = sys.argv[1:]
key = ".claude/skills/extra/SKILL.md"
p = h + "/" + key
if kind == "with":
    assert open(p).read() == "持ち主の skill\n"
else:
    assert not os.path.exists(p)
assert open(os.path.dirname(p) + "/tool.md").read() == "持ち主の道具\n"
assert not os.path.exists(p + ".new")
assert not os.path.exists(h + "/.claude/brain-kit/base/" + key)
assert key not in json.load(open(h + "/.claude/brain-kit/manifest.json"))["files"]
s = open(glob.glob(h + "/.claude/brain-kit/conflicts/*/README.md")[0]).read()
assert "## 名前の重なり" in s and "extra/SKILL.md: 持ち主の方を別名に移すか、kit の方を使わないか" in s
PY
  check "重なり $kind: 所有ファイル・base・manifest に書かず、単独でも資料に残す" test $? -eq 0
  after="$(snap "$H")"
  next_update "$H" >"$H.up2" 2>&1
  check "重なり $kind: 再更新は資料も同じ" test "$after" = "$(snap "$H")"
  mv "$H/.claude/skills/extra" "$H/.claude/skills/extra-own"
  next_update "$H" >"$H.moved" 2>&1
  check "重なり $kind: 持ち主が移したあと kit を足せる" cmp "$NEXT/claude/skills/extra/SKILL.md" "$H/.claude/skills/extra/SKILL.md"
done
H="$TMP/collision-empty"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
mkdir -p "$H/.claude/skills/extra"
next_update "$H" >"$H.up" 2>&1
check "重なり empty: 空のディレクトリには kit を足す" cmp "$NEXT/claude/skills/extra/SKILL.md" "$H/.claude/skills/extra/SKILL.md"
check "重なり empty: 重なりとして出さない" sh -c "! grep -q '名前の重なり' '$H.up'"
HOME="$H" python3 - "$KIT" <<'PY' >"$H.id" 2>&1
import argparse, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
p = os.path.join(ns["CLAUDE"], "skills", "occupied")
os.makedirs(p)
open(p + "/tool.md", "w").write("持ち主の道具\n")
args = argparse.Namespace(review="Review", review_id="occupied", yes=True)
ns["choose_persona"]("review", args, set(), {"files": {}})
PY
check "人格 id: SKILL.md の無い所有ディレクトリも終了 2" test $? -eq 2
check "人格 id: 別 id の指定を案内" grep -q -- '--review-id <別の id>' "$H.id"

# ------------------------------------------------------------------ 16. ファイルの解消と拒否・戻す順序
section "ファイルの解消"
next_resolve() { HOME="$1" bash "$NEXT/install.sh" --resolve "${@:2}"; }
for method in from inplace keep; do
  H="$TMP/resolve-$method"
  mkdir -p "$H"
  new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
  target="$H/.claude/skills/mio/SKILL.md"
  python3 - "$target" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("---", "---\n持ち主の行。", 1)
open(p, "w").write(s)
PY
  before="$(snap "$H")"
  next_update "$H" >"$H.up" 2>&1
  cp "$target.new" "$H.theirs"
  printf '持ち主の追記。\n' >"$H.merged"
  cat "$target.new" >>"$H.merged"
  if [ "$method" = inplace ]; then cp "$H.merged" "$target"; fi
  after_update="$(snap "$H")"
  backups="$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  if [ "$method" = from ]; then
    for refusal in owner same markers stale both missing; do
      case "$refusal" in
        owner) ARGS=("$H/brain/Aoi/00_核.md") ;;
        same) ARGS=("$H/.claude/skills/sora/SKILL.md") ;;
        markers) ARGS=("$target" --from "$H/.claude/brain-kit/conflicts/"*/files/claude/.claude/skills/mio/SKILL.md.merged) ;;
        stale) printf '別の版\n' >"$target.new"; ARGS=("$target") ;;
        both) ARGS=(--keep "$target" --from "$H.merged") ;;
        missing) ARGS=("$target" --from "$H.absent") ;;
      esac
      refusal_before="$(snap "$H")"
      next_resolve "$H" "${ARGS[@]}" >"$H.refusal" 2>&1
      check "解消の拒否 $refusal: 終了 2" test $? -eq 2
      check "解消の拒否 $refusal: 何も書かない" test "$refusal_before" = "$(snap "$H")"
      check "解消の拒否 $refusal: 退避も作らない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
      if [ "$refusal" = stale ]; then cp "$H.theirs" "$target.new"; fi
    done
    # 別の名前の symlink で kit のファイルを指しても、kit のファイルとしては扱わない
    ln -s "$target" "$H/brain/link.md"
    refusal_before="$(snap "$H")"
    next_resolve "$H" "$H/brain/link.md" --from "$H.merged" >"$H.refusal" 2>&1
    check "解消の拒否 symlink: 終了 2" test $? -eq 2
    check "解消の拒否 symlink: 何も書かない" test "$refusal_before" = "$(snap "$H")"
    rm "$H/brain/link.md"
    # kit のファイルの場所が symlink なら、指す先（持ち主のもの）に書かない
    mv "$target" "$H/brain/owner-note.md"
    ln -s "$H/brain/owner-note.md" "$target"
    refusal_before="$(snap "$H")"
    next_resolve "$H" "$target" --from "$H.merged" >"$H.refusal" 2>&1
    check "解消の拒否 symlink の kit: 終了 2" test $? -eq 2
    check "解消の拒否 symlink の kit: 何も書かない" test "$refusal_before" = "$(snap "$H")"
    rm "$target"
    mv "$H/brain/owner-note.md" "$target"
    ARGS=("$target" --from "$H.merged")
  elif [ "$method" = inplace ]; then
    ARGS=("$target")
  else
    ARGS=(--keep "$target")
    cp "$target" "$H.merged"
  fi
  next_resolve "$H" "${ARGS[@]}" --dry-run >"$H.dry" 2>&1
  check "解消 $method: dry-run が 0" test $? -eq 0
  check "解消 $method: dry-run は書かない" test "$after_update" = "$(snap "$H")"
  check "解消 $method: dry-run は退避も作らない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  next_resolve "$H" "${ARGS[@]}" >"$H.resolve" 2>&1
  check "解消 $method: 実行が 0" test $? -eq 0
  check "解消 $method: 結果が一致" cmp "$H.merged" "$target"
  check "解消 $method: .new を消す" test ! -e "$target.new"
  check "解消 $method: base が kit の版" cmp "$H.theirs" "$H/.claude/brain-kit/base/.claude/skills/mio/SKILL.md"
  python3 - "$H" <<'PY'
import hashlib, json, sys
h = sys.argv[1]
def digest(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
r = json.load(open(h + "/.claude/brain-kit/manifest.json"))["files"][".claude/skills/mio/SKILL.md"]
assert r == {"sha": digest(h + ".theirs"), "merged": digest(h + ".merged")}
PY
  check "解消 $method: sha と merged を記録" test $? -eq 0
  after="$(snap "$H")"
  next_update "$H" >"$H.up2" 2>&1
  check "解消 $method: 次の更新は結果も記録も変えない" test "$after" = "$(snap "$H")"
  check "解消 $method: 次の更新は衝突を出さない" sh -c "! grep -q '衝突:' '$H.up2'"
  new "$H" --rollback >"$H.rb1" 2>&1
  check "解消 $method: 最初の rollback は解消前のバイトに戻す" test "$after_update" = "$(snap "$H")"
  if [ "$method" != inplace ]; then
    new "$H" --rollback >"$H.rb2" 2>&1
    check "解消 $method: 次の rollback は更新前のバイトに戻す" test "$before" = "$(snap "$H")"
  fi
done

# ------------------------------------------------------------------ 17. settings の解消
section "settings の解消"
H="$TMP/settings"
s_update "$H" >"$H.up3" 2>&1
for method in inplace keep from; do
  cp "$H/.claude/settings.json" "$H.resolve-before"
  cp "$H/.claude/brain-kit/manifest.json" "$H.resolve-manifest"
  before="$(snap "$H")"
  backups="$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  ARGS=("$H/.claude/settings.json")
  if [ "$method" = keep ]; then ARGS=(--keep "$H/.claude/settings.json"); fi
  if [ "$method" = from ]; then
    python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
s = json.load(open(h + "/.claude/settings.json"))
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 45
json.dump(s, open(h + ".merged.json", "w"), ensure_ascii=False, indent=4)
PY
    ARGS+=(--from "$H.merged.json")
    printf '[]\n' >"$H.invalid.json"
    HOME="$H" bash "$NEXTS/install.sh" --resolve "$H/.claude/settings.json" --from "$H.invalid.json" >"$H.invalid" 2>&1
    check "settings 解消: 配列は終了 2" test $? -eq 2
    check "settings 解消: 不正な JSON では書かない" test "$before" = "$(snap "$H")"
  fi
  HOME="$H" bash "$NEXTS/install.sh" --resolve "${ARGS[@]}" --dry-run >"$H.resolve-dry" 2>&1
  check "settings 解消 $method: dry-run が 0" test $? -eq 0
  check "settings 解消 $method: dry-run は書かない" test "$before" = "$(snap "$H")"
  check "settings 解消 $method: dry-run は退避も作らない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
  HOME="$H" bash "$NEXTS/install.sh" --resolve "${ARGS[@]}" >"$H.resolve" 2>&1
  check "settings 解消 $method: 実行が 0" test $? -eq 0
  if [ "$method" = from ]; then
    check "settings 解消 $method: 指定した JSON のバイトを保つ" cmp "$H.merged.json" "$H/.claude/settings.json"
  else
    check "settings 解消 $method: 持ち主の JSON はそのまま" cmp "$H.resolve-before" "$H/.claude/settings.json"
  fi
  python3 - "$H" "$NEXTS" <<'PY'
import hashlib, json, sys
h, k = sys.argv[1:]
before = json.load(open(h + ".resolve-manifest"))
after = json.load(open(h + "/.claude/brain-kit/manifest.json"))
v = json.load(open(k + "/claude/settings.snippet.json"))["hooks"]["Stop"][0]
key = v["hooks"][0]["command"]
before.pop("settings_conflicts", None)   # 更新が覚えた衝突は解消で外れる
before["settings"]["hooks.Stop"][key] = hashlib.sha256(json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
assert after == before
PY
  check "settings 解消 $method: 衝突した項目だけ kit の sha を記録" test $? -eq 0
  after="$(snap "$H")"
  s_update "$H" >"$H.resolved-up" 2>&1
  check "settings 解消 $method: 再更新で衝突しない" sh -c "! grep -q 'settings.json の衝突:' '$H.resolved-up'"
  check "settings 解消 $method: 再更新で何も変わらない" test "$after" = "$(snap "$H")"
  HOME="$H" bash "$NEXTS/install.sh" --resolve "$H/.claude/settings.json" >"$H.no-conflict" 2>&1
  check "settings 解消 $method: 衝突無しは終了 2" test $? -eq 2
  check "settings 解消 $method: 衝突無しでは書かない" test "$after" = "$(snap "$H")"
  new "$H" --rollback >"$H.rb-resolve" 2>&1
  check "settings 解消 $method: rollback は設定と manifest をバイト単位で戻す" test "$before" = "$(snap "$H")"
done

# ------------------------------------------------------------------ 18. 改名したフックの解消と記録の境界
section "フックの改名の解消"
H="$TMP/resolve-command"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
python3 - "$H" <<'PY'
import json, sys
p = sys.argv[1] + "/.claude/settings.json"
s = json.load(open(p))
s["hooks"]["UserPromptSubmit"][0]["hooks"][0]["timeout"] = 99
json.dump(s, open(p, "w"), ensure_ascii=False, indent=4)
PY
# 更新前に解消しても、無関係な kit の変更まで記録しない。
cp "$H/.claude/settings.json" "$H.ours"
cp "$H/.claude/brain-kit/manifest.json" "$H.manifest"
HOME="$H" bash "$NEXTS/install.sh" --resolve --keep "$H/.claude/settings.json" >"$H.resolve" 2>&1
check "command 解消: 実行が 0" test $? -eq 0
check "command 解消: 持ち主の JSON を保つ" cmp "$H.ours" "$H/.claude/settings.json"
python3 - "$H" "$NEXTS" <<'PY'
import hashlib, json, sys
h, k = sys.argv[1:]
before = json.load(open(h + ".manifest"))
after = json.load(open(h + "/.claude/brain-kit/manifest.json"))
v = json.load(open(k + "/claude/settings.snippet.json"))["hooks"]["UserPromptSubmit"][0]
key = v["hooks"][0]["command"]
before["settings"]["hooks.UserPromptSubmit"] = {key: hashlib.sha256(json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()}
assert before == after
PY
check "command 解消: 古い command の記録を外し、新しい command だけ記録" test $? -eq 0
s_update "$H" >"$H.up" 2>&1
check "command 解消: 再更新で衝突無し" sh -c "! grep -q 'settings.json の衝突:' '$H.up'"
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
a = json.load(open(h + ".ours"))
b = json.load(open(h + "/.claude/settings.json"))
assert a["hooks"]["UserPromptSubmit"] == b["hooks"]["UserPromptSubmit"]
assert b["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"] == 120
PY
check "command 解消: 新 command は足さず、無関係な kit 変更は更新できる" test $? -eq 0

# ------------------------------------------------------------------ 19. 同じ秒の退避と、所有ファイルを読まないこと
section "退避の順序と読み取りの境界"
HOME="$TMP/order" python3 - "$KIT" <<'PY' >"$TMP/order.log" 2>&1
import argparse, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
g["STAMP"] = "20300101-010101"
p = os.path.join(g["CLAUDE"], "order.md")
for old in (False, True):
    entries = []
    for i in range(12):
        backup = g["Backup"]("resolve", {"brain": None, "from": 10, "to": 10, "target": p})
        g["put"](p, str(i), backup)
        directory = backup.close()
        if old:
            meta = g["load_json"](directory + "/meta.json")
            del meta["created"]
            del meta["seq"]
            del meta["legacy_before"]
            g["write_text"](directory + "/meta.json", g["dump_json"](meta))
        entries.append(directory)
    assert entries[-1].endswith("-12") if not old else entries[-1].endswith("-24")
    for i in range(11, -1, -1):
        g["cmd_rollback"](argparse.Namespace(dry_run=False))
        assert g["load_json"](entries[i] + "/meta.json")["rolled_back"]
        assert g["read_text"](p) == (str(i - 1) if i else None)
PY
check "退避: 同じ秒の 12 件を新旧の記録とも新しい順に戻す" test $? -eq 0
# 壁時計は戻ることがある（NTP や仮想機械の時刻合わせで数 ms）。作った順は時計でなく退避の通し番号で決める
HOME="$TMP/order-clock" python3 - "$KIT" <<'PY' >"$TMP/order-clock.log" 2>&1
import argparse, datetime, os, runpy, sys, types
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
ticks = [datetime.datetime(2030, 1, 1, 1, 1, 2, 5000)]
class Clock(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        ticks.append(ticks[-1] - datetime.timedelta(milliseconds=10))   # 呼ぶたびに 10 ms 戻る
        return ticks[-1]
fake = types.ModuleType("datetime")
fake.__dict__.update(datetime.__dict__)
fake.datetime = Clock
g["datetime"] = fake
p = os.path.join(g["CLAUDE"], "order-clock.md")
# 先頭の 2 件は記録の古い退避（通し番号も作った時刻も無い）。次の 3 件は同じ秒、最後は時計が前の秒に戻った退避
entries = []
for i, stamp in enumerate(["20300101-010100", "20300101-010100", "20300101-010102", "20300101-010102",
                           "20300101-010102", "20300101-010101"]):
    g["STAMP"] = stamp
    backup = g["Backup"]("resolve", {"brain": None, "from": 10, "to": 10, "target": p})
    g["put"](p, str(i), backup)
    directory = backup.close()
    if i < 2:
        meta = g["load_json"](directory + "/meta.json")
        meta.pop("created")
        meta.pop("seq", None)
        meta.pop("legacy_before", None)
        g["write_text"](directory + "/meta.json", g["dump_json"](meta))
    entries.append(directory)
for i in range(len(entries) - 1, -1, -1):
    g["cmd_rollback"](argparse.Namespace(dry_run=False))
    assert g["load_json"](entries[i] + "/meta.json")["rolled_back"], (i, entries[i])
    assert g["read_text"](p) == (str(i - 1) if i else None), (i, g["read_text"](p))
PY
check "退避: 時計が戻っても作った順の逆に戻す（同じ秒・前の秒・古い記録）" test $? -eq 0
# 通し番号が壊れている（型・値・重なり）退避があれば、どれから戻すか決めずに止まる（番号の無い古い記録とは扱わない）
HOME="$TMP/order-badseq" python3 - "$KIT" <<'PY' >"$TMP/order-badseq.log" 2>&1
import argparse, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
p = os.path.join(g["CLAUDE"], "order-badseq.md")
g["write_text"](p, "owner")
dirs = []
for i in range(2):
    backup = g["Backup"]("resolve", {"brain": None, "from": 10, "to": 10, "target": p})
    g["put"](p, "kit%d" % i, backup)
    dirs.append(backup.close())
for key, bad in (("seq", "2"), ("seq", 0), ("seq", None), ("seq", True), ("seq", 1), ("legacy_before", None), ("legacy_before", [])):
    meta = g["load_json"](dirs[1] + "/meta.json")
    meta["seq"] = 2
    meta["legacy_before"] = {}
    meta[key] = bad
    g["write_text"](dirs[1] + "/meta.json", g["dump_json"](meta))
    try:
        g["cmd_rollback"](argparse.Namespace(dry_run=False))
        raise AssertionError("rollback が止まらなかった: %r" % ((key, bad),))
    except SystemExit as e:
        assert e.code == 1, e.code
    assert g["read_text"](p) == "kit1"
    assert not any(g["load_json"](d + "/meta.json")["rolled_back"] for d in dirs)
PY
check "退避: 通し番号が壊れていれば何も戻さずに止まる" test $? -eq 0
# 戻していない退避の meta.json が読めない・壊れている（新しい版・古い版とも）なら、ほかの退避から戻さずに止まる。
# meta.json の無い退避（書き換える前に止まった）は数えない
HOME="$TMP/order-badmeta" python3 - "$KIT" <<'PY' >"$TMP/order-badmeta.log" 2>&1
import argparse, os, runpy, signal, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
p = os.path.join(g["CLAUDE"], "order-badmeta.md")
g["write_text"](p, "owner")
dirs = []
for i in range(3):
    backup = g["Backup"]("update", {"brain": None, "from": 10, "to": 10})
    if i == 0:   # 最初の 1 件は古い版の kit の退避
        del backup.meta["seq"], backup.meta["legacy_before"]
    g["put"](p, "kit%d" % i, backup)
    dirs.append(backup.close())
good = {d: open(d + "/meta.json", "rb").read() for d in dirs}
for target in (dirs[2], dirs[0]):
    for raw in (b"{", b"", b"[]", b"{}", b"null", b'\xff\xfe', None,
                g["dump_json"](dict(g["load_json"](target + "/meta.json"), stamp=1)).encode(),
                g["dump_json"](dict(g["load_json"](target + "/meta.json"), created=5)).encode(),
                g["dump_json"](dict(g["load_json"](target + "/meta.json"), rolled_back="false")).encode(),
                g["dump_json"](dict(g["load_json"](target + "/meta.json"), rolled_back=1)).encode(), "dir"):
        if raw in (None, "dir"):   # meta.json か、退避のディレクトリそのものが読めない
            locked = target + "/meta.json" if raw is None else target
            os.chmod(locked, 0)
            if os.access(target + "/meta.json", os.R_OK):   # root では読めてしまうので飛ばす
                os.chmod(locked, 0o755)
                continue
        else:
            open(target + "/meta.json", "wb").write(raw)
        try:
            g["cmd_rollback"](argparse.Namespace(dry_run=False))
            raise AssertionError("rollback が止まらなかった: %s %r" % (target, raw))
        except SystemExit as e:
            assert e.code == 1, e.code
        os.chmod(target, 0o755)
        os.chmod(target + "/meta.json", 0o644)
        open(target + "/meta.json", "wb").write(good[target])
        assert g["read_text"](p) == "kit2"
        assert [open(d + "/meta.json", "rb").read() for d in dirs] == [good[d] for d in dirs]
# 退避の名前のファイル・行き先の無い symlink・ディレクトリへの symlink・FIFO や symlink の meta.json は、確かめられないので止まる
odd = os.path.join(g["CLAUDE"], "backup-brain-kit-29990101-000000")
def fifo_meta():
    os.makedirs(odd)
    os.mkfifo(odd + "/meta.json")   # 読むと止まる。開く前に止まる
def meta_link():
    os.makedirs(odd)
    os.symlink(dirs[2] + "/meta.json", odd + "/meta.json")
signal.alarm(20)
for make in (lambda: open(odd, "w").close(), lambda: os.symlink(odd + "-missing", odd), lambda: os.symlink(dirs[2], odd),
             fifo_meta, meta_link):
    make()
    g["Backup"]("update", {"brain": None, "from": 10, "to": 10})   # 新しい退避を作るときの見回りも開かずに飛ばす
    try:
        g["cmd_rollback"](argparse.Namespace(dry_run=False))
        raise AssertionError("rollback が止まらなかった: %s" % os.path.lexists(odd))
    except SystemExit as e:
        assert e.code == 1, e.code
    if os.path.isdir(odd) and not os.path.islink(odd):
        os.remove(odd + "/meta.json")
        os.rmdir(odd)
    else:
        os.remove(odd)
    assert g["read_text"](p) == "kit2"
    assert [open(d + "/meta.json", "rb").read() for d in dirs] == [good[d] for d in dirs]
signal.alarm(0)
os.makedirs(os.path.join(g["CLAUDE"], "backup-brain-kit-20000101-000000", "files"))   # meta の無い退避
g["cmd_rollback"](argparse.Namespace(dry_run=False))
assert g["read_text"](p) == "kit1"
PY
check "退避: 戻していない退避の meta.json が壊れていれば、ほかの退避から戻さずに止まる" test $? -eq 0
# 退避の名前の項目が外のディレクトリへの symlink（中の meta.json は正しい形で、通し番号がいちばん新しい）なら、
# 何も戻さずに止まる。持ち主のファイルも、外のディレクトリも変えない
HOME="$TMP/order-dirlink" python3 - "$KIT" "$TMP/order-dirlink-outside" <<'PY' >"$TMP/order-dirlink.log" 2>&1
import argparse, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
outside = sys.argv[2]
p = os.path.join(g["CLAUDE"], "order-dirlink.md")
g["write_text"](p, "owner")
backup = g["Backup"]("update", {"brain": None, "from": 10, "to": 10})
g["put"](p, "kit", backup)
real = backup.close()
# 外のディレクトリに、持ち主のファイルを別の中身で戻す退避を置く
stamp = "29990101-000000"
os.makedirs(os.path.join(outside, "files", os.path.dirname(p).lstrip(os.sep)))
g["write_text"](os.path.join(outside, "files", p.lstrip(os.sep)), "outside")
g["write_text"](os.path.join(outside, "meta.json"), g["dump_json"](dict(
    g["load_json"](real + "/meta.json"), stamp=stamp, seq=99, legacy_before={},
    created="2999-01-01T00:00:00.000000")))
os.symlink(outside, os.path.join(g["CLAUDE"], "backup-brain-kit-" + stamp))
def tree(top):
    out = {}
    for root, dirs, files in os.walk(top):
        for f in files:
            q = os.path.join(root, f)
            out[os.path.relpath(q, top)] = open(q, "rb").read()
    return out
before_outside, before_real = tree(outside), tree(real)
try:
    g["cmd_rollback"](argparse.Namespace(dry_run=False))
    raise AssertionError("rollback が止まらなかった: %r" % g["read_text"](p))
except SystemExit as e:
    assert e.code == 1, e.code
assert g["read_text"](p) == "kit", g["read_text"](p)
assert tree(outside) == before_outside
assert tree(real) == before_real
PY
check "退避: 退避の名前の項目が外のディレクトリへの symlink なら、何も戻さずに止まる（持ち主のファイルも外も変えない）" test $? -eq 0
# 新しい版で更新 → 古い版で更新（番号の無い退避）→ 新しい版で更新。最後のは戻せ、そのあとは決められないので止まる
HOME="$TMP/order-mixed" python3 - "$KIT" <<'PY' >"$TMP/order-mixed.log" 2>&1
import argparse, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
p = os.path.join(g["CLAUDE"], "order-mixed.md")
g["write_text"](p, "owner")
dirs = []
for i, who in enumerate(("new", "old", "new")):
    backup = g["Backup"]("update", {"brain": None, "from": 10, "to": 10})
    g["put"](p, "%s%d" % (who, i), backup)
    d = backup.close()
    if who == "old":   # 古い版の kit は seq も legacy_before も書かない
        meta = g["load_json"](d + "/meta.json")
        del meta["seq"], meta["legacy_before"]
        g["write_text"](d + "/meta.json", g["dump_json"](meta))
    dirs.append(d)
assert os.path.basename(dirs[1]) in g["load_json"](dirs[2] + "/meta.json")["legacy_before"]
g["cmd_rollback"](argparse.Namespace(dry_run=False))
assert g["read_text"](p) == "old1"
try:
    g["cmd_rollback"](argparse.Namespace(dry_run=False))
    raise AssertionError("rollback が止まらなかった")
except SystemExit as e:
    assert e.code == 1, e.code
assert g["read_text"](p) == "old1"
assert [g["load_json"](d + "/meta.json")["rolled_back"] for d in dirs] == [False, False, True]
PY
check "退避: 古い版の kit があとで作った番号の無い退避があれば、決められない所で止まる" test $? -eq 0
# 古い版の kit（ロックを取らない）が書いている途中に新しい版で更新し、そのあと古い版が書き足した。どれも戻さずに止まる
HOME="$TMP/order-interleave" python3 - "$KIT" <<'PY' >"$TMP/order-interleave.log" 2>&1
import argparse, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
x, y = os.path.join(g["CLAUDE"], "x.md"), os.path.join(g["CLAUDE"], "y.md")
g["write_text"](x, "ownerX")
g["write_text"](y, "ownerY")
old = g["Backup"]("update", {"brain": None, "from": 9, "to": 9})
del old.meta["seq"], old.meta["legacy_before"]   # 古い版の kit の退避
g["put"](x, "oldX", old)
new = g["Backup"]("update", {"brain": None, "from": 10, "to": 10})
g["put"](x, "newX", new)
g["put"](y, "newY", new)
new.close()
g["put"](y, "oldY", old)
old.close()
try:
    g["cmd_rollback"](argparse.Namespace(dry_run=False))
    raise AssertionError("rollback が止まらなかった")
except SystemExit as e:
    assert e.code == 1, e.code
assert (g["read_text"](x), g["read_text"](y)) == ("newX", "oldY")
assert not g["load_json"](new.dir + "/meta.json")["rolled_back"]
PY
check "退避: 古い版の kit が新しい版の更新をまたいで書き足した退避があれば、何も戻さずに止まる" test $? -eq 0
# 書き換える処理は同じ HOME で 1 つずつ。動いている間の --rollback は何も変えずに止まり、終われば戻せる
H="$TMP/order-lock"
HOME="$H" python3 - "$KIT" <<'PY' >"$TMP/order-lock.log" 2>&1
import os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["cmd_rollback"].__globals__
p = os.path.join(g["CLAUDE"], "order-lock.md")
g["write_text"](p, "owner")
backup = g["Backup"]("update", {"brain": None, "from": 10, "to": 10})
g["put"](p, "kit", backup)
backup.close()
PY
python3 - "$H" "$TMP/order-lock.ready" "$TMP/order-lock.stop" <<'PY' >>"$TMP/order-lock.log" 2>&1 &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
end = time.time() + 60
while not os.path.exists(sys.argv[3]) and time.time() < end:
    time.sleep(0.05)
PY
holder=$!
i=0
while [ ! -e "$TMP/order-lock.ready" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
before="$(snap "$H")"
HOME="$H" python3 "$KIT/lib/kit.py" rollback >"$H.locked" 2>&1
rc=$?
check "同時実行: 別の brain-kit が動いている間の --rollback は 1 で止まる" test "$rc" -eq 1
check "同時実行: 止まった理由を出す" grep -q '別の brain-kit' "$H.locked"
check "同時実行: 止まった --rollback は何も変えない" test "$before" = "$(snap "$H")"
touch "$TMP/order-lock.stop"
wait "$holder"
HOME="$H" python3 "$KIT/lib/kit.py" rollback >"$H.unlocked" 2>&1
check "同時実行: 終わったあとの --rollback は戻せる" test "$(cat "$H/.claude/order-lock.md")" = owner
# ロックが確かめられない（flock の失敗・fcntl が無い）ときは、書き換える 5 つとも何もせずに止まる
mkdir -p "$TMP/order-lockfail"
HOME="$TMP/order-lockfail" python3 - "$KIT" <<'PY' >"$TMP/order-lockfail.log" 2>&1
import builtins, errno, fcntl, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["main"].__globals__
ran = []
for c in ("install", "update", "resolve", "uninstall", "rollback"):
    g["cmd_" + c] = lambda args, c=c: ran.append(c)
def broken(code):
    def flock(fd, op):
        raise OSError(code, os.strerror(code))
    return flock
real_flock, real_import = fcntl.flock, builtins.__import__
def no_fcntl(name, *a, **kw):
    if name == "fcntl":
        raise ImportError(name)
    return real_import(name, *a, **kw)
try:
    for how in ("ENOLCK", "EOPNOTSUPP", "EIO", "no-fcntl"):
        if how == "no-fcntl":
            fcntl.flock, builtins.__import__ = real_flock, no_fcntl
        else:
            fcntl.flock = broken(getattr(errno, how))
        for c in ("install", "update", "resolve", "uninstall", "rollback"):
            try:
                g["main"]([c])
                raise AssertionError("止まらなかった: %s %s" % (how, c))
            except SystemExit as e:
                assert e.code == 1, (how, c, e.code)
finally:
    fcntl.flock, builtins.__import__ = real_flock, real_import
assert ran == [], ran
for c in ("install", "update", "resolve", "uninstall", "rollback", "doctor"):
    g["cmd_" + c] = lambda args, c=c: ran.append(c)
# ロックが取れれば動く。--doctor はロックを取らないので、ロックを持ったままでも動く
g["main"](["rollback"])
g["main"](["doctor"])
assert ran == ["rollback", "doctor"], ran
PY
check "同時実行: ロックが確かめられなければ、書き換える処理は何もせずに止まる" test $? -eq 0
HOME="$TMP/collision-with" python3 - "$NEXT" <<'PY' >"$TMP/no-read.log" 2>&1
import builtins, os, runpy, sys
ns = runpy.run_path(sys.argv[1] + "/lib/kit.py")
g = ns["build_plan"].__globals__
brain = os.path.join(g["HOME"], "brain")
cfg = g["load_json"](g["config_path"](brain))
manifests = g["load_manifests"](brain)
# extra は kit の一覧にあるが、所有ディレクトリとして未登録に戻して確かめる。
del manifests["claude"]["files"][".claude/skills/extra/SKILL.md"]
original = builtins.open
forbidden = [os.path.join(g["CLAUDE"], "skills", "extra"), os.path.join(g["CLAUDE"], "skills", "extra-own"),
             os.path.join(g["CLAUDE"], "agents"), os.path.join(brain, "Aoi", "00_核.md")]
def guarded(path, *args, **kw):
    assert not any(str(path) == p or str(path).startswith(p + os.sep) for p in forbidden), path
    return original(path, *args, **kw)
builtins.open = guarded
import io
old_io = io.open
io.open = guarded
try:
    items = g["build_plan"](cfg, manifests, False, {})
    assert next(i for i in items if i.dst.endswith("/extra/SKILL.md")).state == "collision"
    inv = g["owner_inventory"](cfg, manifests, items, manifests["claude"]["settings"])
    assert "extra-own" in inv["skills"]
finally:
    builtins.open = original
    io.open = old_io
PY
check "一覧と重なり: 所有ファイルの中身を開かない" test $? -eq 0

# ------------------------------------------------------------------ 20. brain と実行ファイル・相対パス
section "brain と実行ファイルの解消"
printf '\n次の版の規約。\n' >>"$NEXT/brain-template/README.md"
printf '\n# 次の版のフック。\n' >>"$NEXT/claude/hooks/session-end-brain.sh"
for area in brain exec; do
  H="$TMP/resolve-$area"
  mkdir -p "$H"
  new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
  if [ "$area" = brain ]; then rel=brain/README.md; else rel=.claude/hooks/session-end-brain.sh; fi
  printf '\n# 持ち主の追記。\n' >>"$H/$rel"
  next_update "$H" >"$H.up" 2>&1
  before="$(snap "$H")"
  c0="$(commits "$H")"
  cp "$H/$rel.new" "$H/result.txt"
  printf '\n# 持ち主の追記。\n' >>"$H/result.txt"
  if [ "$area" = brain ]; then
    # shellcheck disable=SC2088  # kit.py が ~ を展開することを確かめる
    HOME="$H/." bash "$NEXT/install.sh" --resolve '~/brain/README.md' --from "$H/result.txt" >"$H.resolve" 2>&1
  else
    # HOME を symlink 越しに渡し、cwd は実体の側（macOS の /var と /private/var と同じずれ）
    ln -s "$H" "$H-link"
    (cd "$H" && HOME="$H-link" bash "$NEXT/install.sh" --resolve "$rel" --from result.txt) >"$H.resolve" 2>&1
  fi
  check "解消 $area: 正規化した HOME と対象で実行が 0" test $? -eq 0
  check "解消 $area: 内容が一致" cmp "$H/result.txt" "$H/$rel"
  if [ "$area" = brain ]; then
    check "解消 brain: コミットが 1 つ増える" test "$(commits "$H")" -eq "$((c0 + 1))"
    check "解消 brain: base は kit の版" grep -q '次の版の規約' "$H/brain/.brain-kit/base/README.md"
  else
    check "解消 exec: 実行権限を保つ" test -x "$H/$rel"
  fi
  new "$H" --rollback >"$H.rb" 2>&1
  check "解消 $area: rollback でファイル・.new・base・manifest を戻す" test "$before" = "$(snap "$H")"
done

# ------------------------------------------------------------------ 19. 解消の途中で落ちたとき・版の記録が無い入れ方
section "解消の途中失敗と版の記録なし"
H="$TMP/resolve-crash"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
target="$H/.claude/skills/mio/SKILL.md"
python3 - "$target" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("---", "---\n持ち主の行。", 1)
open(p, "w").write(s)
PY
next_update "$H" >"$H.up" 2>&1
after_update="$(snap "$H")"
cat "$target.new" >"$H.merged"
printf '持ち主の追記。\n' >>"$H.merged"
# manifest を書く直前で落とす（対象・.new・base は書き換え済み）
HOME="$H" python3 - "$NEXT" "$target" "$H.merged" <<'PY'
import runpy, sys
kit, target, merged = sys.argv[1:]
ns = runpy.run_path(kit + "/lib/kit.py")
g = ns["cmd_resolve"].__globals__
orig = g["put"]
def put(path, text, backup, exe=False):
    if path == g["CLAUDE_MANIFEST"]:
        raise OSError("書けない（テスト）")
    return orig(path, text, backup, exe)
g["put"] = put
try:
    ns["main"](["resolve", "--target", target, "--from", merged])
except OSError:
    pass
else:
    sys.exit(1)
PY
check "途中失敗: 解消は途中で止まる" test $? -eq 0
check "途中失敗: 対象は書き換わっている" cmp "$H.merged" "$target"
new "$H" --rollback >"$H.rb" 2>&1
check "途中失敗: rollback は途中の解消を先に戻す" test "$after_update" = "$(snap "$H")"
check "途中失敗: .new も戻る" test -f "$target.new"

H="$TMP/resolve-legacy"
old_install "$V9" "$H" --partner 葵 --dev 蓮 --yes
before="$(snap "$H")"
backups="$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"
HOME="$H" bash "$KIT/install.sh" --resolve "$H/.claude/hooks/session-end-brain.sh" >"$H.resolve" 2>&1
check "版の記録なし: 解消は終了 2" test $? -eq 2
check "版の記録なし: 先に --update を案内" grep -q -- '--update' "$H.resolve"
check "版の記録なし: 何も書かない" test "$before" = "$(snap "$H")"
check "版の記録なし: 退避も作らない" test "$backups" = "$(find "$H/.claude" -name 'backup-brain-kit-*' | sort)"

# ------------------------------------------------------------------ 20. 手で消した settings の項目の解消・退避の meta の書きかけ
section "手で消した settings の項目と退避の meta"
H="$TMP/settings-deleted"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
m = json.load(open(h + "/.claude/brain-kit/manifest.json"))
del m["settings"]["enabledPlugins"]["pr-review-toolkit@claude-plugins-official"]
json.dump(m, open(h + "/.claude/brain-kit/manifest.json", "w"), ensure_ascii=False, indent=2, sort_keys=True)
s = json.load(open(h + "/.claude/settings.json"))
s["enabledPlugins"]["pr-review-toolkit@claude-plugins-official"] = False
json.dump(s, open(h + "/.claude/settings.json", "w"), ensure_ascii=False, indent=2)
PY
new "$H" --update --no-worktrees >"$H.up" 2>&1
check "手で消した項目: 未登録の違いは衝突" grep -q 'settings.json の衝突: 1 件' "$H.up"
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
s = json.load(open(h + "/.claude/settings.json"))
del s["enabledPlugins"]["pr-review-toolkit@claude-plugins-official"]
json.dump(s, open(h + "/.claude/settings.json", "w"), ensure_ascii=False, indent=2)
PY
cp "$H/.claude/settings.json" "$H.edited"
new "$H" --update --no-worktrees >"$H.up-again" 2>&1
check "手で消した項目: 解消前の再更新でも足し直さない" cmp "$H.edited" "$H/.claude/settings.json"
check "手で消した項目: 解消前の再更新でも衝突を出す" grep -q 'settings.json の衝突: 1 件' "$H.up-again"
new "$H" --resolve "$H/.claude/settings.json" >"$H.resolve" 2>&1
check "手で消した項目: 解消が 0" test $? -eq 0
new "$H" --update --no-worktrees >"$H.up2" 2>&1
check "手で消した項目: 次の更新で足し直さない" cmp "$H.edited" "$H/.claude/settings.json"
check "手で消した項目: 次の更新で衝突しない" sh -c "! grep -q 'settings.json の衝突' '$H.up2'"

# 解消の途中で meta.json の書き直しが書きかけで落ちても、前の meta は残り、--rollback が拾う
H="$TMP/resolve-journal"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
target="$H/.claude/skills/mio/SKILL.md"
python3 - "$target" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("---", "---\n持ち主の行。", 1)
open(p, "w").write(s)
PY
next_update "$H" >"$H.up" 2>&1
after_update="$(snap "$H")"
cat "$target.new" >"$H.merged"
printf '持ち主の追記。\n' >>"$H.merged"
HOME="$H" python3 - "$NEXT" "$target" "$H.merged" <<'PY'
import io, runpy, sys
kit, target, merged = sys.argv[1:]
ns = runpy.run_path(kit + "/lib/kit.py")
g = ns["cmd_resolve"].__globals__
real = io.open
count = [0]
def fake_open(path, mode="r", *a, **kw):
    if "w" in mode and "meta.json" in str(path):
        count[0] += 1
        if count[0] == 2:
            real(path, mode, *a, **kw).close()   # 開いて中身を消したところで落ちる
            raise OSError("書きかけで落ちた（テスト）")
    return real(path, mode, *a, **kw)
g["io"].open = fake_open
try:
    ns["main"](["resolve", "--target", target, "--from", merged])
except OSError:
    pass
else:
    sys.exit(1)
finally:
    g["io"].open = real
PY
check "meta の書きかけ: 解消は途中で止まる" test $? -eq 0
check "meta の書きかけ: 対象は書き換わっている" cmp "$H.merged" "$target"
new "$H" --rollback >"$H.rb" 2>&1
check "meta の書きかけ: rollback は途中の解消を戻す" test "$after_update" = "$(snap "$H")"

# 解消待ちの項目は、記録の値に戻しても・command の変更でも・--codex 無しでも、解消するまで動かさない
python3 - "$KIT" "$TMP" <<'PY'
import json, os, runpy, sys
kit, tmp = sys.argv[1:]
ns = runpy.run_path(kit + "/lib/kit.py")
plan, ssha = ns["plan_settings"], ns["settings_sha"]
g = plan.__globals__
k = tmp + "/pending-cases"
os.makedirs(k + "/claude")
g["KIT"], g["CLAUDE"] = k, k + "/claude"
def write(name, obj):
    with open(k + "/claude/" + name, "w") as f:
        json.dump(obj, f)
def hook(cmd, n):
    return {"hooks": [{"type": "command", "command": cmd, "timeout": n}]}
write("settings.codex.json", {})
# 記録の値（10）に戻した解消待ちのフックを kit の 20 で上げない
write("settings.snippet.json", {"hooks": {"Stop": [hook("echo kit", 20)]}})
write("settings.json", {"hooks": {"Stop": [hook("echo kit", 10)]}})
r = plan(False, {"settings": {"hooks.Stop": {"echo kit": ssha(hook("echo kit", 10))}},
                 "settings_conflicts": [["hooks.Stop", "echo kit"]]})
assert not r["changed"] and [c["entry"] for c in r["conflict"]] == [("hooks.Stop", "echo kit")], r
# command の変更でも、解消待ちなら置き換えない
write("settings.snippet.json", {"hooks": {"Stop": [hook("echo new", 10)]}})
write("settings.json", {"hooks": {"Stop": [hook("echo old", 10)]}})
r = plan(False, {"settings": {"hooks.Stop": {"echo old": ssha(hook("echo old", 10))}},
                 "settings_conflicts": [["hooks.Stop", "echo old"], ["hooks.Stop", "echo new"]]})
assert not r["changed"] and len(r["conflict"]) == 2, r
# kit から外れた解消待ちの項目は消さない
write("settings.snippet.json", {})
r = plan(False, {"settings": {"hooks.Stop": {"echo old": ssha(hook("echo old", 10))}},
                 "settings_conflicts": [["hooks.Stop", "echo old"]]})
assert not r["changed"] and r["keep"] and "hooks.Stop" not in r["record"], r
# --codex 無しでも、解消待ちの Codex の項目は kit の項目として扱い、手で消したものを足さない
write("settings.codex.json", {"enabledPlugins": {"codex@example-market": True}})
write("settings.json", {})
r = plan(False, {"settings": {}, "settings_conflicts": [["enabledPlugins", "codex@example-market"]]})
assert not r["changed"] and ("enabledPlugins", "codex@example-market") in r["theirs"], r
assert [c["entry"] for c in r["conflict"]] == [("enabledPlugins", "codex@example-market")], r
# 未登録の解消待ちのフックを持ち主が消したあと、kit が command を変えても新しい command を足さない
write("settings.codex.json", {})
write("settings.snippet.json", {"hooks": {"Stop": [hook("echo new", 10)]}})
write("settings.json", {})
r = plan(False, {"settings": {}, "settings_conflicts": [["hooks.Stop", "echo old"]]})
assert not r["changed"] and sorted(c["entry"] for c in r["conflict"]) == [("hooks.Stop", "echo new"), ("hooks.Stop", "echo old")], r
PY
check "解消待ち: 記録の値に戻しても・command 変更でも・外れても・--codex 無しでも動かさない" test $? -eq 0

# settings.json が無ければ --resolve で作らない（書きかけの新しいファイルを残さない）
H="$TMP/settings-absent"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
rm "$H/.claude/settings.json"
printf '{}\n' >"$H.merged.json"
before="$(snap "$H")"
new "$H" --resolve "$H/.claude/settings.json" --from "$H.merged.json" >"$H.resolve" 2>&1
check "settings.json が無い: 解消は終了 2" test $? -eq 2
check "settings.json が無い: 作らない" test "$before" = "$(snap "$H")"

# brain のファイルを今の内容のまま解消したときも、その中身をコミットに入れる
for method in inplace keep; do
  H="$TMP/resolve-brain-$method"
  mkdir -p "$H"
  new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
  printf '\n# 持ち主の追記。\n' >>"$H/brain/README.md"
  next_update "$H" >"$H.up" 2>&1
  printf '\n# 解消のときの持ち主の追記。\n' >>"$H/brain/README.md"
  if [ "$method" = keep ]; then
    HOME="$H" bash "$NEXT/install.sh" --resolve --keep "$H/brain/README.md" >"$H.resolve" 2>&1
  else
    HOME="$H" bash "$NEXT/install.sh" --resolve "$H/brain/README.md" >"$H.resolve" 2>&1
  fi
  check "解消 brain $method: 実行が 0" test $? -eq 0
  check "解消 brain $method: 受け入れた中身がコミットに入る" sh -c "git -C '$H/brain' show HEAD:README.md | cmp - '$H/brain/README.md'"
  check "解消 brain $method: 作業ツリーに残りが無い" test -z "$(git -C "$H/brain" status --porcelain)"
done

# --from で kit の項目を消して解消したら、次の更新で足し直さない（kit の新しい版で増え、まだ記録の無い項目でも）
NEXTS2="$TMP/kit-next-s2"
mkdir -p "$NEXTS2"
(cd "$NEXTS" && tar cf - .) | (cd "$NEXTS2" && tar xf -)
python3 - "$NEXTS2" <<'PY'
import json, sys
p = sys.argv[1] + "/claude/settings.snippet.json"
s = json.load(open(p))
s["enabledPlugins"]["later-plugin@example-market"] = True
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
PY
H="$TMP/settings-from-delete"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
s = json.load(open(h + "/.claude/settings.json"))
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 30                 # 衝突を作る
s["enabledPlugins"]["later-plugin@example-market"] = True          # 持ち主が先に入れていた plugin
json.dump(s, open(h + "/.claude/settings.json", "w"), ensure_ascii=False, indent=2)
PY
HOME="$H" bash "$NEXTS/install.sh" --update --no-worktrees >"$H.up" 2>&1
check "--from で消した項目: 衝突がある" grep -q 'settings.json の衝突' "$H.up"
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
s = json.load(open(h + "/.claude/settings.json"))
del s["enabledPlugins"]["later-plugin@example-market"]
json.dump(s, open(h + ".merged.json", "w"), ensure_ascii=False, indent=2)
PY
HOME="$H" bash "$NEXTS2/install.sh" --resolve "$H/.claude/settings.json" --from "$H.merged.json" >"$H.resolve" 2>&1
check "--from で消した項目: 解消が 0" test $? -eq 0
HOME="$H" bash "$NEXTS2/install.sh" --update --no-worktrees >"$H.up2" 2>&1
check "--from で消した項目: 次の更新で足し直さない" cmp "$H.merged.json" "$H/.claude/settings.json"

# settings.json が symlink なら、--from では指す先に書かない。その場で直した形・--keep は記録だけする
H="$TMP/settings-link"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
s = json.load(open(h + "/.claude/settings.json"))
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 30
json.dump(s, open(h + "/.claude/settings.json", "w"), ensure_ascii=False, indent=2)
PY
HOME="$H" bash "$NEXTS/install.sh" --update --no-worktrees >"$H.up" 2>&1
mkdir -p "$H/brain/dotfiles"
mv "$H/.claude/settings.json" "$H/brain/dotfiles/settings.json"
ln -s "$H/brain/dotfiles/settings.json" "$H/.claude/settings.json"
printf '{}\n' >"$H.merged.json"
before="$(snap "$H")"
HOME="$H" bash "$NEXTS/install.sh" --resolve "$H/.claude/settings.json" --from "$H.merged.json" >"$H.resolve" 2>&1
check "settings の symlink: --from は終了 2" test $? -eq 2
check "settings の symlink: --from は指す先に書かない" test "$before" = "$(snap "$H")"
cp "$H/brain/dotfiles/settings.json" "$H.target-before"
HOME="$H" bash "$NEXTS/install.sh" --resolve --keep "$H/.claude/settings.json" >"$H.keep" 2>&1
check "settings の symlink: --keep は 0" test $? -eq 0
check "settings の symlink: --keep は指す先をそのまま" cmp "$H.target-before" "$H/brain/dotfiles/settings.json"
check "settings の symlink: symlink のまま" test -L "$H/.claude/settings.json"

# --from で kit の項目を前の値に戻して解消したら、次の更新で kit の値に戻さない
# （記録は前の版の A、今は手で新しい版の B、kit も B、解消結果は A）
NEXTS3="$TMP/kit-next-s3"
mkdir -p "$NEXTS3"
(cd "$KIT" && git ls-files --cached --others --exclude-standard -z | xargs -0 tar cf -) | (cd "$NEXTS3" && tar xf -)
python3 - "$NEXTS3" <<'PY'
import json, sys
p = sys.argv[1] + "/claude/settings.snippet.json"
s = json.load(open(p))
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 20                 # Stop だけ変える版
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
PY
H="$TMP/settings-from-revert"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
python3 - "$H" "$NEXTS" <<'PY'
import json, sys
h, nexts = sys.argv[1:]
s = json.load(open(h + "/.claude/settings.json"))
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 30                 # 衝突（解消の入口）
s["statusLine"] = json.load(open(nexts + "/claude/settings.snippet.json"))["statusLine"]   # 手で新しい版の B に
json.dump(s, open(h + "/.claude/settings.json", "w"), ensure_ascii=False, indent=2)
PY
HOME="$H" bash "$NEXTS3/install.sh" --update --no-worktrees >"$H.up" 2>&1
check "--from で戻した項目: 衝突がある" grep -q 'settings.json の衝突' "$H.up"
python3 - "$H" "$KIT" <<'PY'
import json, sys
h, kit = sys.argv[1:]
s = json.load(open(h + "/.claude/settings.json"))
s["statusLine"] = json.load(open(kit + "/claude/settings.snippet.json"))["statusLine"]   # 前の版の A に戻す
json.dump(s, open(h + ".merged.json", "w"), ensure_ascii=False, indent=2)
PY
HOME="$H" bash "$NEXTS/install.sh" --resolve "$H/.claude/settings.json" --from "$H.merged.json" >"$H.resolve" 2>&1
check "--from で戻した項目: 解消が 0" test $? -eq 0
HOME="$H" bash "$NEXTS/install.sh" --update --no-worktrees >"$H.up2" 2>&1
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
assert json.load(open(h + "/.claude/settings.json"))["statusLine"] == json.load(open(h + ".merged.json"))["statusLine"]
PY
check "--from で戻した項目: 次の更新で kit の値に戻さない" test $? -eq 0

# 新しい kit で外れたフックを --from で残すと決めたら、次の更新で消さない
H="$TMP/settings-from-retired"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --yes --no-worktrees >"$H.install" 2>&1
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
s = json.load(open(h + "/.claude/settings.json"))
s["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 30                 # 衝突（解消の入口）
s["hooks"]["TeammateIdle"][0]["hooks"][0]["timeout"] = 30         # 持ち主だけの変更
json.dump(s, open(h + "/.claude/settings.json", "w"), ensure_ascii=False, indent=2)
PY
HOME="$H" bash "$NEXTS3/install.sh" --update --no-worktrees >"$H.up" 2>&1
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
s = json.load(open(h + "/.claude/settings.json"))
s["hooks"]["TeammateIdle"][0]["hooks"][0]["timeout"] = 10         # 入れたときの値で残すと決めた
json.dump(s, open(h + ".merged.json", "w"), ensure_ascii=False, indent=2)
PY
HOME="$H" bash "$NEXTS/install.sh" --resolve "$H/.claude/settings.json" --from "$H.merged.json" >"$H.resolve" 2>&1
check "--from で残した外れた項目: 解消が 0" test $? -eq 0
HOME="$H" bash "$NEXTS/install.sh" --update --no-worktrees >"$H.up2" 2>&1
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
assert json.load(open(h + "/.claude/settings.json"))["hooks"]["TeammateIdle"] == json.load(open(h + ".merged.json"))["hooks"]["TeammateIdle"]
PY
check "--from で残した外れた項目: 次の更新で消さない" test $? -eq 0

# ------------------------------------------------------------------ uninstall（brain は全部そのまま）
section "uninstall と rollback・再導入"
H="$TMP/uninstall"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --yes >"$H.log" 2>&1
check "uninstall 用の新規導入" test $? -eq 0
printf '\n持ち主の追記\n' >>"$H/.claude/CLAUDE.md"
mkdir -p "$H/.claude/skills/mine"
printf 'owner skill\n' >"$H/.claude/skills/mine/SKILL.md"
printf 'owner memory\n' >"$H/brain/Aoi/owner.md"
git -C "$H/brain" add Aoi/owner.md
git -C "$H/brain" commit -qm 'owner memory'
python3 - "$H" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], '.claude/settings.json')
s = json.load(open(p))
s['hooks']['SessionEnd'][0]['timeout'] = 987
s['hooks']['Stop'].append({'hooks': [{'type': 'command', 'command': 'echo owner'}]})
open(p, 'w').write(json.dumps(s, ensure_ascii=False, indent=2) + '\n')
PY
chmod 600 "$H/.claude/settings.json"
before="$(snap "$H")"; own="$(owner_snap "$H" Aoi)"
brain_before="$(snap "$H" | grep ' brain/')"
head_before="$(git -C "$H/brain" rev-parse HEAD)"
cat "$H/.claude/settings.json" >"$H.settings-before"
backups_before="$(find "$H/.claude" -type d -name 'backup-brain-kit-*' | sort)"
new "$H" --uninstall --dry-run >"$H.dry" 2>&1
check "uninstall dry-run が 0" test $? -eq 0
check "dry-run は何も書かない" test "$before" = "$(snap "$H")"
check "dry-run は退避を作らない" test "$backups_before" = "$(find "$H/.claude" -type d -name 'backup-brain-kit-*' | sort)"
check "dry-run は編集済み CLAUDE.md を「残すもの」に出す" sh -c "awk '/^残すもの/{f=1;next} /^[^ ]/{f=0} f' '$H.dry' | grep -qF '.claude/CLAUDE.md'"
check "dry-run は編集済み CLAUDE.md を「消すもの」に出さない" sh -c "! awk '/^消すもの/{f=1;next} /^[^ ]/{f=0} f' '$H.dry' | grep -v '/base/' | grep -qF '.claude/CLAUDE.md'"
new "$H" --uninstall </dev/null >"$H.no" 2>&1
check "非対話は --yes が必要（exit 2）" test $? -eq 2
check "確認前は変更なし" test "$before" = "$(snap "$H")"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "uninstall が 0" test $? -eq 0
for s in aoi ren mio sora setup grilling; do check "kit skill $s を削除" test ! -e "$H/.claude/skills/$s/SKILL.md"; done
check "残した SessionEnd の項目が呼ぶ session-end-brain.sh は残す" test -f "$H/.claude/hooks/session-end-brain.sh"
check "uninstall の出力に「残すフックが使うため」" grep -q '残すフックが使うため' "$H.un"
check "残すスクリプトが呼ぶ brain-digest.js も残す" test -f "$H/.claude/hooks/brain-digest.js"
for p in brain-kit/bin/start-all brain-kit/bin/heavy-lock brain-kit/manifest.json brain-kit/base brain-kit/bin/start-aoi brain-kit/bin/start-ren brain-kit/bin/start-mio brain-kit/bin/start-sora; do
  check "$p を削除" test ! -e "$H/.claude/$p"
done
check "編集した CLAUDE.md を保持" grep -q '持ち主の追記' "$H/.claude/CLAUDE.md"
check "持ち主 skill を保持" test -f "$H/.claude/skills/mine/SKILL.md"
python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['hooks']['SessionEnd'][0]['timeout'] == 987
assert s['hooks']['Stop'] == [{'hooks': [{'type': 'command', 'command': 'echo owner'}]}]
assert 'statusLine' not in s
assert not any('pr-review-toolkit' in k for k in s.get('enabledPlugins', {}))
assert 'permissions' in s
PY
check "settings は持ち主の hook・変更・permissions を保ち kit の項目だけ削除" test $? -eq 0
check "settings の権限（600）を保つ" python3 -c 'import os, sys; sys.exit(os.stat(sys.argv[1]).st_mode & 0o777 != 0o600)' "$H/.claude/settings.json"
check "settings の一時ファイルを残さない" sh -c "! ls -a '$H/.claude' | grep -q '^\.settings\.json\.'"
check "持ち主の brain は同一" test "$own" = "$(owner_snap "$H" Aoi)"
check "brain 全体（kit の記録も）は同一" test "$brain_before" = "$(snap "$H" | grep ' brain/')"
check "brain HEAD は同一" test "$head_before" = "$(git -C "$H/brain" rev-parse HEAD)"
for w in ren mio sora; do check "worktree $w を保持" test -d "$H/brain-$w"; done
new "$H" --rollback >"$H.rb" 2>&1
check "uninstall の rollback が 0" test $? -eq 0
check "rollback で全バイトと実行権限が戻る" test "$before" = "$(snap "$H")"
check "settings のバイトが戻る" cmp -s "$H.settings-before" "$H/.claude/settings.json"
new "$H" --uninstall --yes >"$H.un2" 2>&1
check "再 uninstall が 0" test $? -eq 0
new "$H" --update --no-worktrees >"$H.reinstall" 2>&1
check "update で再導入できる" test $? -eq 0
for s in aoi ren mio sora setup grilling; do check "再導入 skill $s" test -f "$H/.claude/skills/$s/SKILL.md"; done

section "uninstall の範囲と symlink"
printf 'outside\n' >"$H/outside.txt"
python3 - "$H" <<'PY'
import hashlib, json, os, sys
h = sys.argv[1]
p = os.path.join(h, '.claude/brain-kit/manifest.json')
m = json.load(open(p))
sha = hashlib.sha256(open(os.path.join(h, 'outside.txt'), 'rb').read()).hexdigest()
for key in ('../outside.txt', 'outside.txt'):
    m['files'][key] = {'sha': sha}
open(p, 'w').write(json.dumps(m))
PY
mv "$H/.claude/settings.json" "$H/settings-target.json"
cat "$H/settings-target.json" >"$H.settings-target-before"
ln -s "$H/settings-target.json" "$H/.claude/settings.json"
new "$H" --uninstall --yes >"$H.edge" 2>&1
check "symlink があっても uninstall が 0" test $? -eq 0
check "範囲外のファイルを保持" test -f "$H/outside.txt"
check "settings は symlink のまま" test -L "$H/.claude/settings.json"
check "symlink の参照先は同一" cmp -s "$H.settings-target-before" "$H/settings-target.json"
H="$TMP/uninstall-empty"; mkdir -p "$H"
new "$H" --uninstall --yes >"$H.log" 2>&1
check "manifest が無ければ失敗" test $? -ne 0

section "uninstall の .new・衝突資料・不正な settings"
H="$TMP/uninstall-state"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --yes >"$H.log" 2>&1
cp "$H/.claude/skills/aoi/SKILL.md" "$H/.claude/skills/aoi/SKILL.md.new"
printf 'owner merge\n' >"$H/.claude/skills/ren/SKILL.md.new"
mkdir -p "$H/.claude/brain-kit/conflicts/test"
printf 'merged\n' >"$H/.claude/brain-kit/conflicts/test/merged.md"
printf 'state\n' >"$H/.claude/brain-kit/owner.lock"
cp "$H/.claude/settings.json" "$H.settings-good"
printf '{broken' >"$H/.claude/settings.json"
before="$(snap "$H")"
backups_before="$(find "$H/.claude" -type d -name 'backup-brain-kit-*' | sort)"
new "$H" --uninstall --yes >"$H.bad" 2>&1
check "不正 JSON は失敗" test $? -ne 0
check "不正 JSON ならファイルを削除しない" test "$before" = "$(snap "$H")"
check "不正 JSON なら退避も作らない" test "$backups_before" = "$(find "$H/.claude" -type d -name 'backup-brain-kit-*' | sort)"
cp "$H.settings-good" "$H/.claude/settings.json"
python3 - "$H" <<'PY'
import hashlib, json, os, sys
h = sys.argv[1]
p = os.path.join(h, '.claude/brain-kit/manifest.json')
m = json.load(open(p))
# 範囲内に見えても参照先が brain や退避なら外さない。
os.symlink(os.path.join(h, 'brain/Aoi'), os.path.join(h, '.claude/owner-link'))
backups = [d for d in os.listdir(os.path.join(h, '.claude')) if d.startswith('backup-brain-kit-')]
b = os.path.join(h, '.claude', backups[0])
open(os.path.join(b, 'keep.txt'), 'w').write('backup')
os.symlink(b, os.path.join(h, '.claude/backup-link'))
for key in ('.claude/owner-link/00_核.md', '.claude/backup-link/keep.txt'):
    m['files'][key] = {'sha': hashlib.sha256(open(os.path.join(h, key), 'rb').read()).hexdigest()}
entry = ['statusLine', '']
m.setdefault('settings_conflicts', []).append(entry)
open(p, 'w').write(json.dumps(m))
PY
before="$(snap "$H")"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "状態付き uninstall が 0" test $? -eq 0
check "kit と同一の .new は削除" test ! -e "$H/.claude/skills/aoi/SKILL.md.new"
check "編集した .new を保持" grep -q 'owner merge' "$H/.claude/skills/ren/SKILL.md.new"
check "衝突資料を保持" test -f "$H/.claude/brain-kit/conflicts/test/merged.md"
check "未登録の状態を保持" test -f "$H/.claude/brain-kit/owner.lock"
check "brain を指すディレクトリ symlink の中は削除しない" test -f "$H/.claude/owner-link/00_核.md"
check "退避を指すディレクトリ symlink の中は削除しない" test -f "$H/.claude/backup-link/keep.txt"
check "未変更でも settings の衝突項目は残す" grep -q 'statusLine' "$H/.claude/settings.json"
new "$H" --rollback >"$H.rb" 2>&1
check "状態・.new も rollback で戻る" test "$before" = "$(snap "$H")"

section "uninstall の確認中の変更・base・戻すときの作り直し"
H="$TMP/uninstall-race"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
printf 'owner note\n' >"$H/.claude/brain-kit/base/owner-note.md"
printf '\n持ち主の追記\n' >>"$H/.claude/brain-kit/base/.claude/skills/ren/SKILL.md"
# 確認を待つ間に settings.json が変わったら、何も変えずに止まる
backups_before="$(find "$H/.claude" -type d -name 'backup-brain-kit-*' | sort)"
{ sleep 3; printf '{"owner": true}\n' >"$H/.claude/settings.json"; echo y; } |
  BRAIN_KIT_INTERACTIVE=1 HOME="$H" bash "$KIT/install.sh" --uninstall >"$H.race1" 2>&1
check "確認中に settings が変わると止まる" test $? -ne 0
check "止まったとき settings は持ち主の書いたまま" grep -q '"owner": true' "$H/.claude/settings.json"
check "止まったとき kit の skill は消えていない" test -f "$H/.claude/skills/aoi/SKILL.md"
check "止まったとき退避を作らない" test "$backups_before" = "$(find "$H/.claude" -type d -name 'backup-brain-kit-*' | sort)"
# 確認を待つ間に kit の skill を持ち主が書き換えたら、計画が変わったので何も消さずに止まる
{ sleep 3; printf 'edited while waiting\n' >>"$H/.claude/skills/mio/SKILL.md"; echo y; } |
  BRAIN_KIT_INTERACTIVE=1 HOME="$H" bash "$KIT/install.sh" --uninstall >"$H.race2" 2>&1
check "確認中の書き換え: 計画が変わったので止まる" test $? -ne 0
check "確認中の書き換え: ほかの kit の skill も消していない" test -f "$H/.claude/skills/aoi/SKILL.md"
# もう一度（新しい計画で）外す。書き換えた skill は「持ち主が変えた」として残る
new "$H" --uninstall --yes >"$H.race2b" 2>&1
check "もう一度の uninstall が 0" test $? -eq 0
check "確認中に書き換えた skill は残す" grep -q 'edited while waiting' "$H/.claude/skills/mio/SKILL.md"
check "ほかの kit の skill は消す" test ! -e "$H/.claude/skills/aoi/SKILL.md"
check "記録の無い base のファイルは残す" test -f "$H/.claude/brain-kit/base/owner-note.md"
check "書き換えた base は残す" grep -q '持ち主の追記' "$H/.claude/brain-kit/base/.claude/skills/ren/SKILL.md"
check "書き換えていない base は消す" test ! -e "$H/.claude/brain-kit/base/.claude/skills/aoi/SKILL.md"
# 外したあとに持ち主が作り直したものは、--rollback でも上書きしない
mkdir -p "$H/.claude/skills/aoi"
printf 'owner recreated\n' >"$H/.claude/skills/aoi/SKILL.md"
printf '{"owner": "after"}\n' >"$H/.claude/settings.json"
new "$H" --rollback >"$H.rb" 2>&1
check "作り直しがあっても rollback が 0" test $? -eq 0
check "作り直した skill は上書きしない" grep -q 'owner recreated' "$H/.claude/skills/aoi/SKILL.md"
check "書き換えた settings は上書きしない" grep -q '"owner": "after"' "$H/.claude/settings.json"
check "ほかの外したものは戻る" test -f "$H/.claude/skills/sora/SKILL.md"
check "manifest も戻る" test -f "$H/.claude/brain-kit/manifest.json"

section "uninstall の settings.json：置き換えの失敗と書く直前の変更"
# kit.py を読み込み、os.replace（settings.json だけ）か退避の直後を差し替えて uninstall を走らせる
uninstall_fault() { # uninstall_fault <home> <replace|race>
  HOME="$1" python3 - "$KIT/lib/kit.py" "$2" <<'PY2'
import os, runpy, sys
from unittest import mock
g = runpy.run_path(sys.argv[1], run_name="kit_under_test")
mode = sys.argv[2]
settings = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
real_replace, real_save = os.replace, g["Backup"].save
def replace(src, dst, *a, **k):
    if os.path.basename(dst) == "settings.json":
        raise OSError("injected: replace failed")
    return real_replace(src, dst, *a, **k)
def save(self, path):
    real_save(self, path)
    if os.path.basename(path) == "settings.json":
        with open(settings, "a") as f:     # 退避のあと、書く直前に持ち主が保存した
            f.write("\n")
real_copy2 = g["shutil"].copy2
def copy2(src, dst, *a, **k):
    # settings.json を戻す途中で容量不足：半分だけ書いて落ちる
    if os.path.basename(src) == "settings.json":
        with open(src, "rb") as f:
            data = f.read()
        with open(dst, "wb") as f:
            f.write(data[: len(data) // 2])
        raise OSError("injected: copy failed")
    return real_copy2(src, dst, *a, **k)
real_open_bytes = g["main"].__globals__["open_bytes"]   # run_path が返す g は写しなので、関数が見る方を差し替える
def open_bytes(path):
    # 1 MiB を超えるファイルを丸ごと読んだら落とす（大きなデータファイルを読み込まないことの確かめ）
    if os.path.getsize(path) > 1024 * 1024:
        raise MemoryError("read whole file over 1 MiB: %s" % path)
    return real_open_bytes(path)
real_split, real_shlex = g["shlex"].split, g["shlex"].shlex
def split(line, *a, **k):
    if len(line) > 4096:
        raise MemoryError("shlex.split on a %d-char line" % len(line))
    return real_split(line, *a, **k)
def shlex_cls(line, *a, **k):
    if isinstance(line, str) and len(line) > 4096:
        raise MemoryError("shlex.shlex on a %d-char line" % len(line))
    return real_shlex(line, *a, **k)
real_journal = g["Backup"]._journal
def journal(self):
    # 退避した直後の記録（消した・書いた印）を書けずに止まる（容量不足など）
    if any(os.path.basename(p) == "settings.json" for p in self.meta["overwritten"]) and not self.meta.get("journal_failed"):
        if not self.meta.get("written"):
            real_journal(self)              # 退避そのものは記録に残る
            self.meta["journal_failed"] = True
            return
    if self.meta.get("journal_failed"):
        raise OSError("injected: journal failed")
    return real_journal(self)
patches = {"replace": [mock.patch.object(os, "replace", replace)],
           "race": [mock.patch.object(g["Backup"], "save", save)],
           "journal": [mock.patch.object(g["Backup"], "_journal", journal)],
           "rollback": [mock.patch.object(g["shutil"], "copy2", copy2)],
           "bigread": [mock.patch.dict(g["main"].__globals__, {"open_bytes": open_bytes})],
           "longline": [mock.patch.object(g["shlex"], "split", split), mock.patch.object(g["shlex"], "shlex", shlex_cls)]}[mode]
for p in patches:
    p.start()
try:
    g["main"](["rollback"] if mode == "rollback" else ["uninstall", "--dry-run"] if mode == "longline" else ["uninstall", "--yes"])
except SystemExit as e:
    sys.exit(e.code or 0)
except OSError as e:
    print("raised: %s" % e)
    sys.exit(3)
PY2
}
H="$TMP/uninstall-fault"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
cp "$H/.claude/settings.json" "$H.settings-orig"
uninstall_fault "$H" replace >"$H.replace" 2>&1
check "置き換えが失敗すると uninstall は 0 以外" test $? -ne 0
check "置き換えが失敗しても settings.json は元のバイト" cmp -s "$H.settings-orig" "$H/.claude/settings.json"
check "置き換えが失敗しても一時ファイルを残さない" sh -c "! ls -a '$H/.claude' | grep -q '^\.settings\.json\.'"
check "置き換えが失敗したら kit のファイルは消していない" test -f "$H/.claude/skills/aoi/SKILL.md"
new "$H" --rollback >"$H.rb" 2>&1
check "置き換えの失敗のあとの rollback が 0" test $? -eq 0
check "rollback のあとも settings.json は元のバイト" cmp -s "$H.settings-orig" "$H/.claude/settings.json"
uninstall_fault "$H" race >"$H.race" 2>&1
check "書く直前の変更で uninstall は 0 以外" test $? -ne 0
printf '\n' >>"$H.settings-orig"
check "書く直前の持ち主の変更を上書きしない" cmp -s "$H.settings-orig" "$H/.claude/settings.json"
check "書く直前の変更なら kit のファイルは消していない" test -f "$H/.claude/skills/aoi/SKILL.md"
new "$H" --rollback --dry-run >"$H.rb2" 2>&1
check "止めた退避は rollback の対象にしない" sh -c "! grep -q '（uninstall、' '$H.rb2'"
# 退避のあと「書いた」印の記録に失敗して止まり、そのあと持ち主が settings.json を変えた → rollback は上書きしない
H="$TMP/uninstall-journal"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
uninstall_fault "$H" journal >"$H.journal" 2>&1
check "記録の失敗で uninstall は 0 以外" test $? -ne 0
check "記録の失敗なら kit のファイルは消していない" test -f "$H/.claude/skills/aoi/SKILL.md"
printf '{"owner": "edited after failure"}\n' >"$H/.claude/settings.json"
new "$H" --rollback >"$H.rb" 2>&1
check "記録の失敗のあとの rollback が 0" test $? -eq 0
check "記録の失敗のあとの持ち主の settings を rollback で上書きしない" grep -q 'edited after failure' "$H/.claude/settings.json"
# rollback が settings.json を戻す途中で落ちても、途中の中身を残さず、もう一度の rollback で元のバイトに戻る
H="$TMP/uninstall-rbfail"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
cp "$H/.claude/settings.json" "$H.settings-orig"
new "$H" --uninstall --yes >"$H.un" 2>&1
cp "$H/.claude/settings.json" "$H.settings-after"
uninstall_fault "$H" rollback >"$H.rbfail" 2>&1
check "戻す途中の失敗で rollback は 0 以外" test $? -ne 0
check "戻す途中で落ちても settings.json は途中の中身にならない" cmp -s "$H.settings-after" "$H/.claude/settings.json"
check "戻す途中で落ちても一時ファイルを残さない" sh -c "! ls -a '$H/.claude' | grep -q '^\.settings\.json\.'"
new "$H" --rollback >"$H.rb" 2>&1
check "もう一度の rollback が 0" test $? -eq 0
check "もう一度の rollback で settings.json は元のバイト" cmp -s "$H.settings-orig" "$H/.claude/settings.json"
check "もう一度の rollback で kit の skill も戻る" test -f "$H/.claude/skills/aoi/SKILL.md"
# 読み取り専用の settings.json（0444）と kit の実行ファイル（0555）も、外して戻すとバイトと権限が戻る
H="$TMP/uninstall-readonly"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
chmod 444 "$H/.claude/settings.json"; chmod 555 "$H/.claude/brain-kit/bin/start-aoi"
cp "$H/.claude/settings.json" "$H.settings-orig"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "読み取り専用でも uninstall が 0" test $? -eq 0
check "読み取り専用の kit の実行ファイルも消す" test ! -e "$H/.claude/brain-kit/bin/start-aoi"
new "$H" --rollback >"$H.rb" 2>&1
check "読み取り専用でも rollback が 0" test $? -eq 0
check "読み取り専用の settings.json が元のバイトに戻る" cmp -s "$H.settings-orig" "$H/.claude/settings.json"
mode_is() { python3 -c 'import os, sys; sys.exit(os.stat(sys.argv[1]).st_mode & 0o777 != int(sys.argv[2], 8))' "$1" "$2"; }
check "settings.json の権限 444 が戻る" mode_is "$H/.claude/settings.json" 444
check "kit の実行ファイルの権限 555 が戻る" mode_is "$H/.claude/brain-kit/bin/start-aoi" 555

section "uninstall：残すフックが使う kit のファイル"
# 持ち主が SessionEnd の timeout だけを変えた → 項目は残すので、項目が呼ぶスクリプトも残す
H="$TMP/uninstall-hookref"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"] = 120
# 持ち主が足したフックが kit のスクリプトを ~ の形で呼ぶ
s["hooks"].setdefault("Notification", []).append(
    {"hooks": [{"type": "command", "command": "~/.claude/brain-kit/dashboard/collect.py --quiet"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
new "$H" --uninstall --dry-run >"$H.dry" 2>&1
check "dry-run: SessionEnd のスクリプトを「残すフックが使うため」に出す" sh -c "awk '/^残すもの（残すフックが使うため）/{f=1;next} /^[^ ]/{f=0} f' '$H.dry' | grep -qF 'hooks/session-end-brain.sh'"
check "dry-run: 持ち主のフックが呼ぶ collect.py も「残すフックが使うため」に出す" sh -c "awk '/^残すもの（残すフックが使うため）/{f=1;next} /^[^ ]/{f=0} f' '$H.dry' | grep -qF 'dashboard/collect.py'"
check "dry-run: SessionEnd のスクリプトを「消すもの」に出さない" sh -c "! awk '/^消すもの/{f=1;next} /^[^ ]/{f=0} f' '$H.dry' | grep -v '/base/' | grep -qF 'hooks/session-end-brain.sh'"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "uninstall が 0" test $? -eq 0
check "timeout だけ変えた SessionEnd の項目は残る" grep -q 'session-end-brain.sh' "$H/.claude/settings.json"
check "その項目が呼ぶ session-end-brain.sh も残る" test -x "$H/.claude/hooks/session-end-brain.sh"
check "持ち主のフックが呼ぶ collect.py も残る" test -f "$H/.claude/brain-kit/dashboard/collect.py"
check "残す session-end-brain.sh が呼ぶ brain-digest.js も残す" test -f "$H/.claude/hooks/brain-digest.js"
check "どのフックも呼ばない kit のファイルは消す" test ! -e "$H/.claude/brain-kit/bin/heavy-lock"
check "どのフックも呼ばない kit の skill は消す" test ! -e "$H/.claude/skills/aoi/SKILL.md"
# 持ち主が session-end-brain.sh を書き換え、SessionEnd の項目も変えた → 書き換えたスクリプトが呼ぶ brain-digest.js も残す
# 持ち主のスクリプト（kit の外）が kit の heavy-lock を呼ぶ → heavy-lock も残す
H="$TMP/uninstall-hookref-edited"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
printf '\n# 持ち主の追記\n' >>"$H/.claude/hooks/session-end-brain.sh"
# shellcheck disable=SC2016  # $HOME はスクリプトの中で展開させる
printf '#!/bin/sh\n"$HOME/.claude/brain-kit/bin/heavy-lock" true\n' >"$H/.claude/hooks/mine.sh"
chmod +x "$H/.claude/hooks/mine.sh"
# 2 段：持ち主のフック → 持ち主の mine2.sh → 持ち主の helper.sh → kit の collect.py
mkdir -p "$H/.claude/own"
# shellcheck disable=SC2016  # $HOME はスクリプトの中で展開させる
printf '#!/bin/sh\nexec "$HOME/.claude/own/helper.sh"\n' >"$H/.claude/hooks/mine2.sh"
printf '#!/bin/sh\npython3 ~/.claude/brain-kit/dashboard/collect.py\n' >"$H/.claude/own/helper.sh"
# 相対：持ち主のフック → node の mine.js → require('./helper.js') → kit の shot.py
printf "require('./helper.js');\n" >"$H/.claude/hooks/mine.js"
# symlink：持ち主のフック → ~/.claude/hooks/current.sh（kit の precheck.sh を指す symlink）
ln -s ../brain-kit/automations/precheck.sh "$H/.claude/hooks/current.sh"
# 空白を含む持ち主のスクリプト（引用符あり・\ で逃がしたもの）→ kit の start-aoi・start-ren
# shellcheck disable=SC2016  # $HOME はスクリプトの中で展開させる
printf '#!/bin/sh\n"$HOME/.claude/brain-kit/bin/start-aoi" --help\n' >"$H/.claude/hooks/my hook.sh"
# shellcheck disable=SC2016
printf '#!/bin/sh\n"$HOME/.claude/brain-kit/bin/start-ren" --help\n' >"$H/.claude/hooks/other hook.sh"
# shellcheck disable=SC2016
printf '#!/bin/sh\n"$HOME/.claude/brain-kit/bin/start-sora" --help\n' >"$H/.claude/hooks/third hook.sh"
# UTF-8 でない（Latin-1 のコメント）持ち主のスクリプト → kit の index.html を呼ぶ
# shellcheck disable=SC2016
printf '#!/bin/sh\n# caf\351\ncat "$HOME/.claude/brain-kit/dashboard/index.html"\n' >"$H/.claude/hooks/latin1.sh"
# 大きな（2 MiB）データファイルを名指しする持ち主のフック
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"x" * (2 * 1024 * 1024))' "$H/.claude/big.dat"
printf "require('child_process').execFileSync('/usr/bin/env', ['python3', '%s/.claude/brain-kit/dashboard/shot.py']);\n" "$H" >"$H/.claude/hooks/helper.js"
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"] = 120
s["hooks"].setdefault("Notification", []).append(
    {"hooks": [{"type": "command", "command": "\"$HOME/.claude/hooks/mine.sh\""}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/mine2.sh"}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "node ~/.claude/hooks/mine.js"}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "\"$HOME/.claude/hooks/current.sh\""}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "sh \"$HOME/.claude/hooks/my hook.sh\""}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/other\\ hook.sh"}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/third\\ hook.sh; echo done"}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/latin1.sh"}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "wc -c ~/.claude/big.dat"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
new "$H" --uninstall --yes >"$H.un" 2>&1
check "書き換えたスクリプト: uninstall が 0" test $? -eq 0
check "書き換えた session-end-brain.sh は残る" grep -q '持ち主の追記' "$H/.claude/hooks/session-end-brain.sh"
check "書き換えた session-end-brain.sh が呼ぶ brain-digest.js も残る" test -f "$H/.claude/hooks/brain-digest.js"
check "持ち主のスクリプトが呼ぶ heavy-lock も残る" test -x "$H/.claude/brain-kit/bin/heavy-lock"
check "持ち主のスクリプトは残る" test -x "$H/.claude/hooks/mine.sh"
check "持ち主のスクリプト → 補助スクリプトが呼ぶ collect.py も残る" test -f "$H/.claude/brain-kit/dashboard/collect.py"
check "持ち主の node スクリプト → 相対の補助 → kit の shot.py も残る" test -f "$H/.claude/brain-kit/dashboard/shot.py"
check ".claude の中の symlink（current.sh → precheck.sh）越しに呼ぶ kit のファイルも残る" test -f "$H/.claude/brain-kit/automations/precheck.sh"
check "symlink はそのまま" test -L "$H/.claude/hooks/current.sh"
check "引用符の中の空白を含むパスの持ち主のスクリプトが呼ぶ start-aoi も残る" test -f "$H/.claude/brain-kit/bin/start-aoi"
check "\\ で逃がした空白を含むパスの持ち主のスクリプトが呼ぶ start-ren も残る" test -f "$H/.claude/brain-kit/bin/start-ren"
check "\\ で逃がした空白のパスのあとに ; が続いても、そのスクリプトが呼ぶ start-sora を残す" test -f "$H/.claude/brain-kit/bin/start-sora"
check "UTF-8 でない持ち主のスクリプトが呼ぶ index.html も残す" test -f "$H/.claude/brain-kit/dashboard/index.html"
check "大きなファイルを名指ししても uninstall は通り、そのファイルは残る" test -f "$H/.claude/big.dat"
check "どれも呼ばない start-mio は消す" test ! -e "$H/.claude/brain-kit/bin/start-mio"
check "どれも呼ばない kit の skill は消す" test ! -e "$H/.claude/skills/aoi/SKILL.md"
# 確認を待つ間に、残す持ち主のスクリプトが kit のファイルを呼ぶように書き換えた → 何も変えずに止まる
H2="$TMP/uninstall-hookref-race"; mkdir -p "$H2"
new "$H2" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H2.log" 2>&1
printf '#!/bin/sh\ntrue\n' >"$H2/.claude/hooks/mine.sh"
python3 - "$H2/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"].setdefault("Notification", []).append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/mine.sh"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
backups_before="$(find "$H2/.claude" -type d -name 'backup-brain-kit-*' | sort)"
# shellcheck disable=SC2016  # $HOME はスクリプトの中で展開させる
{ sleep 3; printf '"$HOME/.claude/brain-kit/bin/heavy-lock" true\n' >>"$H2/.claude/hooks/mine.sh"; echo y; } |
  BRAIN_KIT_INTERACTIVE=1 HOME="$H2" bash "$KIT/install.sh" --uninstall >"$H2.race" 2>&1
check "確認中に残すスクリプトが変わると止まる" test $? -ne 0
check "止まったとき heavy-lock は消えていない" test -x "$H2/.claude/brain-kit/bin/heavy-lock"
check "止まったとき kit の skill も消えていない" test -f "$H2/.claude/skills/aoi/SKILL.md"
check "止まったとき退避を作らない" test "$backups_before" = "$(find "$H2/.claude" -type d -name 'backup-brain-kit-*' | sort)"
new "$H2" --uninstall --yes >"$H2.un" 2>&1
check "もう一度の uninstall は 0 で、heavy-lock を残す" sh -c "test -x '$H2/.claude/brain-kit/bin/heavy-lock'"
# 持ち主が何も変えていなければ、SessionEnd の項目もスクリプトも外す
H="$TMP/uninstall-hookref-plain"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
new "$H" --uninstall --yes >"$H.un" 2>&1
check "変えていなければ SessionEnd の項目を外す" sh -c "! grep -q 'session-end-brain.sh' '$H/.claude/settings.json'"
check "変えていなければ session-end-brain.sh も消す" test ! -e "$H/.claude/hooks/session-end-brain.sh"
check "変えていなければ brain-digest.js も消す" test ! -e "$H/.claude/hooks/brain-digest.js"
# 同じ実体の別名（skills/sora → skills/ren のディレクトリ symlink）：残すフックが sora の側を読むなら、ren の側も消さない
H="$TMP/uninstall-alias"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
mv "$H/.claude/skills/sora" "$H/sora-moved"
ln -s ren "$H/.claude/skills/sora"
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"].setdefault("Notification", []).append({"hooks": [{"type": "command", "command": "cat ~/.claude/skills/sora/SKILL.md"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
new "$H" --uninstall --yes >"$H.un" 2>&1
check "別名: uninstall が 0" test $? -eq 0
check "別名で読まれる skills/ren/SKILL.md は消さない" test -f "$H/.claude/skills/ren/SKILL.md"
check "別名: 読まれない skill は消す" test ! -e "$H/.claude/skills/aoi/SKILL.md"
# symlink の別名から相対で呼ぶ：hooks/wrapper.sh → ../own/wrapper.sh（実体）が ./session-end-brain.sh を呼ぶ
# （別名のディレクトリ hooks/ から見た相対）→ hooks/session-end-brain.sh を消さない
H="$TMP/uninstall-aliasrel"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
mkdir -p "$H/.claude/own"
# shellcheck disable=SC2016  # スクリプトの中で展開させる
printf '#!/bin/sh\ncd -- "$(dirname -- "$0")" || exit 1\nsh ./session-end-brain.sh\n' >"$H/.claude/own/wrapper.sh"
ln -s ../own/wrapper.sh "$H/.claude/hooks/wrapper.sh"
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"].setdefault("Notification", []).append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/wrapper.sh"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
new "$H" --uninstall --yes >"$H.un" 2>&1
check "別名からの相対: uninstall が 0" test $? -eq 0
check "別名のディレクトリから相対で呼ぶ session-end-brain.sh は消さない" test -f "$H/.claude/hooks/session-end-brain.sh"
check "別名からの相対: 呼ばれない skill は消す" test ! -e "$H/.claude/skills/aoi/SKILL.md"
# 自分自身を別名で呼び直す：own/disp.sh が hooks/alias.sh（→ own/disp.sh）を呼び、そこから ./brain-digest.js を使う
# symlink と .. の組み合わせ：~/.claude/link（→ brain-kit/dashboard）/../bin/heavy-lock は brain-kit/bin/heavy-lock
H="$TMP/uninstall-selfalias"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
mkdir -p "$H/.claude/own"
# shellcheck disable=SC2016  # スクリプトの中で展開させる
printf '#!/bin/sh\n[ -n "$1" ] && exec sh "$HOME/.claude/hooks/alias.sh"\nnode ./brain-digest.js\n' >"$H/.claude/own/disp.sh"
ln -s ../own/disp.sh "$H/.claude/hooks/alias.sh"
ln -s brain-kit/dashboard "$H/.claude/link"
# 指す先の途中に .. がある symlink：link2 → brain-kit/automations/../bin（automations が消えると辿れない）
ln -s brain-kit/automations/../bin "$H/.claude/link2"
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
# 持ち主のフック（自分では kit の SessionEnd を外してある）
del s["hooks"]["SessionEnd"]
s["hooks"].setdefault("Notification", []).append({"hooks": [{"type": "command", "command": "sh ~/.claude/own/disp.sh go"}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "sh ~/.claude/link/../bin/heavy-lock true"}]})
s["hooks"]["Notification"].append({"hooks": [{"type": "command", "command": "sh ~/.claude/link2/heavy-lock true"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
new "$H" --uninstall --yes >"$H.un" 2>&1
check "自分を別名で呼ぶ: uninstall が 0" test $? -eq 0
check "別名のディレクトリから相対で使う brain-digest.js は消さない" test -f "$H/.claude/hooks/brain-digest.js"
check "symlink と .. で指す heavy-lock は消さない" test -x "$H/.claude/brain-kit/bin/heavy-lock"
check "symlink と .. のパスが、外したあとも書かれた形のまま辿れる（link の指す先を消さない）" test -x "$H/.claude/link/../bin/heavy-lock"
check "指す先の途中に .. がある symlink のパスも、外したあと辿れる（automations を消さない）" test -x "$H/.claude/link2/heavy-lock"
check "自分を別名で呼ぶ: 呼ばれない skill は消す" test ! -e "$H/.claude/skills/aoi/SKILL.md"
# 相対の自己参照（./self.sh）と 2 つのファイルの相対の循環でも、同じファイルを読み続けずに終わる
H="$TMP/uninstall-cycle"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
printf '#!/bin/sh\n# usage: ./self.sh\nsh ./b.sh\n' >"$H/.claude/hooks/self.sh"
printf '#!/bin/sh\nsh ./self.sh\nsh ../hooks/./self.sh\n' >"$H/.claude/hooks/b.sh"
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"].setdefault("Notification", []).append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/self.sh"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
python3 - "$KIT" "$H" <<'PY2'
import subprocess, sys
kit, h = sys.argv[1], sys.argv[2]
try:
    r = subprocess.run(["bash", kit + "/install.sh", "--uninstall", "--dry-run"], env={"HOME": h, "PATH": __import__("os").environ["PATH"]},
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    sys.exit(r.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY2
check "相対の自己参照と循環でも dry-run が 60 秒以内に 0 で終わる" test $? -eq 0
# 計画のときには無かった持ち主のスクリプトが、確認を待つ間に作られ、kit のファイルを呼ぶ → 止まる
H="$TMP/uninstall-appear"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"].setdefault("Notification", []).append({"hooks": [{"type": "command", "command": "sh ~/.claude/hooks/later.sh"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
# shellcheck disable=SC2016  # $HOME はスクリプトの中で展開させる
{ sleep 3; printf '#!/bin/sh\n"$HOME/.claude/brain-kit/bin/heavy-lock" true\n' >"$H/.claude/hooks/later.sh"; echo y; } |
  BRAIN_KIT_INTERACTIVE=1 HOME="$H" bash "$KIT/install.sh" --uninstall >"$H.race" 2>&1
check "確認中に現れたスクリプト: 止まる" test $? -ne 0
check "確認中に現れたスクリプトが呼ぶ heavy-lock は消えていない" test -x "$H/.claude/brain-kit/bin/heavy-lock"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "もう一度の uninstall は heavy-lock を残す" test -x "$H/.claude/brain-kit/bin/heavy-lock"
# 残すフックが名指しした 2 MiB のファイルを丸ごと読まない（1 MiB を超えて読んだら落ちるようにして走らせる）
H="$TMP/uninstall-bigread"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"x" * (2 * 1024 * 1024))' "$H/.claude/big.dat"
python3 - "$H/.claude/settings.json" <<'PY2'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["hooks"].setdefault("Notification", []).append({"hooks": [{"type": "command", "command": "wc -c ~/.claude/big.dat"}]})
open(p, "w").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY2
uninstall_fault "$H" longline >"$H.long" 2>&1
check "1 MiB の 1 行のデータファイルを shlex に渡さない（遅くなる。CI の bash 3.2 で止まった）" test $? -eq 0
uninstall_fault "$H" bigread >"$H.big" 2>&1
check "残すフックが名指しした大きなファイルを丸ごと読まずに uninstall が 0" test $? -eq 0
check "大きなファイルは残る" test -f "$H/.claude/big.dat"

# ------------------------------------------------------------------ Claude Code の版
section "Claude Code の版（注意だけで続行）"
old_word='動作を確かめた版（2.1.294）より古い'
missing_word='Claude Code CLI（claude）が無い'
for version_case in old equal newer odd failed; do
  fake="$TMP/claude-$version_case"; mkdir -p "$fake"
  case "$version_case" in
    old) output='2.1.200 (Claude Code)'; expected=1 ;;
    equal) output='2.1.294 (Claude Code)'; expected=0 ;;
    newer) output='2.2.0 (Claude Code)'; expected=0 ;;
    odd|failed) output='something odd'; expected=0 ;;
  esac
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$output" >"$fake/claude"
  [ "$version_case" != failed ] || printf 'exit 1\n' >>"$fake/claude"
  chmod +x "$fake/claude"
  H="$TMP/version-$version_case"; mkdir -p "$H"
  PATH="$fake:$PATH" new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.install" 2>&1
  check "$version_case: install が 0" test $? -eq 0
  PATH="$fake:$PATH" new "$H" --update >"$H.update" 2>&1
  check "$version_case: update が 0" test $? -eq 0
  PATH="$fake:$PATH" new "$H" --update --dry-run >"$H.dry" 2>&1
  check "$version_case: dry-run が 0" test $? -eq 0
  PATH="$fake:$PATH" new "$H" --doctor >"$H.doctor" 2>&1
  check "$version_case: doctor が 0" test $? -eq 0
  for action in install update dry doctor; do
    check "$version_case/$action: 古い版の注意は $expected 行" test "$(grep -cF "$old_word" "$H.$action")" -eq "$expected"
    check "$version_case/$action: 版の注意に必要と言わない" test "$(grep -F '2.1.294）より古い' "$H.$action" | grep -c '必要')" -eq 0
    if [ "$version_case" = odd ] || [ "$version_case" = failed ]; then
      check "$version_case/$action: 読めない注意は 1 行" test "$(grep -c '版を読めない' "$H.$action")" -eq 1
    fi
  done
  case "$version_case" in
    old)
      check "doctor: 古い行" grep -q 'Claude Code の版.*古い.*2.1.200' "$H.doctor"
      check "doctor: todo に更新" grep -q '^[[:space:]]*[0-9][0-9]*\. claude update（動作を確かめた版 2.1.294 より古い）' "$H.doctor" ;;
    equal|newer)
      check "doctor: OK 行" grep -q 'Claude Code の版.*OK.*動作を確かめた版 2.1.294 以上' "$H.doctor"
      check "同じか新しい版の導入・更新は警告なし" test "$(grep -c 'warn: Claude Code' "$H.install" "$H.update" "$H.dry" | grep -vc ':0$')" -eq 0 ;;
    odd|failed) check "doctor: 要確認行" grep -q 'Claude Code の版.*要確認.*版を読めない' "$H.doctor" ;;
  esac
done
H="$TMP/version-missing"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.install" 2>&1
check "claude 無し: install が 0" test $? -eq 0
check "claude 無し: install は kit の注意を重ねない" test "$(grep -cF "$missing_word" "$H.install")" -eq 0
new "$H" --update >"$H.update" 2>&1
check "claude 無し: update が 0" test $? -eq 0
check "claude 無し: update の注意は 1 行" test "$(grep -cF "$missing_word" "$H.update")" -eq 1
new "$H" --doctor >"$H.doctor" 2>&1
check "claude 無し: doctor が 0" test $? -eq 0
check "claude 無し: doctor は注意を重ねない" test "$(grep -cF "$missing_word" "$H.doctor")" -eq 0

# 時間切れは待たずに再現し、先頭の空白・数値比較・短縮も確かめる。
python3 - "$KIT/lib/kit.py" <<'PY2'
import runpy, subprocess, sys
from unittest import mock
warning = runpy.run_path(sys.argv[1])["claude_version_warning"]
assert warning(result=(0, "  2.1.294 (Claude Code)", "")) is None
assert warning(result=(0, "2.10.0 (Claude Code)", "")) is None
assert "より古い" in warning(result=(0, "2.1.9 (Claude Code)", ""))
assert "版を読めない" in warning(result=(1, "2.1.294 (Claude Code)", ""))
assert "x" * 60 + "）。" in warning(result=(0, "x" * 100 + "\nsecond", ""))
with mock.patch("shutil.which", return_value="/fake/claude"), mock.patch(
        "subprocess.run", side_effect=subprocess.TimeoutExpired("claude", 15)) as call:
    text = warning()
    assert "版を読めない" in text and len(text.splitlines()) == 1
    assert call.call_args.kwargs["timeout"] == 15
PY2
check "版の取得: 空白・数値比較・失敗・60 文字・時間切れ" test $? -eq 0

section "--version（依存コマンドやほかの引数に左右されない）"
version_path="$TMP/version-bin"; mkdir -p "$version_path"
for c in dirname tr; do ln -s "$(command -v "$c")" "$version_path/$c"; done
for version_args in '--version' '--version --unknown --mode' '--unknown --version --help'; do
  # shellcheck disable=SC2086  # 固定のテスト引数を分けて渡す
  PATH="$version_path" "$BASH" "$KIT/install.sh" $version_args >"$TMP/version.out" 2>&1
  check "--version $version_args: 0" test $? -eq 0
  printf 'brain-kit v%s\n' "$KV" >"$TMP/version.expected"
  check "--version $version_args: 版の 1 行だけ" cmp -s "$TMP/version.expected" "$TMP/version.out"
done
if [ -n "$NODE" ]; then
  "$NODE" "$KIT/bin/brain-kit.js" --version >"$TMP/version.out" 2>&1
  check "node 経由の --version が 0" test $? -eq 0
  check "node 経由も版の 1 行だけ" cmp -s "$TMP/version.expected" "$TMP/version.out"
fi

section "check.sh の版の一致"
version_check="$TMP/version-check"; mkdir -p "$version_check"
for version_case in current kit package format absent heading noheading invalid minor pending dotted missingkit missingpackage missingchangelog badheading zero; do
  cp "$KIT/check.sh" "$KIT/VERSION" "$KIT/package.json" "$KIT/CHANGELOG.md" "$version_check/"
  expected=1
  case "$version_case" in
    current) expected=0 ;;
    kit) printf '12\n' >"$version_check/VERSION" ;;
    package) printf '{"version":"12.0.0"}\n' >"$version_check/package.json" ;;
    format) printf '{"version":"11"}\n' >"$version_check/package.json" ;;
    absent) printf '{}\n' >"$version_check/package.json" ;;
    heading) printf '## v12\n' >"$version_check/CHANGELOG.md" ;;
    noheading) printf '## 次の版（作業中）\n' >"$version_check/CHANGELOG.md" ;;
    invalid) printf 'odd\n' >"$version_check/VERSION" ;;
    minor) printf '{"version":"%s.3.2"}\n' "$KV" >"$version_check/package.json"; expected=0 ;;
    pending) printf '## 次の版（作業中）\n\n## v%s\n' "$KV" >"$version_check/CHANGELOG.md"; expected=0 ;;
    dotted) printf '## v%s.1\n' "$KV" >"$version_check/CHANGELOG.md"; expected=0 ;;
    missingkit) rm "$version_check/VERSION" ;;
    missingpackage) rm "$version_check/package.json" ;;
    missingchangelog) rm "$version_check/CHANGELOG.md" ;;
    badheading) printf '## v11.odd\n' >"$version_check/CHANGELOG.md" ;;
    zero) printf '0\n' >"$version_check/VERSION" ;;
  esac
  BRAIN_KIT_CHECK_WORDS_FILE=/nonexistent bash "$version_check/check.sh" >"$TMP/version-check.out" 2>&1
  check "$version_case: check.sh が $expected" test $? -eq "$expected"
  if [ "$expected" = 1 ]; then
    check "$version_case: [version] の指摘" grep -q '^\[version\]' "$TMP/version-check.out"
  else
    check "$version_case: 0 件の表示を保つ" grep -q '^ok: 0 件' "$TMP/version-check.out"
  fi
done

# ------------------------------------------------------------------ セッション開始時の更新のお知らせ
section "更新のお知らせ（npm 公開版・キャッシュ・停止）"
H="$TMP/update-notice"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.install" 2>&1
check "通知: install が 0" test $? -eq 0
python3 - "$H" "$KIT" <<'PY'
import fcntl, hashlib, http.server, json, os, pathlib, socket, subprocess, sys, threading, time
h, kit = map(pathlib.Path, sys.argv[1:])
state = h / ".claude/brain-kit"
hook = h / ".claude/hooks/brain-kit-update-check.py"
manifest = state / "manifest.json"
cache = state / "update-check.json"
stop = state / "no-update-check"
env = dict(os.environ, HOME=str(h), NO_PROXY="localhost", no_proxy="localhost")
env.pop("BRAIN_KIT_NO_UPDATE_CHECK", None)
m = json.loads(manifest.read_text())
assert m["package_version"] == json.loads((kit / "package.json").read_text())["version"] == "11.0.0"
assert os.access(str(hook), os.X_OK)
command = 'python3 "$HOME/.claude/hooks/brain-kit-update-check.py"'
group = {"hooks": [{"type": "command", "command": command, "timeout": 10}]}
s = json.loads((h / ".claude/settings.json").read_text())
assert s["hooks"]["SessionStart"].count(group) == 1
assert m["settings"]["hooks.SessionStart"][command] == hashlib.sha256(
    json.dumps(group, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.count += 1
        if self.server.hang:
            self.server.release.wait()
            return
        body = self.server.body.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("localhost", 0), Handler)
server.count, server.hang, server.body = 0, False, '{}'
server.release = threading.Event()
threading.Thread(target=server.serve_forever, daemon=True).start()
env["BRAIN_KIT_UPDATE_URL"] = "http://localhost:%d/" % server.server_port

def poll(predicate, limit=10):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError("バックグラウンド処理が時間内に終わらない")

def unlocked():
    with (state / "update-check.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False

def finished(count):
    # 起動前の空きロックを完了と誤認しないよう、先に要求の到着を待つ。
    poll(lambda: server.count == count)
    poll(unlocked, 6)

def clear():
    if cache.exists():
        cache.unlink()

def seed(latest, age=25 * 3600):
    cache.write_text(json.dumps({"checked_at": time.time() - age, "latest": latest}))

def publish(version):
    server.body = json.dumps({"version": version})

def expected(latest):
    if latest is None:
        return b""
    return ("brain-kit の更新のお知らせ: brain-kit %s が出ている（今は 11.0.0）。自動では更新しない。"
            "中身を見る: npx brainkit-agents@latest --update --dry-run"
            "（持ち主への最初の返事の冒頭で、この 1 行だけをそのまま伝える。更新はしない）\n" % latest).encode()

def run(latest=None, extra=None, pipe=False):
    start = time.monotonic()
    p = subprocess.Popen([sys.executable, str(hook)], env=dict(env, **(extra or {})),
                         stdin=subprocess.PIPE if pipe else subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        if pipe:
            p.stdin.write(b'{}\n')
            p.stdin.flush()
            p.wait(timeout=1)
        out, err = p.communicate(timeout=1)
        assert time.monotonic() - start < 1
        assert (p.returncode, out, err) == (0, expected(latest), b""), (p.returncode, out, err)
    finally:
        if p.poll() is None:
            p.kill()
            p.communicate()

try:
    # 初回は無出力、次のセッションからキャッシュの版だけを知らせる。
    for version in ("12.0.0", "11.1.0", "11.0.0", "10.1.0", "11.0.1", "11.10.0"):
        clear(); publish(version)
        count = server.count
        run()
        poll(lambda: json.loads(cache.read_text())["latest"] == version)
        finished(count + 1)
        run(version if version not in ("11.0.0", "10.1.0") else None)
        assert server.count == count + 1
    for invalid in ('{', '{}', 'null', '[]', '{"version":null}', '{"version":"next"}',
                    '{"version":"12.0"}', '{"version":"12.0.0-beta.1"}'):
        clear(); server.body = invalid
        count = server.count
        run(); finished(count + 1); run()
        assert json.loads(cache.read_text())["latest"] is None
        assert server.count == count + 1
    clear(); publish("12.0.0")
    count = server.count
    run(); finished(count + 1)
    publish("13.0.0")
    run("12.0.0"); run("12.0.0", pipe=True)
    assert server.count == count + 1
    seed("12.0.0")
    run("12.0.0"); finished(count + 2); run("13.0.0")
    assert server.count == count + 2
    # 1 時間以内の未来時刻は新鮮、それ以上は再試行する。
    seed("13.0.0", -1800); run("13.0.0")
    assert server.count == count + 2
    seed("13.0.0", -7200); run("13.0.0"); finished(count + 3)
    # 他の処理がロックを持っていても、既存の通知を失わず待たない。
    seed("12.0.0")
    with (state / "update-check.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run("12.0.0")
    assert server.count == count + 3
    seed("12.0.0"); publish("14.0.0")
    count = server.count
    processes = [subprocess.Popen([sys.executable, str(hook)], env=env,
                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(8)]
    for p in processes:
        out, err = p.communicate(timeout=2)
        assert p.returncode == 0 and err == b"" and out in (expected("12.0.0"), expected("14.0.0"))
    finished(count + 1)
    assert json.loads(cache.read_text())["latest"] == "14.0.0"
    assert server.count == count + 1
    # 応答が無い場合もフックは即座に戻り、子は 5 秒でロックを解放する。
    seed("12.0.0"); server.hang = True
    count = server.count
    start = time.monotonic()
    run("12.0.0"); finished(count + 1)
    assert time.monotonic() - start < 6.5
    c = json.loads(cache.read_text())
    assert c["latest"] == "12.0.0" and 0 <= time.time() - c["checked_at"] < 10
    before = cache.read_bytes()
    run("12.0.0")
    assert cache.read_bytes() == before and server.count == count + 1
    server.hang = False
    # 保存できなければ試行しない。残った一時ファイルもない。
    clear(); cache.mkdir()
    count = server.count
    run(); run()
    time.sleep(.2)
    assert server.count == count and not list(state.glob(".update-check-*"))
    cache.rmdir()
    # 閉じたポートへの失敗は無出力で、試行時刻だけが残る。
    with socket.socket() as sock:
        sock.bind(("localhost", 0))
        offline = "http://localhost:%d/" % sock.getsockname()[1]
    for previous in (None, "12.0.0"):
        seed(previous)
        run(previous, extra={"BRAIN_KIT_UPDATE_URL": offline})
        # 接続失敗は要求数で追えないため、子の起動時間を取ってから排他も確認する。
        time.sleep(.5); poll(unlocked, 6)
        c = json.loads(cache.read_text())
        assert c["latest"] == previous and time.time() - c["checked_at"] < 10
        run(previous)
    assert server.count == count
    # 停止時はキャッシュの内容・時刻も変わらない。
    for use_file in (False, True):
        for existing in (False, True):
            clear()
            if existing:
                seed("12.0.0")
            before = (cache.read_bytes(), cache.stat().st_mtime_ns) if existing else None
            if use_file:
                stop.touch()
            run(extra={} if use_file else {"BRAIN_KIT_NO_UPDATE_CHECK": "1"})
            assert ((cache.read_bytes(), cache.stat().st_mtime_ns) if cache.exists() else None) == before
            if use_file:
                stop.unlink()
    seed("12.0.0", 0)
    manifest.write_text(json.dumps({"version": 11})); run("12.0.0")
    clear()
    for broken in ("{", "[]", "null", '{}', '{"package_version":"odd"}'):
        manifest.write_text(broken); run(); assert not cache.exists()
    manifest.unlink(); run(); assert not cache.exists()
    manifest.write_text(json.dumps(m))
    time.sleep(.2)
    assert server.count == count
    seed("12.0.0", 0)
finally:
    server.release.set()
    server.shutdown()
    server.server_close()
PY
check "通知: 非同期・版比較・排他・失敗・保存不可・停止・入力・manifest" test $? -eq 0
new "$H" --doctor >"$H.doctor" 2>&1
check "通知: doctor は有効とキャッシュの版を表示" grep -q '更新のお知らせ.*有効.*12.0.0' "$H.doctor"
touch "$H/.claude/brain-kit/no-update-check"
new "$H" --doctor >"$H.doctor-off" 2>&1
check "通知: doctor は止めてあると表示" grep -q '更新のお知らせ.*止めてある' "$H.doctor-off"
rm "$H/.claude/brain-kit/no-update-check"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "通知: uninstall が 0" test $? -eq 0
check "通知: 未変更のスクリプトを外す" test ! -e "$H/.claude/hooks/brain-kit-update-check.py"
check "通知: 未変更の項目を外す" sh -c "! grep -q brain-kit-update-check.py '$H/.claude/settings.json'"
new "$H" --doctor >"$H.doctor-none" 2>&1
check "通知: doctor はフック無しと表示" grep -q '更新のお知らせ.*フック無し' "$H.doctor-none"

section "更新のお知らせ（前の kit から追加・所有設定の保持）"
H="$TMP/update-notice-old"
old_install 6033393 "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes
check "通知: 前の kit にはスクリプトが無い" test ! -e "$H/.claude/hooks/brain-kit-update-check.py"
python3 - "$H" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / ".claude/settings.json"
s = json.loads(p.read_text())
s["model"] = "owner-model"
s["permissions"] = {"allow": ["Bash(echo:*)"]}
s["hooks"]["SessionStart"].insert(0, {"hooks": [{"type": "command", "command": "echo owner", "timeout": 7}]})
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY
cp "$H/.claude/settings.json" "$H.settings-before"
new "$H" --update --no-worktrees >"$H.up" 2>&1
check "通知: 前の kit から update が 0" test $? -eq 0
check "通知: update で実行可能なスクリプトを追加" test -x "$H/.claude/hooks/brain-kit-update-check.py"
python3 - "$H" <<'PY'
import hashlib, json, pathlib, sys
h = pathlib.Path(sys.argv[1])
p = h / ".claude/settings.json"
s = json.loads(p.read_text())
command = 'python3 "$HOME/.claude/hooks/brain-kit-update-check.py"'
groups = s["hooks"]["SessionStart"]
group = next(g for g in groups if g["hooks"][0]["command"] == command)
assert group == {"hooks": [{"type": "command", "command": command, "timeout": 10}]}
groups.remove(group)
# この版では核の読み直しも追加される。追加分以外は持ち主の設定と完全に一致する。
core_command = 'python3 "$HOME/.claude/hooks/brain-kit-core-reread.py"'
groups.remove({"matcher": "compact", "hooks": [
    {"type": "command", "command": core_command, "timeout": 10}]})
assert s == json.loads(pathlib.Path(str(h) + ".settings-before").read_text())
m = json.loads((h / ".claude/brain-kit/manifest.json").read_text())
assert m["package_version"] == "11.0.0"
assert m["settings"]["hooks.SessionStart"][command] == hashlib.sha256(
    json.dumps(group, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
PY
check "通知: update で項目と所有記録を追加し持ち主の設定を保持" test $? -eq 0
before="$(snap "$H")"
new "$H" --update --no-worktrees >"$H.up2" 2>&1
check "通知: 2 回目の update が 0" test $? -eq 0
check "通知: 2 回目の update は何も変えない" test "$before" = "$(snap "$H")"
python3 - "$H/.claude/settings.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = json.loads(p.read_text())
for group in s["hooks"]["SessionStart"]:
    for hook in group["hooks"]:
        if "brain-kit-update-check.py" in hook["command"]:
            hook["timeout"] = 20
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY
new "$H" --uninstall --yes >"$H.un" 2>&1
check "通知: 編集後の uninstall が 0" test $? -eq 0
check "通知: 編集した項目が使うスクリプトを残す" test -x "$H/.claude/hooks/brain-kit-update-check.py"
check "通知: 残す理由を表示" grep -q '残すフックが使うため' "$H.un"
python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert any(h["timeout"] == 20 for g in s["hooks"]["SessionStart"] for h in g["hooks"]
           if "brain-kit-update-check.py" in h["command"])
PY
check "通知: 編集した項目をそのまま残す" test $? -eq 0

# ------------------------------------------------------------------ 自分を直す雛形（#9 の 3 番）：足すだけ・持ち主の手直しを保つ
section "自分を直す雛形"
PRE93=62952c7   # 雛形が入る前の main
H="$TMP/self-improve"
old_install "$PRE93" "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --yes --no-worktrees
check "前の版には答えの表が無い" test ! -e "$H/brain/Aoi/21_読み直しの答え.md"
printf '| 2026-01-03 | Ren | 持ち主の行 | 手順外 | dev/00_核.md | |\n' >>"$H/brain/Aoi/20_振り返り.md"
printf '\n## F. 持ち主の項目\n' >>"$H/brain/review/規準.md"
git -C "$H/brain" add -A >/dev/null && git -C "$H/brain" commit -qm owner >/dev/null
furi0="$(cat "$H/brain/Aoi/20_振り返り.md")"; kijun0="$(cat "$H/brain/review/規準.md")"
new "$H" --update --no-worktrees </dev/null >"$H.up" 2>&1
check "雛形: 更新が 0" test $? -eq 0
for f in review/規準の版/README.md review/読み直し/README.md review/読み直し/_テンプレート.md review/評価/_テンプレート.md Aoi/21_読み直しの答え.md; do
  check "雛形: 更新で足す $f" test -f "$H/brain/$f"
done
check "雛形: 持ち主の振り返りの表に触らない" test "$furi0" = "$(cat "$H/brain/Aoi/20_振り返り.md")"
check "雛形: 持ち主の規準に触らない" test "$kijun0" = "$(cat "$H/brain/review/規準.md")"
check "雛形: 答えの表は持ち主のもの（kit の記録に無い）" sh -c "! grep -q '21_読み直しの答え' '$H/brain/.brain-kit/manifest.json'"
check "雛形: 使い方は kit のもの（kit の記録に有る）" grep -q '読み直し/README.md' "$H/brain/.brain-kit/manifest.json"
s1="$(snap "$H")"
new "$H" --update --no-worktrees </dev/null >"$H.up2" 2>&1
check "雛形: 2 回目の更新は何も変えない" test "$s1" = "$(snap "$H")"
# 持ち主が答えを書き、採点表の雛形を自分の列に直す。次の版の kit が同じファイルを変えても上書きしない
printf '\n## 2026-01（規準 版 1）\n| 1 | example/app#1 | abc1234 | a.ts:1 — 持ち主の答え | A1 | 捕まえた |\n' >>"$H/brain/Aoi/21_読み直しの答え.md"
printf '\n持ち主が足した列の説明。\n' >>"$H/brain/review/評価/_テンプレート.md"
git -C "$H/brain" add -A >/dev/null && git -C "$H/brain" commit -qm owner2 >/dev/null
ans0="$(cat "$H/brain/Aoi/21_読み直しの答え.md")"; tmpl0="$(cat "$H/brain/review/評価/_テンプレート.md")"
NEXT93="$TMP/kit-next93"
mkdir -p "$NEXT93"
while IFS= read -r -d '' f; do
  mkdir -p "$NEXT93/$(dirname "$f")"
  cp "$KIT/$f" "$NEXT93/$f"
done < <(git -C "$KIT" ls-files --cached --others --exclude-standard -z)
for f in partner/21_読み直しの答え.md partner/20_振り返り.md review/規準.md review/評価/_テンプレート.md review/読み直し/README.md; do
  printf '\n次の版の行。\n' >>"$NEXT93/brain-template/$f"
done
HOME="$H" bash "$NEXT93/install.sh" --update --no-worktrees </dev/null >"$H.next" 2>&1
check "雛形: 次の版への更新が 0" test $? -eq 0
check "雛形: 持ち主の答えに触らない" test "$ans0" = "$(cat "$H/brain/Aoi/21_読み直しの答え.md")"
check "雛形: 振り返りの表に触らない（次の版でも）" test "$furi0" = "$(cat "$H/brain/Aoi/20_振り返り.md")"
check "雛形: 規準に触らない（次の版でも）" test "$kijun0" = "$(cat "$H/brain/review/規準.md")"
check "雛形: 持ち主の .new を作らない" test ! -e "$H/brain/Aoi/21_読み直しの答え.md.new"
check "雛形: 手で直した採点表の雛形は上書きしない" test "$tmpl0" = "$(cat "$H/brain/review/評価/_テンプレート.md")"
check "雛形: 手で直した採点表の雛形は .new に" grep -q '次の版の行。' "$H/brain/review/評価/_テンプレート.md.new"
check "雛形: 直していない使い方は上がる" grep -q '次の版の行。' "$H/brain/review/読み直し/README.md"

section "止まっている仕事（工程表と --doctor）"
H="$TMP/stalled"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --repos "example/app" --projects "app" --no-worktrees --yes </dev/null >"$H.install" 2>&1
check "停滞: 新規導入が 0" test $? -eq 0
mkdir -p "$TMP/fakegh"
printf '#!/bin/sh\nexec python3 "%s/fakegh/gh.py" "$@"\n' "$TMP" >"$TMP/fakegh/gh"
chmod +x "$TMP/fakegh/gh"
cat >"$TMP/fakegh/gh.py" <<'PY'
import datetime, json, os, sys
args = sys.argv[1:]
mode = os.environ.get("FAKE_GH_MODE")
if args == ["--version"]:
    print("gh version 2.0")
    sys.exit(0)
if args == ["auth", "status"]:
    sys.exit(1 if mode == "noauth" else 0)
if args[:2] == ["label", "list"]:
    print("from-chat\nneeds-triage\nagent-ready\nagent-working\nquestion\nren\nmio\nsora")
    sys.exit(0)
assert args[:2] in (["issue", "list"], ["pr", "list"]), args
if mode == "offline":
    print("読めない", file=sys.stderr)
    sys.exit(1)
if args[args.index("--state") + 1] == "merged":
    print("[]")
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
def item(n, labels, hours, draft=False, decision=""):
    return {"number": n, "title": "Item %d" % n,
            "url": "https://github.com/example/app/%s/%d" % ("issues" if n < 40 else "pull", n),
            "labels": [{"name": label} for label in labels],
            "updatedAt": (now - datetime.timedelta(hours=hours)).isoformat().replace("+00:00", "Z"),
            "isDraft": draft, "reviewDecision": decision}
if args[0] == "issue":
    result = [item(12, ["ren"], 30), item(13, ["agent-working"], 1),
              item(14, [], 100), item(15, ["question"], 100)]
else:
    assert "reviewDecision" in args[args.index("--json") + 1]
    result = [item(40, ["sora"], 30), item(41, [], 50, decision="APPROVED"),
              item(42, ["mio"], 50), item(43, ["sora"], 50, draft=True, decision="APPROVED")]
print(json.dumps(result))
PY
python3 - "$H" <<'PY'
import os, pathlib, re, sys, time
home = pathlib.Path(sys.argv[1])
for pid, hours in (("ren", 40), ("sora", 0)):
    enc = re.sub(r"[^A-Za-z0-9]", "-", str(home / ("brain-" + pid)))
    p = home / ".claude/projects" / enc / "s.jsonl"
    p.parent.mkdir(parents=True)
    p.write_text("")
    at = time.time() - hours * 3600
    os.utime(str(p), (at, at))
PY
stall_collect() { PATH="$TMP/fakegh:$PATH" HOME="$H" python3 "$H/.claude/brain-kit/dashboard/collect.py" --brain "$H/brain" "$@"; }
stall_collect --out "$H.board.json" >"$H.collect" 2>&1
check "停滞: 集計が 0" test $? -eq 0
python3 - "$H.board.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["stalled"]
assert s["hours"] == 24
assert {(i["kind"], i["number"]) for i in s["items"] if i["kind"] != "session"} == {("issue", 12), ("pr", 40), ("pr", 41)}
assert {i["id"] for i in s["items"] if i["kind"] == "session"} == {"ren", "mio"}
assert "app#12" in s["line"]
PY
check "停滞: issue・PR・セッションを区別し下書きを除く" test $? -eq 0
check "停滞: ファイル出力時も 1 行伝える" grep -q '止まっている' "$H.collect"
BRAIN_KIT_STALL_HOURS=60 stall_collect --out - >"$H.board.json" 2>"$H.collect"
python3 - "$H.board.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["stalled"]
assert s["hours"] == 60
assert [(i["kind"], i.get("id")) for i in s["items"]] == [("session", "mio")]
PY
check "停滞: 環境変数 60 と標準出力の JSON" test $? -eq 0
check "停滞: 標準出力時は 1 行を標準エラーへ" grep -q '止まっている' "$H.collect"
BRAIN_KIT_STALL_HOURS=60 stall_collect --stall-hours 0.5 --out "$H.board.json" >/dev/null
python3 - "$H.board.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["stalled"]
assert s["hours"] == 0.5
assert {i["number"] for i in s["items"] if i["kind"] == "issue"} == {12, 13}
PY
check "停滞: 引数が環境変数より優先" test $? -eq 0
cp "$H/brain/.brain-kit/config.json" "$H.config"
python3 - "$H/brain/.brain-kit/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p)); c["stall_hours"] = 45
with open(p, "w") as f:
    json.dump(c, f)
PY
stall_collect --out "$H.board.json" >/dev/null
python3 - "$H.board.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["stalled"]
assert s["hours"] == 45
assert [(i["kind"], i.get("number"), i.get("id")) for i in s["items"]] == [("pr", 41, None), ("session", None, "mio")]
PY
check "停滞: 設定 45 では PR 41 と記録なしだけ" test $? -eq 0
BRAIN_KIT_STALL_HOURS=60 stall_collect --out "$H.board.json" >/dev/null
check "停滞: 環境変数が設定より優先" python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["stalled"]["hours"] == 60' "$H.board.json"
cp "$H.config" "$H/brain/.brain-kit/config.json"
python3 -B - "$KIT" "$H" <<'PY'
import datetime, importlib.util, json, os, pathlib, re, subprocess, sys
kit, home = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("collect", str(kit / "claude/brain-kit/dashboard/collect.py"))
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
for invalid in (None, "", "bad", 0, -1, "nan", "inf"):
    assert c.stall_hours({"stall_hours": 45}, invalid, {"BRAIN_KIT_STALL_HOURS": "60"}) == 60
    assert c.stall_hours({"stall_hours": 45}, invalid, {"BRAIN_KIT_STALL_HOURS": "bad"}) == 45
    assert c.stall_hours({"stall_hours": invalid}, invalid, {}) == 24
cfg = json.loads((home / "brain/.brain-kit/config.json").read_text())
cfg["brain"] = str(home / "different")
now = datetime.datetime.now(datetime.timezone.utc)
def issue(n, at):
    return {"number": n, "title": "Item %d" % n, "url": "https://github.com/example/app/issues/%d" % n,
            "updatedAt": at, "labels": [{"name": "ren"}]}
work = {"example/app": {"issues": [issue(1, "bad"), issue(2, None),
    issue(3, (now - datetime.timedelta(hours=24)).isoformat()),
    issue(4, (now + datetime.timedelta(hours=1)).isoformat())], "prs": []}}
assert not [i for i in c.find_stalled(cfg, str(home / "brain"), work, 24, now)["items"] if i["kind"] == "issue"]
assert c.find_stalled(cfg, str(home / "brain"), {}, 24, now)["items"] == []
old = (now - datetime.timedelta(hours=30)).isoformat().replace("+00:00", "Z")
work["example/app"]["issues"] = [issue(n, old) for n in range(1, 8)]
s = c.find_stalled(cfg, str(home / "brain"), work, 24, now)
assert "app#5…ほか 2 件" in s["line"] and "app#6" not in s["line"]
assert {i["id"] for i in s["items"] if i["kind"] == "session"} == {"ren"}
claude_dir = home / "session-check"
enc = re.sub(r"[^A-Za-z0-9]", "-", str(home / "brain-ren"))
directory = claude_dir / "projects" / enc
directory.mkdir(parents=True)
for name, hours in (("old.jsonl", 80), ("last.jsonl", 30), ("other.txt", 0), ("nested/new.jsonl", 0)):
    p = directory / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text("")
    stamp = now.timestamp() - hours * 3600
    os.utime(str(p), (stamp, stamp))
at = c.last_session(str(home / "brain"), "ren", "dev", str(claude_dir))
assert abs((now - at).total_seconds() - 30 * 3600) < 1
calls = []
def gh(args, timeout):
    calls.append((args, timeout))
    return []
c.gh = gh
assert c.fetch("example/app", timeout=20) == {"issues": [], "prs": []}
assert len(calls) == 2 and all(t == 20 for _, t in calls)
assert "reviewDecision" in calls[1][0][-1]
assert "merged" in c.fetch("example/app", since="2026-01-01")
def timeout_run(*args, **kwargs):
    raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])
c.subprocess.run = timeout_run
try:
    # 実際の gh 関数でも時間切れが呼び出し側へ渡る。
    spec.loader.exec_module(c)
    c.fetch("example/app", timeout=20)
    raise AssertionError("時間切れにならない")
except subprocess.TimeoutExpired:
    pass
PY
check "停滞: 無効値・境界時刻・省略・brain の指定・直下の最新記録・時間切れ" test $? -eq 0
FAKE_GH_MODE=offline stall_collect --out "$H.board.json" >/dev/null
check "停滞: 読めない repo のセッションは判定しない" python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); assert s["errors"] and not s["stalled"]["items"]' "$H.board.json"
# 開発のラベルが無く agent-working か agent-ready だけの issue も、開発の待っている仕事に数える
python3 -B - "$KIT" "$H" <<'PY'
import datetime, importlib.util, json, pathlib, sys
kit, home = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("collect", str(kit / "claude/brain-kit/dashboard/collect.py"))
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
cfg = json.loads((home / "brain/.brain-kit/config.json").read_text())
now = datetime.datetime.now(datetime.timezone.utc)
for label in ("agent-working", "agent-ready"):
    issue = {"number": 70, "title": "Item 70", "url": "https://github.com/example/app/issues/70",
             "updatedAt": now.isoformat().replace("+00:00", "Z"), "labels": [{"name": label}]}
    work = {"example/app": {"issues": [issue], "prs": []}}
    s = c.find_stalled(cfg, str(home / "brain"), work, 24, now, str(home / "no-sessions"))
    sessions = [i for i in s["items"] if i["kind"] == "session"]
    assert [(i["id"], i["work"]) for i in sessions] == [("ren", 1)], (label, sessions)
PY
check "停滞: agent-working・agent-ready だけの issue でも開発のセッションを止まった扱いにする" test $? -eq 0

rm -rf "$KIT/claude/brain-kit/dashboard/__pycache__"
before="$(snap "$H")"
PATH="$TMP/fakegh:$PATH" new "$H" --doctor >"$H.doctor" 2>&1
check "停滞: doctor が 0" test $? -eq 0
check "停滞: doctor は kit の側に .pyc を作らない" test ! -e "$KIT/claude/brain-kit/dashboard/__pycache__"
check "停滞: doctor の節" grep -q '\[止まっている仕事\]' "$H.doctor"
check "停滞: doctor の issue" grep -q '作業中の issue.*app#12' "$H.doctor"
check "停滞: doctor の PR" grep -q 'レビュー済みで未リリースの PR.*app#41' "$H.doctor"
check "停滞: doctor の開発" grep -q 'セッション Ren.*止まっている' "$H.doctor"
check "停滞: doctor のレビュー" grep -q 'セッション Mio.*記録なし' "$H.doctor"
check "停滞: doctor の次にやること" grep -q '止まっている仕事を確かめる' "$H.doctor"
PATH="$TMP/fakegh:$PATH" new "$H" --doctor --stall-hours 60 >"$H.doctor60" 2>&1
check "停滞: doctor に引数を渡せる" test $? -eq 0
check "停滞: doctor の閾値 60" grep -q '60 時間以上動きなし' "$H.doctor60"
check "停滞: doctor の閾値で開発も OK" grep -q 'セッション Ren.*OK' "$H.doctor60"
new "$H" --doctor >"$H.nogh" 2>&1
check "停滞: gh が無くても 0" test $? -eq 0
check "停滞: gh 無しの注記" grep -q 'GitHub.*飛ばした.*gh が無い' "$H.nogh"
check "停滞: gh 無しのセッションは参考" grep -q 'セッション Ren.*参考' "$H.nogh"
FAKE_GH_MODE=offline PATH="$TMP/fakegh:$PATH" new "$H" --doctor >"$H.offline" 2>&1
check "停滞: 通信できなくても 0" test $? -eq 0
check "停滞: 通信失敗の注記" grep -q '飛ばした.*読めない' "$H.offline"
FAKE_GH_MODE=noauth PATH="$TMP/fakegh:$PATH" new "$H" --doctor >"$H.noauth" 2>&1
check "停滞: 未認証でも 0" test $? -eq 0
check "停滞: 未認証の注記" grep -q '飛ばした.*未認証' "$H.noauth"
check "停滞: doctor はファイルを変えない" test "$before" = "$(snap "$H")"
check "停滞: 工程表の一覧" grep -q 'id="stalled"' "$KIT/claude/brain-kit/dashboard/index.html"
check "停滞: 工程表は新しい集計を読む" grep -q 'b\.stalled' "$KIT/claude/brain-kit/dashboard/index.html"

# ------------------------------------------------------------------ 全人格を 1 回だけ起動
section "start-all（偽の端末・プロセス一覧）"
H="$TMP/start-all"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.install" 2>&1
check "一括起動: install が 0" test $? -eq 0
check "一括起動: 実行可能" test -x "$H/.claude/brain-kit/bin/start-all"
python3 - "$H" "$SAFE_PATH" "$BASH" "$KIT" <<'PY'
import json, os, pathlib, runpy, signal, subprocess, sys, time
h, safe, bash, kit = sys.argv[1:]
h = pathlib.Path(h)
script = h / ".claude/brain-kit/bin/start-all"
text = script.read_text()
assert str(h) not in text
ids = ("aoi", "ren", "mio", "sora")
assert all("start-" + i in text for i in ids)
bin_dir = h / "fake-bin"
bin_dir.mkdir()
state = h / "state"
state.mkdir()
# PATH の偽物だけが起動する。端末の子も同じ bash と PATH を使う。
fake = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
s = pathlib.Path(os.environ["START_STATE"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "ps":
    assert args == ["-Ao", "pid=,args="]
    print((s / "procs").read_text(), end="")
elif name == "uname":
    print(os.environ.get("START_OS", "Linux"))
elif name == "claude":
    ident = args[-1].lstrip("/")
    if (s / ("never-" + ident)).exists():
        sys.exit(0)
    if (s / ("slow-" + ident)).exists():
        time.sleep(2)
    with (s / "procs").open("a") as f:
        f.write("%d claude %s\n" % (os.getpid(), " ".join(args)))
else:
    with (s / "log").open("a") as f:
        f.write(json.dumps([name] + args) + "\n")
    if name == "tmux":
        if args[0] in ("list-sessions", "has-session"):
            sys.exit(0 if (s / "session").exists() else 1)
        if args[0] == "capture-pane":
            p = s / ("pane-" + args[-1].split(":")[-1])
            print(p.read_text() if p.exists() else "")
            sys.exit(0)
        assert args[0] in ("new-session", "new-window")
        (s / "session").touch()
        with (s / "windows").open("a") as f:
            f.write(args[args.index("-n") + 1] + "\n")
        cmd = args[-1]
    elif name == "osascript":
        # AppleScript の文字列を解き、shell の引用も実際に通す。
        import re
        match = re.search(r'(?:do script|write text) "((?:\\.|[^"\\])*)"', args[-1])
        assert match, args
        cmd = re.sub(r'\\(.)', r'\1', match[1])
    else:
        assert "-lc" in args
        cmd = args[-1]
    p = subprocess.Popen([os.environ["START_BASH"], "-c", cmd],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    with (s / "children").open("a") as f:
        f.write(str(p.pid) + "\n")
'''
env = dict(os.environ, HOME=str(h), PATH=str(bin_dir) + os.pathsep + safe,
           START_STATE=str(state), START_BASH=bash)
for key in ("TMUX", "DISPLAY", "WAYLAND_DISPLAY", "WSL_DISTRO_NAME", "TERM_PROGRAM",
            "BRAIN_KIT_START_WITH", "BRAIN_KIT_TMUX_SESSION", "CLAUDE_CONFIG_DIR"):
    env.pop(key, None)

def tool(name):
    p = bin_dir / name
    p.write_text(fake)
    p.chmod(0o755)

for name in ("ps", "uname", "claude"):
    tool(name)

def clean_children():
    p = state / "children"
    if p.exists():
        for pid in p.read_text().splitlines():
            try:
                os.killpg(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        p.unlink()

def reset():
    clean_children()
    for p in state.iterdir():
        p.unlink()
    (state / "procs").write_text("")
    (state / "log").write_text("")

def run(*args, rc=0, extra=None):
    p = subprocess.run([bash, str(script)] + list(args), env=dict(env, **(extra or {})),
                       capture_output=True, text=True, timeout=12)
    assert p.returncode == rc, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout

def log():
    return [json.loads(l) for l in (state / "log").read_text().splitlines()]

def starts():
    return [l for l in log() if l[0] == "tmux" and l[1] in ("new-session", "new-window")]

def four(out, state_text):
    assert sum(state_text in l and "\t/" in l for l in out.splitlines()) == 4, out

try:
    tool("tmux")
    reset()
    out = run("--tmux", "--wait", "5")
    four(out, "起動した")
    assert len(starts()) == 4 and (state / "windows").read_text().splitlines() == list(ids)
    assert starts()[0][1] == "new-session" and all(l[1] == "new-window" for l in starts()[1:])
    assert "tmux attach -t" in out and "Ctrl-b" in out
    # --no-worktrees は同じフォルダなので信頼の案内も 1 回だけ。
    assert out.count("初回のフォルダ確認") == 1
    four(run("--tmux", "--wait", "0"), "すでに動いていた")
    assert len(starts()) == 4
    before = log()
    four(run("--status"), "すでに動いていた")
    assert log() == before
    print("  起動・二度目・status: ok")

    reset()
    (state / "slow-ren").touch()
    start = time.monotonic()
    four(run("--tmux", "--wait", "6"), "起動した")
    assert 2 <= time.monotonic() - start < 9 and len(starts()) == 4
    assert sum(l[l.index("-n") + 1] == "ren" for l in starts()) == 1
    reset()
    (state / "never-mio").touch()
    out = run("--tmux", "--wait", "2", rc=1)
    assert "まだ見えない" in out and "start-all --status" in out
    assert len(starts()) == 4 and sum(l[l.index("-n") + 1] == "mio" for l in starts()) == 1
    before = log()
    run("--status", rc=1)
    assert log() == before
    print("  遅延・不在でも各 1 回: ok")

    reset()
    for ident in ids[1:]:
        (h / ("brain-" + ident)).mkdir()
    (h / ".claude.json").write_text(json.dumps({"projects": {
        str(h / "brain"): {"hasTrustDialogAccepted": True},
        str(h / "brain-ren"): {"hasTrustDialogAccepted": True}}}))
    (state / "pane-mio").write_text("Do you trust the files in this folder?")
    out = run("--tmux", "--wait", "5")
    assert "tmux ウィンドウ mio: 初回" in out and "tmux ウィンドウ sora: 初回" in out
    assert "tmux ウィンドウ aoi: 初回" not in out and "tmux ウィンドウ ren: 初回" not in out
    assert "接続してウィンドウ mio に移り、Yes で Enter" in out
    four(out, "起動した")
    reset()
    config = h / "config-dir"
    config.mkdir()
    (config / ".claude.json").write_text(json.dumps({"projects": {
        str(h / ("brain" if i == "aoi" else "brain-" + i)): {"hasTrustDialogAccepted": True} for i in ids}}))
    assert "初回のフォルダ確認" not in run("--tmux", "--wait", "5", extra={"CLAUDE_CONFIG_DIR": str(config)})
    print("  信頼済み・未信頼・確認待ち・設定先: ok")

    reset()
    out = run("--wait", "5", extra={"TMUX": "fake"})
    assert "起動方法: tmux（tmux の中）" in out and "switch-client" in out and len(starts()) == 4
    reset()
    (state / "session").touch()
    assert "セッションがある" in run("--wait", "5")
    reset()
    assert "セッションを新しく作る" in run("--wait", "5")
    (bin_dir / "tmux").unlink()
    reset()
    tool("gnome-terminal")
    four(run("--wait", "5", extra={"DISPLAY": "fake"}), "起動した")
    assert sum(l[0] == "gnome-terminal" for l in log()) == 4
    (bin_dir / "gnome-terminal").unlink()
    for terminal in ("konsole", "xfce4-terminal", "wt.exe"):
        reset()
        tool(terminal)
        extra = {"WAYLAND_DISPLAY": "fake"} if terminal != "wt.exe" else {"WSL_DISTRO_NAME": "test-distro"}
        four(run("--wait", "5", extra=extra), "起動した")
        assert len(log()) == 4 and all(l[0] == terminal for l in log())
        (bin_dir / terminal).unlink()
    reset()
    tool("osascript")
    out = run("--wait", "5", extra={"START_OS": "Darwin"})
    four(out, "起動した")
    assert "Terminal.app" in out and len(log()) == 4
    reset()
    four(run("--tabs", "--wait", "5", extra={"START_OS": "Darwin", "TERM_PROGRAM": "iTerm.app"}), "起動した")
    assert len(log()) == 4 and all('tell application "iTerm2"' in l[-1] for l in log())
    (bin_dir / "osascript").unlink()
    print("  自動検出・全端末のコマンド: ok")

    reset()
    out = run()
    assert "起動方法: print" in out and not log()
    assert all(str(h / (".claude/brain-kit/bin/start-" + i)) in out for i in ids)
    assert "start-all --status" in out
    run("--tmux", rc=2)
    run("--tabs", rc=2)
    run("--wait", "bad", rc=2)
    run("--wait", rc=2)
    run("--help")
    tool("tmux")
    assert "起動方法: print" in run(extra={"BRAIN_KIT_START_WITH": "print"})
    assert "起動方法: print" in run("--print", extra={"TMUX": "fake"})
    assert not log()
    # 最後の単語以外の /id や claude を含まない行は数えない。
    (state / "procs").write_text("1 claude /aoi extra\n2 other /ren\n3 claude /mio-other\n4 claude /sora\n")
    out = run("--status", rc=1)
    assert out.count("\tまだ見えない") == 3 and out.count("\tすでに動いていた") == 1
    assert not log()
    print("  print・指定の失敗・引数・厳密なプロセス判定: ok")

    # 日本語・引用符・shell の記号をデータとして保つ。未導入の役は出さない。
    k = runpy.run_path(str(pathlib.Path(kit) / "lib/kit.py"))
    generate = k["gen_start_all"]
    generate.__globals__["HOME"] = str(h)
    unusual = h / "brain ' \" \\ $(false)"
    unusual.mkdir()
    display = "葵 ' \" $(false)"
    cfg = {"brain": str(unusual), "personas": {"partner": {"id": "aoi", "name": display}}}
    generated = generate(cfg)
    assert str(h) not in generated and "start-ren" not in generated
    script.write_text(generated)
    reset()
    out = run("--tmux", "--wait", "5", extra={"BRAIN_KIT_TMUX_SESSION": "test-room"})
    assert display in out and "\t/aoi\t起動した" in out and len(starts()) == 1
    assert starts()[0][starts()[0].index("-c") + 1] == str(unusual)
    assert starts()[0][starts()[0].index("-s") + 1] == "test-room"
    reset()
    (bin_dir / "tmux").unlink()
    tool("osascript")
    assert "\t/aoi\t起動した" in run("--tabs", "--wait", "5", extra={"START_OS": "Darwin"})
    assert len(log()) == 1
    print("  日本語・引用符・未導入の役・セッション名: ok")
finally:
    script.write_text(text)
    clean_children()
PY
check "一括起動: 各 1 回・遅延・不在・信頼・status・検出・手動案内" test $? -eq 0

H="$TMP/start-all-old"
old_install 62952c7 "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes
check "一括起動: 前の kit には無い" test ! -e "$H/.claude/brain-kit/bin/start-all"
new "$H" --update --no-worktrees >"$H.up" 2>&1
check "一括起動: 前の kit から更新が 0" test $? -eq 0
check "一括起動: 更新で実行可能なファイルを追加" test -x "$H/.claude/brain-kit/bin/start-all"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "一括起動: uninstall が 0" test $? -eq 0
check "一括起動: uninstall で削除" test ! -e "$H/.claude/brain-kit/bin/start-all"

# ------------------------------------------------------------------ 初日の練習（本物のプロジェクトには触らない）
section "任意のローカル練習"
H="$TMP/practice-home"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --no-worktrees --yes </dev/null >"$H.log" 2>&1
check "練習: 新規導入が 0" test $? -eq 0
check "練習: --yes 導入では自動実行しない" test ! -e "$H/brain-kit-practice"
check "練習: 任意の案内を表示" grep -q '初日の練習（任意）: ./install.sh --practice' "$H.log"
before="$(snap "$H")"; c0="$(commits "$H")"
new "$H" --practice </dev/null >"$H.practice" 2>&1
check "練習: 非対話で完走" test $? -eq 0
check "練習: brain と ~/.claude はバイト不変" test "$before" = "$(snap "$H")"
check "練習: brain のコミット数は不変" test "$c0" = "$(commits "$H")"
python3 - "$H" "$KIT" <<'PY'
# 練習の検証。本物のプロジェクトには触らない。
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
h, kit = map(Path, sys.argv[1:])
sys.dont_write_bytecode = True
r = h / "brain-kit-practice"
load = lambda p: json.loads(p.read_text())
assert load(r / "state.json")["step"] == 6
assert load(r / "issues/1.json")["state"] == "closed"
pr = load(r / "prs/1.json")
assert pr["state"] == "merged"
board = load(r / "board.json")
assert {s["key"]: s["count"] for s in board["stages"]} == dict(filed=0, decide=0, dev=0, review=0, release=0, prod=1)
assert set(board) == {"collected_at", "repos", "stages", "items", "owner_auto", "prod_since", "errors"}
assert board["repos"] == ["practice"] and board["errors"] == []
assert board["items"][0]["kind"] == "pr"
for role in ("dev", "review", "release"):
    assert (r / "records" / (role + ".md")).is_file()
    label = load(h / "brain/.brain-kit/config.json")["personas"][role]["label"]
    assert label in (r / "issues/1.json").read_text() + (r / "prs/1.json").read_text()
fixed = subprocess.check_output(["git", "-C", str(r / "remote.git"), "show", "main:greet.sh"], text=True)
assert subprocess.check_output(["sh", "-c", fixed, "practice", "練習"], text=True).strip() == "こんにちは、練習"
assert subprocess.check_output(["git", "-C", str(r / "remote.git"), "log", "-1", "--format=%an <%ae>"], text=True).strip() == "practice <practice@example.invalid>"
# 練習の盤面を、実際の collect.py に同じ入力を渡した結果と突き合わせる。
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
practice = module("practice", kit / "lib/practice.py")
collect = module("collect", kit / "claude/brain-kit/dashboard/collect.py")
board_root = h / "board-practice"
board_root.mkdir()
session = practice.Practice(board_root, h / "brain")
for labels in ([], ["question"], ["needs-triage", "agent-ready"], ["agent-ready"], ["agent-working"],
               [session.p["dev"]["label"]], [session.p["release"]["label"], "needs-triage"]):
    for state in ("open", "merged"):
        issue = dict(number=1, title="練習", url="practice", labels=labels, updatedAt="練習", state="open")
        pr_item = dict(issue, state=state, mergedAt="練習" if state == "merged" else None)
        session.save("issues", issue)
        session.save("prs", pr_item)
        session.board()
        def fake_read(args, **kwargs):
            item = issue if args[0] == "issue" else pr_item
            wanted = args[args.index("--state") + 1]
            return [dict(item, labels=[{"name": x} for x in labels])] if item["state"] == wanted else []
        collect.gh = fake_read
        out = board_root / "expected.json"
        old = sys.argv
        sys.argv = ["collect", "--brain", str(h / "brain"), "--repos", "practice", "--out", str(out)]
        collect.main()
        sys.argv = old
        actual, expected = load(board_root / "board.json"), load(out)
        assert actual["stages"] == expected["stages"]
        assert [(i["kind"], i["stage"]) for i in actual["items"]] == [(i["kind"], i["stage"]) for i in expected["items"]]
PY
check "練習: 修正・完了状態・記録・設定ラベル・盤面の規則" test $? -eq 0
main0="$(git -C "$H/brain-kit-practice/remote.git" rev-parse main)"
new "$H" --practice </dev/null >"$H.again" 2>&1
check "練習: 完了後の再実行が 0" test $? -eq 0
check "練習: 再実行で main は不変" test "$main0" = "$(git -C "$H/brain-kit-practice/remote.git" rev-parse main)"
new "$H" --practice-status >"$H.status" 2>&1
check "練習: status が 0" test $? -eq 0
check "練習: status に完了した段" grep -q '6/6' "$H.status"

# 練習の安全境界。本物を模したディレクトリは変えない。
python3 - "$H" "$KIT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
h, kit = map(Path, sys.argv[1:])
env = dict(os.environ, HOME=str(h))
def run(*args, ok=False):
    result = subprocess.run(["bash", str(kit / "install.sh")] + list(args), env=env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert (result.returncode == 0) == ok, result.stdout
    return result.stdout
foreign = h / "foreign"
foreign.mkdir()
(foreign / "keep").write_text("練習で消さない。本物の代わり。")
for action in ("--practice", "--practice-cleanup"):
    run(action, "--practice-dir", str(foreign), "--yes")
    assert list(foreign.iterdir()) == [foreign / "keep"]
    assert (foreign / "keep").read_text() == "練習で消さない。本物の代わり。"
(foreign / ".brain-kit-practice").write_text('{"kind":"different"}')
run("--practice-cleanup", "--practice-dir", str(foreign), "--yes")
(foreign / ".brain-kit-practice").write_text('{')
run("--practice", "--practice-dir", str(foreign))
empty = h / "empty"
empty.mkdir()
run("--practice", "--practice-dir", str(empty))
assert not list(empty.iterdir())
run("--practice", "--practice-dir", str(h / "absent-parent/practice"))
assert not (h / "absent-parent").exists()
for path in (h, h.parent, h / "brain", h / "brain/nested", h / ".claude/nested"):
    run("--practice", "--practice-dir", str(path))
# 別の brain を指しても既定の ~/brain は守る（git でない ~/brain でも。git の検査に頼らない）
h2 = h / "plain-home"
(h2 / "brain").mkdir(parents=True)
(h2 / "other-brain").mkdir()
env2 = dict(env, HOME=str(h2))
for action in ("start", "cleanup"):
    if action == "cleanup":
        (h2 / "brain/nested").mkdir()
        (h2 / "brain/nested/.brain-kit-practice").write_text('{"kind": "brain-kit-practice"}')
    result = subprocess.run([sys.executable, str(kit / "lib/practice.py"), action, "--dir", str(h2 / "brain/nested"),
                             "--brain", str(h2 / "other-brain"), "--yes", "--auto"], env=env2,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert result.returncode == 1 and "保護" in result.stdout, result.stdout
assert sorted(x.name for x in (h2 / "brain/nested").iterdir()) == [".brain-kit-practice"]
assert not (h / "brain/nested").exists() and not (h / ".claude/nested").exists()
repo = h / "real-repo"
repo.mkdir()
subprocess.run(["git", "-C", str(repo), "init"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
run("--practice", "--practice-dir", str(repo / "nested/practice"))
assert not (repo / "nested").exists()
# 親が在っても（親の無い場所の柵に頼らず）、既存の git 作業ツリーの中には作らない
(repo / "nested").mkdir()
for target in (repo / "nested/practice", repo / "practice"):
    assert "本物の git 作業ツリーの中" in run("--practice", "--practice-dir", str(target)), target
assert not list((repo / "nested").iterdir()) and not (repo / "practice").exists()
assert subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=all"], env=env,
                      stdout=subprocess.PIPE, text=True).stdout == ""
# 印が symlink なら（指す先が正しい印でも）練習とみなさない。消さない・書かない
real_marker = h / "real-marker.json"
real_marker.write_text('{"kind": "brain-kit-practice"}')
fake = h / "marker-link"
fake.mkdir()
(fake / "keep").write_text("印が symlink の場所。練習で消さない。")
(fake / ".brain-kit-practice").symlink_to(real_marker)
assert "印が無い" in run("--practice-cleanup", "--practice-dir", str(fake), "--yes")
run("--practice", "--practice-dir", str(fake))
assert sorted(x.name for x in fake.iterdir()) == [".brain-kit-practice", "keep"]
assert (fake / ".brain-kit-practice").is_symlink() and real_marker.read_text() == '{"kind": "brain-kit-practice"}'
link = h / "linked-practice"
link.symlink_to(h / "brain-kit-practice", target_is_directory=True)
run("--practice-cleanup", "--practice-dir", str(link), "--yes")
run("--practice", "--practice-dir", str(link))
assert link.is_symlink()
# 練習内の symlink を削除しても、その先は消さない。
(h / "brain-kit-practice/outside").symlink_to(foreign, target_is_directory=True)
run("--practice")
assert "--yes" in run("--practice-cleanup")
# --dry-run は何も消さない（--yes と一緒でも）・何も作らない
before_dry = sorted(str(x) for x in (h / "brain-kit-practice").rglob("*"))
assert "何も消していない" in run("--practice-cleanup", "--dry-run", "--yes", ok=True)
assert sorted(str(x) for x in (h / "brain-kit-practice").rglob("*")) == before_dry
assert "何も作っていない" in run("--practice", "--dry-run", "--practice-dir", str(h / "dry-practice"), ok=True)
assert not (h / "dry-practice").exists()
assert (h / "brain-kit-practice").exists()
run("--practice-cleanup", "--yes", ok=True)
assert not (h / "brain-kit-practice").exists() and (foreign / "keep").exists()
assert "練習用プロジェクトは無い" in run("--practice-cleanup", "--yes", ok=True)
assert "練習用プロジェクトは無い" in run("--practice-status", ok=True)
PY
check "練習: 所有印・保護場所・既存 git・リンク・削除の確認" test $? -eq 0

# 練習の対話中断と再開、別 brain の設定・既定へのフォールバック。
python3 - "$H" "$KIT" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys
h, kit = map(Path, sys.argv[1:])
root, brain = h / "practice interactive", h / "read-only-brain"
brain.mkdir()
(brain / ".brain-kit").mkdir()
config = brain / ".brain-kit/config.json"
config.write_text(json.dumps({"personas": {r: {"name": r, "id": r, "label": "practice-" + r}
                                         for r in ("partner", "dev", "review", "release")}}))
before = config.read_bytes()
env = dict(os.environ, HOME=str(h), BRAIN_DIR=str(brain))
command = [sys.executable, str(kit / "lib/practice.py"), "start", "--dir", str(root)]
master, slave = os.openpty()
try:
    process = subprocess.Popen(command, env=env, stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    os.write(master, b"q\n")
    out, _ = process.communicate(timeout=20)
    assert process.returncode == 0 and "Enter で次へ／q で中断" in out, out
    assert json.loads((root / "state.json").read_text())["step"] == -1
    assert not (root / "remote.git").exists()
    result = subprocess.run(command + ["--auto", "--until", "2"], env=env, stdin=slave,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
    assert result.returncode == 0, result.stdout
finally:
    os.close(master)
    os.close(slave)
assert json.loads((root / "state.json").read_text())["step"] == 2
assert "practice-review" in json.loads((root / "prs/1.json").read_text())["labels"]
assert "practice-dev" in json.loads((root / "issues/1.json").read_text())["labels"]
assert config.read_bytes() == before
# 明示の --brain は環境変数より優先し、読めなければ役名と id を使う。
config.write_text("{")
for suffix, brain_path in (("broken", brain), ("missing", h / "missing-brain")):
    target = h / ("practice-" + suffix)
    result = subprocess.run(["bash", str(kit / "install.sh"), "--practice", "--practice-dir", str(target),
                             "--brain", str(brain_path)], env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert result.returncode == 0, result.stdout
    assert "【開発: 開発（/dev）】" in result.stdout
    assert json.loads((target / "state.json").read_text())["step"] == 6
assert config.read_text() == "{"
PYTEST
check "練習: 対話の q・再開・--auto・別 brain・設定が読めない場合" test $? -eq 0

# 各ガードだけで止まる入力にする。外すとマージできてしまうことも mutation で確認する。
python3 - "$H" "$KIT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
h, kit = map(Path, sys.argv[1:])
env = dict(os.environ, HOME=str(h))
source = (kit / "lib/practice.py").read_text()
h = h.resolve()   # macOS の TMPDIR（/var → /private/var）でも、練習が使う実パスで設定を書く
def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root)] + list(args), env=env, text=True).strip()
def run(script, root, *args):
    return subprocess.run([sys.executable, str(script), "start", "--dir", str(root)] + list(args),
                          env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
INSTR = '        if not instructions or not instructions[-1]["body"].startswith(to_release + "入れてよい"):\n'
HEAD = '        if ok_head != head:\n'
SCRIPT = '        if (path / "test.sh").read_text(encoding="utf-8") != TEST or greet not in (BUG, FIX):\n'
def drop_comment(root, pr, pred):
    pr["comments"] = [c for c in pr["comments"] if not pred(c["body"])]
def add_comment(root, pr, body):
    pr["comments"].append({"by": "練習", "body": body, "at": "練習"})
def push_extra(root, pr):
    (root / "dev-wt/extra.md").write_text("練習の追加変更。本物には触らない。")
    git(root / "dev-wt", "add", "extra.md")
    git(root / "dev-wt", "commit", "-m", "練習: OK 後の追加")
    git(root / "dev-wt", "push", str(root / "remote.git"), pr["branch"])
def rewrite_push(root, pr):
    # 外の bare（本物の代わり）へ push を向け直す設定を、練習の作業ツリーに置く
    subprocess.check_call(["git", "clone", "-q", "--bare", str(root / "remote.git"), str(root.parent / (root.name + "-outside.git"))], env=env)
    git(root / "work", "config", "url." + str(root.parent / (root.name + "-outside.git")) + ".pushInsteadOf", str(root / "remote.git"))
def outside_worktree(root, pr):
    # 作業ツリーを外（本物の代わり）へ向け直す設定を置く。再開しても外のファイルは変えない
    out = root.parent / (root.name + "-outside-wt")
    out.mkdir()
    for f in ("greet.sh", "test.sh"):   # main と同じ中身（外が「本物」で、merge が上書きできる状態）
        (out / f).write_bytes((root / "work" / f).read_bytes())
        os.chmod(str(out / f), 0o755)
    git(root / "work", "config", "core.worktree", str(out))
def edit_test(root, pr):
    with open(str(root / "review-wt/test.sh"), "a") as f:
        f.write("touch ../escaped\n")
# 名前: (入力の作り方, 止まるときの文言, mutation で外す行と置き換え)
GUARDS = {
    "instruction": (lambda r, pr: drop_comment(r, pr, lambda b: "へ：入れてよい" in b), "指示コメントが無い",
                    (INSTR, "        if False:\n")),
    "withdrawn": (lambda r, pr: add_comment(r, pr, "Soraへ：待って（練習）"), "指示コメントが無い",
                  (INSTR, '        if not [c for c in pr["comments"] if c["body"].startswith(to_release + "入れてよい")]:\n')),
    "verdict-ng": (lambda r, pr: add_comment(r, pr, "判定: NG\n1. 練習の指摘"), "OK の head と現在の PR head が違う",
                   ('        ok_head = last.splitlines()[1][5:] if last.startswith("判定: OK\\nhead ") else None\n',
                    '        ok_head = head\n')),
    "head": (push_extra, "OK の head と現在の PR head が違う", (HEAD, "        if False:\n")),
    "rewrite": (rewrite_push, "URL の書き換え設定がある",
                ('            if rewrites:\n', '            if False:\n')),
    "worktree": (outside_worktree, "git の作業ツリーが練習の外",
                 ('                    if top.returncode != 0 or Path(top.stdout.strip()).resolve() != repo.resolve():\n',
                  '                    if False:\n')),
    "script": (edit_test, "練習のスクリプトが書き換えられている", (SCRIPT, "        if False:\n")),
}
for guard, (setup, message, (old, repl)) in sorted(GUARDS.items()):
    for mutation in (False, True):
        root = h / ("practice-" + guard + ("-mutation" if mutation else ""))
        script = kit / "lib/practice.py"
        if mutation:
            assert source.count(old) == 1, guard
            script = h / ("practice-mutated-" + guard + ".py")
            script.write_text(source.replace(old, repl))
        first = run(script, root, "--until", "4")
        assert first.returncode == 0, first.stdout
        before = git(root / "remote.git", "rev-parse", "main")
        pr_path = root / "prs/1.json"
        pr = json.loads(pr_path.read_text())
        setup(root, pr)
        pr_path.write_text(json.dumps(pr, ensure_ascii=False))
        result = run(script, root)
        after = git(root / "remote.git", "rev-parse", "main")
        if mutation:
            # ガードを外すと先へ進んでしまう（script は外へ書く・それ以外はマージされる）
            if guard == "script":
                assert (root / "escaped").exists(), result.stdout
            elif guard == "worktree":
                out = root.parent / (root.name + "-outside-wt")
                assert '"$1"' in (out / "greet.sh").read_text(), result.stdout   # 外の greet.sh が merge で書き換わる
            elif guard == "rewrite":
                outside = root.parent / (root.name + "-outside.git")
                assert git(outside, "rev-parse", "main") != before, result.stdout
            else:
                assert result.returncode == 0 and before != after, (guard, result.stdout)
        else:
            assert result.returncode == 1 and before == after, (guard, result.stdout)
            assert message in result.stdout, (guard, result.stdout)
            assert not (root / "escaped").exists()
            if guard == "worktree":
                assert '"$1"' not in (root.parent / (root.name + "-outside-wt") / "greet.sh").read_text()
            if guard == "rewrite":
                assert git(root.parent / (root.name + "-outside.git"), "rev-parse", "main") == before
            assert json.loads((root / "state.json").read_text())["step"] == 4
# マージ済みと書いた直後に落ちても、再実行で後始末だけ続く（ラベルが外れていても止まらない）
root = h / "practice-resume-release"
assert run(kit / "lib/practice.py", root, "--until", "4").returncode == 0
crash = h / "practice-crash.py"
crash.write_text(source.replace("        self.save(\"prs\", pr)\n        self.finish_release(pr)\n",
                                "        self.save(\"prs\", pr)\n        raise RuntimeError(\"練習の故障の注入\")\n"))
assert crash.read_text() != source
first = run(crash, root)
assert first.returncode == 1 and "故障の注入" in first.stdout, first.stdout
assert json.loads((root / "prs/1.json").read_text())["state"] == "merged"
assert json.loads((root / "state.json").read_text())["step"] == 4
merged = git(root / "remote.git", "rev-parse", "main")
again = run(kit / "lib/practice.py", root)
assert again.returncode == 0, again.stdout
assert json.loads((root / "state.json").read_text())["step"] == 6
assert json.loads((root / "issues/1.json").read_text())["state"] == "closed"
assert git(root / "remote.git", "rev-parse", "main") == merged
assert "入った practice#1" in (root / "records/release.md").read_text()
# squash の前に落ち、そのあと関係ないコミットで main が進んでも「入った」と言わない（ガードを外すと言ってしまう）
SQUASH = ('        if after == before or self.git(self.work, "rev-parse", "main^") != before or \\\n'
          '                self.git(self.work, "rev-parse", "main^{tree}") != self.git(self.work, "rev-parse", head + "^{tree}"):\n')
assert source.count(SQUASH) == 1
for mutation in (False, True):
    root = h / ("practice-unrelated" + ("-mutation" if mutation else ""))
    script = kit / "lib/practice.py"
    if mutation:
        script = h / "practice-mutated-squash.py"
        script.write_text(source.replace(SQUASH, "        if after == before:\n"))
    assert run(script, root, "--until", "4").returncode == 0
    crash = h / ("practice-crash-before-squash%s.py" % ("-m" if mutation else ""))
    old = '            self.git(self.work, "merge", "--squash", head)\n'
    crash.write_text(script.read_text().replace(old, '            raise RuntimeError("練習の故障の注入")\n'))
    assert run(crash, root).returncode == 1
    (root / "work/note.md").write_text("関係ない変更。練習。")
    git(root / "work", "add", "note.md")
    git(root / "work", "commit", "-m", "練習: 関係ないコミット")
    before = git(root / "remote.git", "rev-parse", "main")
    result = run(script, root)
    issue = json.loads((root / "issues/1.json").read_text())
    if mutation:
        assert result.returncode == 0 and issue["state"] == "closed", result.stdout
    else:
        assert result.returncode == 1 and "squash ではない" in result.stdout, result.stdout
        assert issue["state"] == "open" and json.loads((root / "prs/1.json").read_text())["state"] == "open"
        assert git(root / "remote.git", "rev-parse", "main") == before
PY
check "練習: 指示欠落・取り消し・NG・OK 後の head 変更・書き換えたスクリプトで停止（各ガードの mutation も検証）" test $? -eq 0

# ------------------------------------------------------------------ 要約のあとの核の読み直し
section "要約のあとの核の読み直し（4 人格・入力・停止）"
H="$TMP/core-reread"
mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --yes </dev/null >"$H.log" 2>&1
check "核: install が 0" test $? -eq 0
check "核: スクリプトは実行可能" test -x "$H/.claude/hooks/brain-kit-core-reread.py"
python3 - "$H" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, time
h = pathlib.Path(sys.argv[1])
brain = h / "brain"
hook = h / ".claude/hooks/brain-kit-core-reread.py"
text = hook.read_text(encoding="utf-8")
# HOME に // が混ざる環境（macOS の TMPDIR）では ~ の形にならず、絶対パスで埋まる
assert "<brain>" not in text
brain_path = h / ".claude/brain-kit/brain-path"
assert brain_path.read_text() in ("~/brain\n", os.path.abspath(str(brain)) + "\n")
command = 'python3 "$HOME/.claude/hooks/brain-kit-core-reread.py"'
group = {"matcher": "compact", "hooks": [{"type": "command", "command": command, "timeout": 10}]}
s = json.loads((h / ".claude/settings.json").read_text())
assert [g for g in s["hooks"]["SessionStart"] if any(
    x.get("command") == command for x in g["hooks"])] == [group]
m = json.loads((h / ".claude/brain-kit/manifest.json").read_text())
assert m["settings"]["hooks.SessionStart"][command] == hashlib.sha256(
    json.dumps(group, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
assert m["files"][".claude/hooks/brain-kit-core-reread.py"]["sha"] == hashlib.sha256(hook.read_bytes()).hexdigest()
assert m["files"][".claude/brain-kit/brain-path"]["sha"] == hashlib.sha256(brain_path.read_bytes()).hexdigest()
roles = [
    ("相棒", "Aoi", "brain", ["Aoi/00_核.md", "Aoi/02_関係.md"]),
    ("開発", "Ren", "brain-ren", ["dev/00_核.md"]),
    ("レビュー", "Mio", "brain-mio", ["review/00_核.md", "review/規準.md"]),
    ("リリース", "Sora", "brain-sora", ["release/00_核.md", "release/手順.md"]),
]
contents = {}
for _, _, directory, paths in roles:
    assert (h / directory / ".git").exists()
    for path in paths:
        contents[path] = "main にだけある核: " + path + "\n"
        (brain / path).write_text(contents[path], encoding="utf-8")
subprocess.run(["git", "-C", str(brain), "add", "--"] + list(contents), check=True)
subprocess.run(["git", "-C", str(brain), "commit", "-qm", "核の読み直しの見本"], check=True)
env = dict(os.environ, HOME=str(h))
env.pop("BRAIN_KIT_NO_CORE_REREAD", None)

def run(raw, cwd=brain, extra=None):
    result = subprocess.run([sys.executable, str(hook)], input=raw, cwd=str(cwd),
                            env=dict(env, **(extra or {})), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=1)
    assert result.returncode == 0 and result.stderr == b"", result
    return result.stdout.decode("utf-8")

def compact(cwd):
    # 実際の cwd は HOME にして、入力 JSON の cwd が優先されることも確かめる。
    return run(json.dumps({"source": "compact", "cwd": str(cwd)}).encode(), cwd=h)

def expected(role, name, paths):
    return ("文脈の要約のあと、%s %s の核を読み直す（brain-kit のフック）。\n" % (role, name)
            + "".join("--- %s ---\n%s" % (p, contents[p]) for p in paths))

for role, name, directory, paths in roles:
    want = expected(role, name, paths)
    assert compact(h / directory) == want, directory
    sub = h / directory / "subdir"
    sub.mkdir()
    assert compact(sub) == want, str(sub)
    # symlink の別名からも、実体で人格を判定する。
    alias = h / (directory + "-link")
    alias.symlink_to(h / directory, target_is_directory=True)
    assert compact(alias / "subdir") == want
    if directory != "brain":
        assert contents[paths[0]] not in (h / directory / paths[0]).read_text(encoding="utf-8")
for elsewhere in (h, pathlib.Path("/"), h / "brain-renx", h / "brainx"):
    if elsewhere.parent == h:
        elsewhere.mkdir(exist_ok=True)
    assert compact(elsewhere) == "", str(elsewhere)
# 最寄りの git の所属で判定する。移動先が brain 内でも partner にはならない。
dev = h / "brain-ren"
nested = brain / "worktrees/ren"
nested.parent.mkdir()
subprocess.run(["git", "-C", str(brain), "worktree", "move", str(dev), str(nested)], check=True)
try:
    assert not dev.exists()
    assert compact(nested) == expected("開発", "Ren", roles[1][3])
    dev.mkdir()  # 元の名前を持つだけの持ち主のディレクトリ
    assert compact(dev) == ""
    plain = h / "brain-ren2"
    plain.mkdir()
    assert compact(plain) == ""
    # 移動先でブランチに一致しなければ、brain 内でも無出力。
    gitdir = pathlib.Path((nested / ".git").read_text().strip()[8:])
    head = gitdir / "HEAD"
    saved_head = head.read_bytes()
    head.write_text("ref: refs/heads/unmatched\n")
    assert compact(nested) == ""
    head.write_bytes(saved_head)
finally:
    dev.rmdir()
    subprocess.run(["git", "-C", str(brain), "worktree", "move", str(nested), str(dev)], check=True)
foreign = brain / "nested"
subprocess.run(["git", "init", "-q", str(foreign)], check=True)
assert compact(foreign) == ""
# 相棒の本文への symlink は開発セッションへ漏らさない。
core = brain / "dev/00_核.md"
core.unlink()
core.symlink_to(brain / "Aoi/00_核.md")
assert compact(dev) == ""
core.unlink()
core.write_text(contents["dev/00_核.md"], encoding="utf-8")
# 中間ディレクトリの symlink でも領域外なら読まない。
core.unlink()
outside = brain / "Aoi/linked"
outside.mkdir()
(outside / "core.md").write_text("相棒の秘密", encoding="utf-8")
link = brain / "dev/linked"
link.symlink_to(outside, target_is_directory=True)
core.symlink_to(link / "core.md")
assert compact(dev) == ""
core.unlink()
link.unlink()
core.write_text(contents["dev/00_核.md"], encoding="utf-8")
# 写した worktree（.git の指す登録は元のもの）・登録の消えた古い .git では動かない
import shutil
copy = h / "foreign-copy"
shutil.copytree(str(h / "brain-ren"), str(copy), symlinks=True)
assert compact(copy) == "", "copied worktree"
stale = h / "stale-wt"
subprocess.run(["git", "-C", str(brain), "worktree", "add", "-q", "--detach", str(stale)], check=True)
stale_git = (stale / ".git").read_text()
subprocess.run(["git", "-C", str(brain), "worktree", "remove", "--force", str(stale)], check=True)
stale.mkdir()
(stale / ".git").write_text(stale_git)
assert compact(stale) == "", "stale .git pointer"
# 領域そのものが symlink（dev → 相棒の領域、dev → 外）でも、相棒や外の本文は出さない
real_dev = brain / "dev-real"
(brain / "dev").rename(real_dev)
try:
    (brain / "dev").symlink_to(brain / "Aoi", target_is_directory=True)
    out = compact(h / "brain-ren")
    assert contents["Aoi/00_核.md"] not in out and contents["Aoi/02_関係.md"] not in out, out
    (brain / "dev").unlink()
    outside = h / "outside-area"
    outside.mkdir()
    (outside / "00_核.md").write_text("外の本文\n", encoding="utf-8")
    (brain / "dev").symlink_to(outside, target_is_directory=True)
    assert "外の本文" not in compact(h / "brain-ren")
finally:
    if (brain / "dev").is_symlink():
        (brain / "dev").unlink()
    real_dev.rename(brain / "dev")
assert compact(h / "brain-ren") == expected("開発", "Ren", roles[1][3])
# HEAD が外れている（rebase の途中など）worktree でも、正しい場所なら場所で役を決める（ブランチに頼らない）
subprocess.run(["git", "-C", str(h / "brain-mio"), "checkout", "-q", "--detach"], check=True)
try:
    assert compact(h / "brain-mio") == expected(*roles[2][:2], roles[2][3]), "detached HEAD at the right location"
finally:
    subprocess.run(["git", "-C", str(h / "brain-mio"), "checkout", "-q", "mio"], check=True)
# 起動スクリプトが brain で始めたとき（worktree が無い）：渡された役の核を出し、相棒の核は出さない。worktree の中では場所が勝つ
def launched(cwd, persona):
    return run(json.dumps({"source": "compact", "cwd": str(cwd)}).encode(), cwd=h, extra={"BRAIN_KIT_PERSONA": persona})
assert launched(brain, "dev") == expected(*roles[1][:2], roles[1][3])
assert launched(brain, "review") == expected(*roles[2][:2], roles[2][3])
assert launched(brain, "release") == expected(*roles[3][:2], roles[3][3])
assert launched(brain, "partner") == expected(*roles[0][:2], roles[0][3])
assert launched(brain, "../x") == expected(*roles[0][:2], roles[0][3])
assert launched(h / "brain-mio", "dev") == expected(*roles[2][:2], roles[2][3])
for source in ("startup", "resume", "clear", None, 0):
    assert run(json.dumps({"source": source, "cwd": str(brain)}).encode()) == ""
want = expected(*roles[0][:2], roles[0][3])
for raw in (b"", b"{}", b'{"source":"compact"}'):
    assert run(raw) == want
    assert run(raw, cwd=h) == ""
for raw in (b"invalid json", b"[]", b"null", b" ", b'{"source":"compact","cwd":'):
    assert run(raw) == ""
# 書き手が pipe を閉じなくても合計約 1 秒。完全な JSON は直ちに読む。
for raw, cwd, output in ((b"", brain, want), (b"invalid", brain, ""),
                         (b'{"source":"compact","cwd":', brain, ""),
                         (json.dumps({"source": "compact", "cwd": str(brain)}).encode(), h, want)):
    started = time.monotonic()
    proc = subprocess.Popen([sys.executable, str(hook)], cwd=str(cwd), env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        if raw:
            proc.stdin.write(raw)
            proc.stdin.flush()
        proc.wait(timeout=1.5)
        assert time.monotonic() - started < 1.5
        assert proc.returncode == 0 and proc.stderr.read() == b""
        assert proc.stdout.read().decode("utf-8") == output
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        proc.stdin.close()
        proc.stdout.close()
        proc.stderr.close()
# 書き手が遅れて、JSON を二分して送る。
proc = subprocess.Popen([sys.executable, str(hook)], cwd=str(brain), env=env,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    time.sleep(.3)
    proc.stdin.write(b'{"source":"compact","cwd":')
    proc.stdin.flush()
    time.sleep(.1)
    proc.stdin.write(json.dumps(str(dev)).encode() + b"}")
    proc.stdin.close()
    proc.stdin = None
    out, err = proc.communicate(timeout=1.5)
    assert proc.returncode == 0 and err == b""
    assert out.decode("utf-8") == expected("開発", "Ren", roles[1][3])
finally:
    if proc.poll() is None:
        proc.kill()
        proc.communicate()
# パスデータが無い・読めない場合は静かに終了する。
saved_path = brain_path.read_bytes()
brain_path.unlink()
assert compact(brain) == ""
brain_path.mkdir()
assert compact(brain) == ""
brain_path.rmdir()
brain_path.write_bytes(saved_path)
assert run(b"{}", extra={"BRAIN_KIT_NO_CORE_REREAD": "1"}) == ""
stop = h / ".claude/brain-kit/no-core-reread"
stop.touch()
assert compact(brain) == ""
stop.unlink()
# 片方が無くても、残る方を出す。全部無ければヘッダーも出さない。
paths = roles[0][3]
(brain / paths[0]).unlink()
assert compact(brain) == expected("相棒", "Aoi", paths[1:])
(brain / paths[1]).unlink()
assert compact(brain) == ""
# FIFO・ディレクトリは読まず、無い場合と同じく飛ばす。
os.mkfifo(str(brain / paths[0]))
assert compact(brain) == ""
(brain / paths[0]).unlink()
(brain / paths[0]).mkdir()
assert compact(brain) == ""
(brain / paths[0]).rmdir()
# 100 KiB の本文 2 つ。UTF-8 の境界で切り、各 32 KiB・合計 64 KiB 以内。
for p in paths:
    (brain / p).write_bytes(("核" * (100 * 1024 // 3 + 1)).encode("utf-8"))
out = compact(brain)
overhead = "文脈の要約のあと、相棒 Aoi の核を読み直す（brain-kit のフック）。\n"
for p in paths:
    marker = "（以下略: %s）\n" % p
    header = "--- %s ---\n" % p
    assert marker in out
    body = out.split(header, 1)[1].split(marker, 1)[0].rstrip("\n")
    assert 32 * 1024 - 3 <= len(body.encode("utf-8")) <= 32 * 1024
    overhead += header + "\n" + marker
assert len(out.encode("utf-8")) <= 64 * 1024 + len(overhead.encode("utf-8"))
# ちょうど上限なら省略しない。
for p in paths:
    (brain / p).write_bytes(b"a" * (32 * 1024))
assert "以下略" not in compact(brain)
# 読み手が stdout を消費せず pipe が埋まっても、フックは待ち続けない（3 秒で打ち切る）。
proc = subprocess.Popen([sys.executable, str(hook)], cwd=str(brain), env=env,
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    proc.wait(timeout=4)
    assert proc.returncode == 0 and proc.stderr.read() == b""
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    proc.stdout.close()
    proc.stderr.close()
# config が読めない・壊れていても静かに成功する。
cfg = brain / ".brain-kit/config.json"
saved = cfg.read_bytes()
for value in (b"invalid", b"[]", b"{}"):
    cfg.write_bytes(value)
    assert compact(brain) == ""
cfg.unlink()
assert compact(brain) == ""
cfg.write_bytes(saved)
# 不正な名前の参照先にも本文を置き、欠損による無出力と区別する。
for escaped in (h / "x", h / "absolute"):
    escaped.mkdir()
    (escaped / "00_核.md").write_text("領域外の核", encoding="utf-8")
for role, field, values in (
        ("partner", "name", ("../x", str(h / "absolute"), ".hidden", ".", "..", "x/y", "x\\y", "x\0y", "")),
        ("dev", "id", ("..", "ren..", "Ren", "x" * 41, "ren\n"))):
    for value in values:
        invalid = json.loads(saved)
        invalid["personas"][role][field] = value
        cfg.write_text(json.dumps(invalid))
        assert compact(brain) == ""
        assert compact(dev) == ""
cfg.write_bytes(saved)
# 出力先の切断でも stderr に何も出さず 0 で終わる。
read_fd, write_fd = os.pipe()
os.close(read_fd)
try:
    result = subprocess.run([sys.executable, str(hook)], input=b"{}", cwd=str(brain), env=env,
                            stdout=write_fd, stderr=subprocess.PIPE, timeout=1)
    assert result.returncode == 0 and result.stderr == b""
finally:
    os.close(write_fd)
PY
check "核: 所有記録・4 人格・main の本文・パス境界・stdin・欠損・容量・停止・失敗" test $? -eq 0
new "$H" --doctor >"$H.doctor" 2>&1
check "核: doctor は有効" grep -q '要約のあとの核の読み直し.*有効' "$H.doctor"
touch "$H/.claude/brain-kit/no-core-reread"
new "$H" --doctor >"$H.doctor-off" 2>&1
check "核: doctor はファイルで止めてある" grep -q '要約のあとの核の読み直し.*止めてある' "$H.doctor-off"
rm "$H/.claude/brain-kit/no-core-reread"
BRAIN_KIT_NO_CORE_REREAD=1 new "$H" --doctor >"$H.doctor-env" 2>&1
check "核: doctor は環境変数で止めてある" grep -q '要約のあとの核の読み直し.*止めてある' "$H.doctor-env"
# 設定だけ・スクリプトだけでは有効にならない。
mv "$H/.claude/hooks/brain-kit-core-reread.py" "$H.hook"
new "$H" --doctor >"$H.doctor-no-script" 2>&1
check "核: doctor はスクリプトが無ければフック無し" grep -q '要約のあとの核の読み直し.*フック無し' "$H.doctor-no-script"
mv "$H.hook" "$H/.claude/hooks/brain-kit-core-reread.py"
cp "$H/.claude/settings.json" "$H.settings"
python3 - "$H/.claude/settings.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = json.loads(p.read_text())
for g in s["hooks"]["SessionStart"]:
    if g.get("matcher") == "compact":
        g["matcher"] = "startup"
p.write_text(json.dumps(s))
PY
new "$H" --doctor >"$H.doctor-no-compact" 2>&1
check "核: doctor は compact の設定が無ければフック無し" grep -q '要約のあとの核の読み直し.*フック無し' "$H.doctor-no-compact"
mv "$H.settings" "$H/.claude/settings.json"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "核: uninstall が 0" test $? -eq 0
check "核: 未変更の brain-path を外す" test ! -e "$H/.claude/brain-kit/brain-path"
check "核: 未変更のスクリプトを外す" test ! -e "$H/.claude/hooks/brain-kit-core-reread.py"
check "核: 未変更の項目を外す" sh -c "! grep -q brain-kit-core-reread.py '$H/.claude/settings.json'"
new "$H" --doctor >"$H.doctor-none" 2>&1
check "核: uninstall のあとはフック無し" grep -q '要約のあとの核の読み直し.*フック無し' "$H.doctor-none"

section "核の読み直し（Python の文字列にならない brain パス）"
python3 - "$TMP" "$KIT" <<'PY'
import os, pathlib, subprocess, sys
root, kit = map(pathlib.Path, sys.argv[1:])
for i, suffix in enumerate(('trailing\\', 'triple"""')):
    home = root / ("core-path-%d" % i)
    home.mkdir()
    brain = home / suffix
    env = dict(os.environ, HOME=str(home))
    result = subprocess.run(["bash", str(kit / "install.sh"), "--brain", str(brain),
                             "--partner", "Aoi", "--dev", "Ren", "--review", "Mio",
                             "--release", "Sora", "--user", "Ken", "--yes"],
                            input=b"", env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode == 0, (result.stdout, result.stderr)
    path = home / ".claude/brain-kit/brain-path"
    assert os.path.expanduser(path.read_text()[:-1].replace("~", str(home), 1)) == str(brain)
    hook = home / ".claude/hooks/brain-kit-core-reread.py"
    assert hook.read_bytes() == (kit / "claude/hooks/brain-kit-core-reread.py").read_bytes()
    (brain / "Aoi/00_核.md").write_text("path core", encoding="utf-8")
    result = subprocess.run([sys.executable, str(hook)], input=b"", cwd=str(brain), env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1)
    assert result.returncode == 0 and result.stderr == b"", result
    assert "--- Aoi/00_核.md ---\npath core" in result.stdout.decode("utf-8")
PY
check "核: 末尾のバックスラッシュ・三重引用符の brain パスでも動く" test $? -eq 0

section "核の読み直し（日本語の名前）"
H="$TMP/core-reread-ja"
mkdir -p "$H"
new "$H" --partner 光 --dev 彫 --review 澄 --release 渡 --user Ken --yes </dev/null >"$H.log" 2>&1
check "核: 日本語の install が 0" test $? -eq 0
HOME="$H" python3 - "$H" <<'PY'
import json, pathlib, subprocess, sys
h = pathlib.Path(sys.argv[1])
cfg = json.loads((h / "brain/.brain-kit/config.json").read_text())
assert {r: p["id"] for r, p in cfg["personas"].items()} == {r: r for r in ("partner", "dev", "review", "release")}
for name in ("00_核.md", "02_関係.md"):
    (h / "brain/光" / name).write_text("光の記憶: " + name, encoding="utf-8")
result = subprocess.run([sys.executable, str(h / ".claude/hooks/brain-kit-core-reread.py")],
                        input=json.dumps({"source": "compact", "cwd": str(h / "brain")}).encode(),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=1)
assert result.returncode == 0 and result.stderr == b""
out = result.stdout.decode("utf-8")
assert out.startswith("文脈の要約のあと、相棒 光 の核を読み直す（brain-kit のフック）。\n")
for name in ("00_核.md", "02_関係.md"):
    assert "--- 光/" + name + " ---\n光の記憶: " + name in out
PY
check "核: 日本語の名前のディレクトリを読む（既定 id）" test $? -eq 0

section "核の読み直し（前の kit から追加・所有設定の保持）"
H="$TMP/core-reread-old"
# 実装前の origin/main。先へ進んでも同じ旧版からの更新を検証する。
old_install 62952c7 "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --yes
check "核: 前の kit にはスクリプトが無い" test ! -e "$H/.claude/hooks/brain-kit-core-reread.py"
cp "$H/.claude/settings.json" "$H.settings-before"
new "$H" --update >"$H.up" 2>&1
check "核: 前の kit から update が 0" test $? -eq 0
check "核: update で実行可能なスクリプトを追加" test -x "$H/.claude/hooks/brain-kit-core-reread.py"
python3 - "$H" <<'PY'
import hashlib, json, pathlib, sys
h = pathlib.Path(sys.argv[1])
p = h / ".claude/settings.json"
s = json.loads(p.read_text())
command = 'python3 "$HOME/.claude/hooks/brain-kit-core-reread.py"'
group = {"matcher": "compact", "hooks": [{"type": "command", "command": command, "timeout": 10}]}
assert s["hooks"]["SessionStart"].count(group) == 1
s["hooks"]["SessionStart"].remove(group)
assert s == json.loads(pathlib.Path(str(h) + ".settings-before").read_text())
m = json.loads((h / ".claude/brain-kit/manifest.json").read_text())
assert m["settings"]["hooks.SessionStart"][command] == hashlib.sha256(
    json.dumps(group, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
path = h / ".claude/brain-kit/brain-path"
assert "<brain>" not in path.read_text()
assert path.read_text().endswith("brain\n")
assert m["files"][".claude/brain-kit/brain-path"]["sha"] == hashlib.sha256(path.read_bytes()).hexdigest()
PY
check "核: update で compact 項目と所有記録を追加し既存設定を保持" test $? -eq 0
before="$(snap "$H")"
new "$H" --update >"$H.up2" 2>&1
check "核: 2 回目の update が 0" test $? -eq 0
check "核: 2 回目の update は何も変えない" test "$before" = "$(snap "$H")"
python3 - "$H/.claude/settings.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = json.loads(p.read_text())
for group in s["hooks"]["SessionStart"]:
    if any("brain-kit-core-reread.py" in h["command"] for h in group["hooks"]):
        group["matcher"] = "compact|resume"
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
PY
new "$H" --uninstall --yes >"$H.un" 2>&1
check "核: matcher 編集後の uninstall が 0" test $? -eq 0
check "核: 編集した項目が使うスクリプトを残す" test -x "$H/.claude/hooks/brain-kit-core-reread.py"
check "核: 残す理由を表示" grep -q '残すフックが使うため' "$H.un"
python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
command = 'python3 "$HOME/.claude/hooks/brain-kit-core-reread.py"'
assert s["hooks"]["SessionStart"] == [{"matcher": "compact|resume", "hooks": [
    {"type": "command", "command": command, "timeout": 10}]}]
PY
check "核: 編集した matcher も項目ごとそのまま残す" test $? -eq 0

# ------------------------------------------------------------------ worktree 無しで起動スクリプトから始めた人格
section "要約のあとの核の読み直し（worktree 無しの起動）"
H="$TMP/core-reread-nowt"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes </dev/null >"$H.log" 2>&1
check "核（worktree 無し）: install が 0" test $? -eq 0
printf '相棒だけの核\n' >"$H/brain/Aoi/00_核.md"
printf '開発の核\n' >"$H/brain/dev/00_核.md"
fakec="$TMP/fake-claude-core"; mkdir -p "$fakec"
# 起動スクリプトが exec する claude の代わりに、要約のあとのフックをその場で走らせる
# shellcheck disable=SC2016  # $HOME は偽の claude の中で展開させる
printf '#!/bin/sh\nprintf %%s "{\\"source\\":\\"compact\\"}" | python3 "$HOME/.claude/hooks/brain-kit-core-reread.py"\n' >"$fakec/claude"
chmod +x "$fakec/claude"
HOME="$H" PATH="$fakec:$PATH" "$H/.claude/brain-kit/bin/start-ren" >"$H.ren" 2>&1
check "核（worktree 無し）: 開発の起動は開発の核を出す" grep -q '開発の核' "$H.ren"
check "核（worktree 無し）: 開発の起動は相棒の核を出さない" sh -c "! grep -q '相棒だけの核' '$H.ren'"
HOME="$H" PATH="$fakec:$PATH" "$H/.claude/brain-kit/bin/start-aoi" >"$H.aoi" 2>&1
check "核（worktree 無し）: 相棒の起動は相棒の核を出す" grep -q '相棒だけの核' "$H.aoi"

# ------------------------------------------------------------------ リリースだけの許可
section "リリースだけの許可（任意）"
lacks() { ! grep -q -E -- "$1" "$2"; }   # lacks <式> <file> : 一致する行が無い
H="$TMP/release-off"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --yes --no-worktrees >"$H.log" 2>&1
check "許可: 既定の install" test $? -eq 0
check "許可: 既定ではディレクトリ無し" test ! -e "$H/.claude/brain-kit/permissions"
check "許可: config は false" python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["release_permissions"] is False' "$H/brain/.brain-kit/config.json"
check "許可: 既定の start は読み込まない" lacks --settings "$H/.claude/brain-kit/bin/start-sora"
new "$H" --doctor >"$H.doctor" 2>&1
check "許可: doctor の既定表示" grep -q 'リリースの許可の一覧.*入れていない.*任意' "$H.doctor"
H0="$H"
# 任意機能を入れる前の main（a1cf25a。起動スクリプトに BRAIN_KIT_PERSONA が入った版）の生成結果と比べ、
# 選ばない起動を保つ。原文は一時領域だけで使う
git -C "$KIT" show a1cf25a:lib/kit.py >"$TMP/previous-kit.py"
python3 - "$TMP/previous-kit.py" "$KIT/lib/kit.py" "$H0" <<'PY'
import json, pathlib, runpy, sys
old, current = (runpy.run_path(p) for p in sys.argv[1:3])
cfg = json.loads((pathlib.Path(sys.argv[3]) / "brain/.brain-kit/config.json").read_text())
for role in ("partner", "dev", "review", "release"):
    assert old["gen_start"](role, cfg) == current["gen_start"](role, cfg)
PY
check "許可: 無効時の全起動は前の生成結果と同一" test $? -eq 0
for answer in y n; do
  hi="$TMP/permissions-interactive-$answer"; mkdir -p "$hi"
  printf '%s\n' "$answer" | BRAIN_KIT_INTERACTIVE=1 HOME="$hi" bash "$KIT/install.sh" --mode local --no-codex \
    --partner Aoi --dev Ren --review Mio --release Sora --user Ken --projects '' --repos '' --no-worktrees >"$hi.log" 2>&1
  check "許可: 対話 $answer の導入" test $? -eq 0
  check "許可: 対話 $answer の選択を記録" python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["release_permissions"] == (sys.argv[2] == "y")' "$hi/brain/.brain-kit/config.json" "$answer"
done

H="$TMP/release-on"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --release-permissions --yes --no-worktrees >"$H.log" 2>&1
check "許可: 明示して install" test $? -eq 0
perm="$H/.claude/brain-kit/permissions/sora.json"
check "許可: 雛形と manifest" python3 -c 'import json,sys; from pathlib import Path; h=Path(sys.argv[1]); assert "Bash(gh pr merge:*)" in json.loads((h/".claude/brain-kit/permissions/sora.json").read_text())["permissions"]["allow"]; assert ".claude/brain-kit/permissions/sora.json" in json.loads((h/".claude/brain-kit/manifest.json").read_text())["files"]' "$H"
check "許可: 共通設定は同一" cmp -s "$H0/.claude/settings.json" "$H/.claude/settings.json"
for id in aoi ren mio; do
  check "許可: $id は読み込まない" lacks 'permissions|--settings' "$H/.claude/brain-kit/bin/start-$id"
  # HOME の展開結果だけ揃え、スクリプトをバイトで比較する。kit はパスを正規化して書くので、
  # 置き換える側も正規化する（macOS の TMPDIR は / で終わり、$H0 に // が混ざる）
  python3 -c 'import os, sys; sys.stdout.write(open(sys.argv[1]).read().replace(os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])))' \
    "$H0/.claude/brain-kit/bin/start-$id" "$H0" "$H" >"$H.expected"
  check "許可: $id は同一" cmp -s "$H.expected" "$H/.claude/brain-kit/bin/start-$id"
done
check "許可: sora だけ settings" grep -q -- --settings "$H/.claude/brain-kit/bin/start-sora"
mkdir -p "$TMP/permissions-bin"
cat >"$TMP/permissions-bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
SH
chmod +x "$TMP/permissions-bin/claude"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" extra >"$H.args"
printf '%s\n' --settings "$perm" extra /sora >"$H.want"
check "許可: sora の引数と追加引数" cmp -s "$H.want" "$H.args"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-mio" >"$H.args"
printf '%s\n' /mio >"$H.want"
check "許可: mio の引数" cmp -s "$H.want" "$H.args"
before="$(snap "$H")"; n="$(commits "$H")"
new "$H" --update --no-worktrees >"$H.up" 2>&1
check "許可: 通常更新が成功" test $? -eq 0
check "許可: 通常更新は同一" test "$before" = "$(snap "$H")"
check "許可: 通常更新はコミット無し" test "$n" = "$(commits "$H")"
new "$H" --update --no-release-permissions --no-worktrees >"$H.off" 2>&1
check "許可: 解除が成功" test $? -eq 0
check "許可: 未編集の一覧を削除" test ! -e "$perm"
check "許可: 解除で起動から外す" lacks --settings "$H/.claude/brain-kit/bin/start-sora"
check "許可: 解除を記録" python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["release_permissions"] is False' "$H/brain/.brain-kit/config.json"
new "$H" --rollback >"$H.rb" 2>&1
check "許可: 解除の rollback" test $? -eq 0
check "許可: 解除前を全復元" test "$before" = "$(snap "$H")"
python3 - "$perm" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); data = json.loads(p.read_text())
data["permissions"]["allow"].append("Bash(echo:*)")
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
cp "$perm" "$H.edited"
new "$H" --update --no-worktrees >"$H.up" 2>&1
check "許可: 編集後の更新" test $? -eq 0
check "許可: 持ち主の変更を保持" cmp -s "$perm" "$H.edited"
new "$H" --doctor >"$H.doctor" 2>&1
check "許可: doctor は入れた" grep -q 'リリースの許可の一覧.*入れた.*sora.json.*start-sora だけが読む' "$H.doctor"
rm "$perm"
new "$H" --doctor >"$H.missing" 2>&1
check "許可: doctor は欠落と修復を案内" grep -q 'リリースの許可の一覧.*無い' "$H.missing"
check "許可: doctor の修復コマンド" grep -q './install.sh --update（リリースの許可の一覧を戻す）' "$H.missing"
cp "$H.edited" "$perm"
# 一覧と起動スクリプトの両方を持ち主が直したまま外す → 起動スクリプトは衝突で残るが、一覧は読まれない場所へ
printf '# owner\n' >>"$H/.claude/brain-kit/bin/start-sora"
before="$(snap "$H")"
new "$H" --update --no-release-permissions --no-worktrees --dry-run >"$H.offdry" 2>&1
check "許可: 解除の dry-run は何も変えない" test "$before" = "$(snap "$H")"
check "許可: 解除の dry-run は移すと出す" grep -q '.off に移し' "$H.offdry"
new "$H" --update --no-release-permissions --no-worktrees >"$H.off" 2>&1
check "許可: 編集済みの解除が 0" test $? -eq 0
check "許可: 編集済みの一覧は読まれる場所から消える" test ! -e "$perm"
check "許可: 編集済みの中身は .off に残る" cmp -s "$perm.off" "$H.edited"
check "許可: 移したことを出す" grep -q 'sora.json.off に移した' "$H.off"
check "許可: 直した起動スクリプトは衝突で残る" grep -q -- --settings "$H/.claude/brain-kit/bin/start-sora"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
printf '%s\n' /sora >"$H.want"
check "許可: 残った起動スクリプトも一覧を渡さない" cmp -s "$H.want" "$H.args"
# 一覧が読まれる場所に戻っていても、設定で選んでいなければ残った起動スクリプトは渡さない
cp "$H.edited" "$perm"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
check "許可: 選んでいなければ一覧が在っても渡さない" cmp -s "$H.want" "$H.args"
new "$H" --doctor >"$H.offdoc" 2>&1
check "許可: doctor は選んでいないのに在る一覧を指摘" grep -q 'sora.json.*要確認.*選んでいないのに在る' "$H.offdoc"
rm "$perm"
# 外す → 入れ直す → 一覧を直す → --rollback（入れ直しを戻す）でも、外した状態で一覧は渡らない
new "$H" --update --release-permissions --no-worktrees >"$H.reon" 2>&1
check "許可: 入れ直しが 0" test $? -eq 0
printf '%s\n' '{"permissions": {"allow": ["Bash(psql:*)", "Bash(echo:*)"]}}' >"$perm"
new "$H" --rollback >"$H.rb3" 2>&1
check "許可: 入れ直しの rollback が 0" test $? -eq 0
check "許可: rollback で設定は外した状態" python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["release_permissions"] is False' "$H/brain/.brain-kit/config.json"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
check "許可: rollback のあと起動スクリプトは一覧を渡さない" cmp -s "$H.want" "$H.args"
rm -f "$perm"
new "$H" --rollback >"$H.rb2" 2>&1
check "許可: 編集済みの解除の rollback" test "$before" = "$(snap "$H")"
new "$H" --update --no-release-permissions --no-worktrees >"$H.off" 2>&1
rm -f "$perm.off"
printf '\n# --settings\n' >>"$H/.claude/brain-kit/bin/start-mio"
python3 - "$H/.claude/settings.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); data = json.loads(p.read_text())
data["permissions"]["allow"].append("Bash(psql:*)")
p.write_text(json.dumps(data))
PY
new "$H" --doctor >"$H.leak" 2>&1
check "許可: doctor は他人格を指摘" grep -q 'start-mio.*要確認' "$H.leak"
check "許可: doctor は共通設定を指摘" grep -q 'settings.json.*要確認.*全人格' "$H.leak"
H="$H0"; perm="$H/.claude/brain-kit/permissions/sora.json"
new "$H" --update --release-permissions --no-worktrees >"$H.on" 2>&1
check "許可: あとから追加" test $? -eq 0
check "許可: あとから一覧を置く" test -f "$perm"
check "許可: あとから起動に追加" grep -q -- --settings "$H/.claude/brain-kit/bin/start-sora"
before="$(snap "$H")"
new "$H" --uninstall --yes >"$H.un" 2>&1
check "許可: uninstall" test $? -eq 0
check "許可: 空のディレクトリも削除" test ! -e "$H/.claude/brain-kit/permissions"
new "$H" --rollback >"$H.rb" 2>&1
check "許可: uninstall の rollback" test $? -eq 0
check "許可: uninstall 前を全復元" test "$before" = "$(snap "$H")"
# 一覧と起動スクリプトの両方を直したまま外す → 両方とも残るが、kit の記録が無いので一覧は渡さない
printf '%s\n' '{"permissions": {"allow": ["Bash(psql:*)"]}}' >"$perm"
printf '# owner\n' >>"$H/.claude/brain-kit/bin/start-sora"
new "$H" --uninstall --yes >"$H.un2" 2>&1
check "許可: 直したまま uninstall が 0" test $? -eq 0
check "許可: 直した一覧は残る" test -f "$perm"
check "許可: 直した起動スクリプトは残る" grep -q -- --settings "$H/.claude/brain-kit/bin/start-sora"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
printf '%s\n' /sora >"$H.want"
check "許可: uninstall のあとは一覧を渡さない" cmp -s "$H.want" "$H.args"
new "$H" --rollback >"$H.rb4" 2>&1
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
printf '%s\n' --settings "$perm" /sora >"$H.want"
check "許可: uninstall を戻すと一覧を渡す" cmp -s "$H.want" "$H.args"
new "$H" --update --release-permissions --no-release-permissions >"$H.bad" 2>&1
check "許可: 両方の指定は失敗" test $? -ne 0
# 同じ機に別の brain を入れ、前のリリースの id を開発に使う。直した前の起動スクリプトが残っても一覧は渡さない
H="$TMP/release-two-brains"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --release-permissions --yes --no-worktrees >"$H.log" 2>&1
check "許可: 1 つ目の brain" test $? -eq 0
printf '# owner\n' >>"$H/.claude/brain-kit/bin/start-sora"
new "$H" --brain "$H/brain2" --partner Kai --dev Sora --review Mio2 --release Rin --user Ken --edited keep --yes --no-worktrees >"$H.log2" 2>&1
check "許可: 2 つ目の brain" test $? -eq 0
check "許可: 前の直した起動スクリプトは残る" grep -q -- --settings "$H/.claude/brain-kit/bin/start-sora"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
check "許可: 別の brain の開発に同じ id でも一覧を渡さない" lacks --settings "$H.args"

# 逆向き：前の brain の開発の id を、別の brain のリリースに使う。直した開発の skill を残したら一覧は渡さない
H="$TMP/release-two-brains-rev"; mkdir -p "$H"
new "$H" --partner Aoi --dev Sora --review Mio --release Rin --user Ken --yes --no-worktrees >"$H.log" 2>&1
check "許可（逆）: 1 つ目の brain" test $? -eq 0
printf '# owner\n' >>"$H/.claude/skills/sora/SKILL.md"
new "$H" --brain "$H/brain2" --partner Kai --dev Ren2 --review Mio2 --release Sora --user Ken --release-permissions --edited keep --yes --no-worktrees >"$H.log2" 2>&1
check "許可（逆）: 2 つ目の brain" test $? -eq 0
check "許可（逆）: 直した開発の skill は残る" grep -q '^# owner' "$H/.claude/skills/sora/SKILL.md"
check "許可（逆）: 渡さないと知らせる" grep -q '許可の一覧は渡さない' "$H.log2"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
check "許可（逆）: 残った開発の skill に一覧を渡さない" lacks --settings "$H.args"
# そのあと普通の流れで衝突を今のまま解消しても（--update → --resolve --keep → --update）、開発の skill には渡さない
new "$H" --brain "$H/brain2" --update --no-worktrees </dev/null >"$H.up1" 2>&1
new "$H" --brain "$H/brain2" --resolve --keep "$H/.claude/skills/sora/SKILL.md" </dev/null >"$H.res" 2>&1
check "許可（逆）: --resolve --keep が 0" test $? -eq 0
new "$H" --brain "$H/brain2" --update --no-worktrees </dev/null >"$H.up2" 2>&1
check "許可（逆）: 解消後の更新が 0" test $? -eq 0
check "許可（逆）: 解消後も開発の skill のまま" grep -q '^# owner' "$H/.claude/skills/sora/SKILL.md"
HOME="$H" PATH="$TMP/permissions-bin:$PATH" "$H/.claude/brain-kit/bin/start-sora" >"$H.args"
check "許可（逆）: 今のまま解消しても一覧を渡さない" lacks --settings "$H.args"

# 選ぶ前の kit で入れた設定には、何も変わらない更新で印を足さない
H="$TMP/release-legacy"
old_install 62952c7 "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes
new "$H" --update --no-worktrees >"$H.up" 2>&1
check "許可: 前の kit からの更新が 0" test $? -eq 0
check "許可: 前の kit の設定に印を足さない" lacks release_permissions "$H/brain/.brain-kit/config.json"
check "許可: 前の kit からの更新で一覧を置かない" test ! -e "$H/.claude/brain-kit/permissions"
before="$(snap "$H")"; n="$(commits "$H")"
new "$H" --update --no-worktrees >"$H.up2" 2>&1
check "許可: 前の kit からの 2 回目の更新は何も変えない" test "$before" = "$(snap "$H")"
check "許可: 前の kit からの 2 回目の更新はコミット無し" test "$n" = "$(commits "$H")"

# ------------------------------------------------------------------ npm の tarball から入れる
section "npm の tarball から新規"
if [ -n "$NPM" ]; then
  mkdir -p "$TMP/pack"
  (cd "$KIT" && PATH="$(dirname "$NPM"):$PATH" npm_config_cache="$TMP/npm-cache" "$NPM" pack --silent --pack-destination "$TMP/pack" >/dev/null 2>&1)
  check "npm pack が tarball を作る" sh -c "ls '$TMP/pack'/brainkit-agents-*.tgz"
  # PATH を絞っているので gzip が無い。python3 で展開する
  python3 -c 'import glob, sys, tarfile; tarfile.open(glob.glob(sys.argv[1] + "/brainkit-agents-*.tgz")[0]).extractall(sys.argv[1])' "$TMP/pack"
  check "tarball を展開できる（install.sh がある）" test -f "$TMP/pack/package/install.sh"
  check "tarball に tests は入らない" test ! -e "$TMP/pack/package/tests"
  H="$TMP/from-npm"; mkdir -p "$H"
  HOME="$H" bash "$TMP/pack/package/install.sh" --partner Aoi --dev Ren --review Mio --release Sora --user Ken \
    --repos "example/app" --projects "app" --yes </dev/null >"$H.log" 2>&1
  rc=$?
  check "tarball からの install が 0 で終わる" test "$rc" -eq 0
  [ "$rc" -eq 0 ] || tail -n 20 "$H.log"
  check "tarball から入れた brain に .gitignore がある" test -f "$H/brain/.gitignore"
  check "tarball から入れた brain の .gitignore は kit と同じ" cmp -s "$KIT/brain-template/gitignore" "$H/brain/.gitignore"
  check "tarball から入れた brain に点なしの gitignore は無い" test ! -e "$H/brain/gitignore"
else
  printf '  skip npm が無い\n'
fi

printf '\n%d ok, %d NG\n' "$pass" "$fail"
[ "$fail" = 0 ]
