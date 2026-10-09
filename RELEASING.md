# Releasing / リリースの手順

> **EN** — How a version of brain-kit is released, in order: align the version in `VERSION` / `package.json` / `CHANGELOG.md` (`./check.sh` verifies) → close the changelog section → tag `v<N>` on `main` → GitHub Release from that changelog section → `npm publish` as `brainkit-agents` → verify from the published tarball. A release is a new integer version `<N>` (`VERSION`, tag `v<N>`, heading `## v<N>`); `package.json` carries `<N>.0.0`. Publishing (tag, Release, npm) is done by the owner or whoever the owner gives the release role; a PR never publishes anything. With a passkey as npm's second factor, run `BROWSER=echo npm publish` in a real terminal and open the printed URL.

版を出すときの手順。上から順に進める。**タグ・GitHub Release・npm の公開は、持ち主（または持ち主がリリースを任せた担当）がする。**PR は何も公開しない（PR が揃えるのは 1〜2 まで）。

以下、`<N>` は版の整数（例 `12`）。

**版は整数で数える。**`VERSION` は整数で、`check.sh` と更新（`--update` の版の判定・CHANGELOG の表示）がこの整数で比べる。だからリリースは毎回新しい整数（major）にする。minor・patch は `package.json` にだけ現れる（npm が `X.Y.Z` を要るため）。

## 1. 版を 3 か所で揃える

| 場所 | 書くもの | 例 |
|---|---|---|
| `VERSION` | 整数 | `12` |
| `package.json` の `version` | `<N>.0.0` | `12.0.0` |
| `CHANGELOG.md` の最初の版見出し | `## v<N>` | `## v12` |

```bash
./check.sh <固有名詞...>
# ok: 版 VERSION=12 / package.json=12.0.0 / CHANGELOG=v12
```

`check.sh` は VERSION が正の整数か、package.json が `X.Y.Z` か、`package.json` と CHANGELOG の版の major が VERSION と同じかを見る。

## 2. CHANGELOG の節を閉じる

- `## 次の版（作業中）` に溜まった行の上に `## v<N>` を足し、その版の節にする
- `## 次の版（作業中）` の見出しは空のまま一番上に残す（次の PR がそこに書く。`check.sh` は版の見出しに数えない）
- 1〜2 は 1 本の PR にし、CI（e2e・lint・check）が緑になってから main に入れる
- 更新の最後には、入っていた版より大きい整数の節だけが出る（v11 から v12 に上げた人には `## v12` の節）

## 3. タグ

main に入ったコミットに `v<N>` を付ける（これまでと同じ形。例 `v11`）。

```bash
git fetch origin
git show origin/main:VERSION          # <N> であること
git show origin/main:package.json | grep '"version"'   # <N>.0.0 であること
git tag v<N> origin/main              # 例: git tag v12 origin/main
git push origin v<N>
```

## 4. GitHub Release

本文は CHANGELOG のその版の節をそのまま使う（見出しを含む）。

```bash
n=<N>
awk -v h="## v$n" '$0 == h {f = 1; print; next} f && /^## / {exit} f' CHANGELOG.md >"/tmp/release-notes-v$n.md"
cat "/tmp/release-notes-v$n.md"           # 中身を目で確かめる
gh release create "v$n" --verify-tag --title "v$n" --notes-file "/tmp/release-notes-v$n.md"
```

`--verify-tag` は、3 のタグが GitHub に無ければ作らずに止める。

## 5. npm publish

パッケージ名は **`brainkit-agents`**（コマンド名も同じ。`package.json` の `bin`）。npm の版は `<N>.0.0`。

```bash
git switch --detach v<N>       # タグの中身から出す
git status                     # clean
npm pack --dry-run             # 入るファイルの一覧（package.json の files）を確かめる
BROWSER=echo npm publish       # 2 要素目がパスキーのとき
```

- **2 要素目がパスキーのとき**は、本物の端末（対話できるターミナル）で `BROWSER=echo npm publish` を打つ。認証の URL が画面に出るので、それをブラウザで開いて承認する。エージェントの実行環境や CI からは通らない
- **名前を変える・新しく取るとき**：npm は区切り（`-` `.` `_`）を除いて既存の名前と比べ、似すぎていれば公開を 403 で拒む（例：`brain-kit-agents` と `brainkitagents` は同じ名前として扱われる）。候補は区切りを外した形でも `npm view <名前>` で確かめてから決める
- 公開した版は取り消して同じ版番号で出し直せない。間違えたら次の版を出す

## 6. 公開のあとに確かめる

npm から入れたものが動くかを、**公開された tarball** で確かめる（手元のチェックアウトではなく）。

```bash
v=<N>.0.0
npm view brainkit-agents version              # <N>.0.0 が出る
npm view brainkit-agents dist-tags            # latest が <N>.0.0

# tarball の中身
d="$(mktemp -d)"; cd "$d" || exit 1
npm pack "brainkit-agents@$v"
tar -tzf "brainkit-agents-$v.tgz" | sort
tar -xzf "brainkit-agents-$v.tgz" -O package/package.json | grep '"version"'

# 版の表示（VERSION の整数を出す。例: brain-kit v12）
npx -y "brainkit-agents@$v" --version

# 使い捨ての HOME に実際に入れる
h="$(mktemp -d)"
HOME="$h" npx -y "brainkit-agents@$v" --partner Aoi --dev Ren --review Mio --release Sora --user Ken --no-worktrees --yes
ls -a "$h/brain"                              # .gitignore があること
HOME="$h" npx -y "brainkit-agents@$v" --doctor
```

- **npm は `.gitignore` という名前のファイルを tarball に入れない。**kit はテンプレートで点なしの `brain-template/gitignore` として持ち、書くときに `.gitignore` に戻している。tarball に `package/brain-template/gitignore` があり、入れた brain に `.gitignore` があることを、毎回ファイルで確かめる
- 確かめ終えたら使い捨ての HOME とディレクトリを消す
- 何かおかしければ、Release の本文に書き足すか次の版を出す（同じ版は出し直せない）
