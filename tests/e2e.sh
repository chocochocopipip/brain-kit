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
check "持ち主のものは 1 バイトも変わらない" test "$own0" = "$(owner_snap "$H9" | grep -v -e ' brain/review/' -e ' brain/release/' -e ' brain/光/03_' -e ' brain/光/20_')"
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

# ------------------------------------------------------------------ 8. 3-way（次の版）
section "3-way（次の版）"
NEXT="$TMP/kit-next"
mkdir -p "$NEXT"
while IFS= read -r -d '' f; do
  mkdir -p "$NEXT/$(dirname "$f")"
  cp "$KIT/$f" "$NEXT/$f"
done < <(git -C "$KIT" ls-files -z)
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
done < <(git -C "$KIT" ls-files -z)
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
            g["write_text"](directory + "/meta.json", g["dump_json"](meta))
        entries.append(directory)
    assert entries[-1].endswith("-12") if not old else entries[-1].endswith("-24")
    for i in range(11, -1, -1):
        g["cmd_rollback"](argparse.Namespace(dry_run=False))
        assert g["load_json"](entries[i] + "/meta.json")["rolled_back"]
        assert g["read_text"](p) == (str(i - 1) if i else None)
PY
check "退避: 同じ秒の 12 件を新旧の記録とも新しい順に戻す" test $? -eq 0
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
(cd "$KIT" && git ls-files -z | xargs -0 tar cf -) | (cd "$NEXTS3" && tar xf -)
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
for p in brain-kit/bin/heavy-lock brain-kit/manifest.json brain-kit/base brain-kit/bin/start-aoi brain-kit/bin/start-ren brain-kit/bin/start-mio brain-kit/bin/start-sora; do
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
# 確認を待つ間に kit の skill を持ち主が書き換えたら、それは消さない
{ sleep 3; printf 'edited while waiting\n' >>"$H/.claude/skills/mio/SKILL.md"; echo y; } |
  BRAIN_KIT_INTERACTIVE=1 HOME="$H" bash "$KIT/install.sh" --uninstall >"$H.race2" 2>&1
check "確認中の書き換え: uninstall が 0" test $? -eq 0
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
           "rollback": [mock.patch.object(g["shutil"], "copy2", copy2)]}[mode]
for p in patches:
    p.start()
try:
    g["main"](["rollback"] if mode == "rollback" else ["uninstall", "--yes"])
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
check "どれも呼ばない kit の skill は消す" test ! -e "$H/.claude/skills/aoi/SKILL.md"
# 持ち主が何も変えていなければ、SessionEnd の項目もスクリプトも外す
H="$TMP/uninstall-hookref-plain"; mkdir -p "$H"
new "$H" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes >"$H.log" 2>&1
new "$H" --uninstall --yes >"$H.un" 2>&1
check "変えていなければ SessionEnd の項目を外す" sh -c "! grep -q 'session-end-brain.sh' '$H/.claude/settings.json'"
check "変えていなければ session-end-brain.sh も消す" test ! -e "$H/.claude/hooks/session-end-brain.sh"
check "変えていなければ brain-digest.js も消す" test ! -e "$H/.claude/hooks/brain-digest.js"

# ------------------------------------------------------------------ npm の tarball から入れる
section "npm の tarball から新規"
if [ -n "$NPM" ]; then
  mkdir -p "$TMP/pack"
  (cd "$KIT" && PATH="$(dirname "$NPM"):$PATH" "$NPM" pack --silent --pack-destination "$TMP/pack" >/dev/null 2>&1)
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
