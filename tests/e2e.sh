#!/usr/bin/env bash
# 実走テスト（サンドボックス HOME）。新規・v8 → v10・v9 → v10・v10 → v10、--dry-run、base・3-way・衝突の保全、
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

printf '\n%d ok, %d NG\n' "$pass" "$fail"
[ "$fail" = 0 ]
