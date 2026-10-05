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

printf '\n%d ok, %d NG\n' "$pass" "$fail"
[ "$fail" = 0 ]
