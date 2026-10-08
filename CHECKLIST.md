# 渡す前に確認すること

このキットは「仕組み」だけを渡すもの。**記憶・個人データ・人名・店名・リポジトリ名・認証情報は入れない。**
自分の環境から更新して次の人に渡すときも、毎回これを通す。

## 1. 固有名詞と認証情報が 0 件であること

`check.sh` に、自分の環境の固有名詞を**引数で**渡して走らせる（このファイルにも check.sh にも、その語は書かない。
書いた瞬間にそれ自体が漏れになる）。

```bash
./check.sh <自分のユーザー名> <プロジェクト名> <相棒の名前> <dev エージェントの名前> <店名> <人名> ...
```

語が多いなら、**リポジトリの外の**ファイルに 1 行 1 語で書いて渡す（既定は `~/.config/brain-kit/check-words.txt`）:

```bash
BRAIN_KIT_CHECK_WORDS_FILE=~/.config/brain-kit/check-words.txt ./check.sh
```

GitHub で公開しているなら、同じ中身を secret `BRAIN_KIT_CHECK_WORDS` に入れる。`.github/workflows/check.yml` が PR ごとに流し、当たれば落ちる
（ログには「ファイル:行」だけが出て、語そのものは出ない）。BRAIN_KIT_CHECK_WORDS が無いと組み込みパターンだけで通り、警告が出る。

check.sh は引数の語に加えて、次を**常に**探す:

- メールアドレスらしき文字列
- 秘密鍵ヘッダ（`BEGIN ... PRIVATE KEY`）
- 認証情報らしき英単語（トークン／シークレット／API キー／パスワード）
- ホームディレクトリの絶対パス（`$HOME` か `~` に置き換える）
- IP アドレス（Tailscale の `100.x.x.x` を含む）

**すべて 0 件になるまで渡さない。**`.git/` は対象外（コミッタ情報が入るため）。渡す側はコミッタ名も自分の本名でないことを確認する。

## 2. 中身が「型」だけであること

- 日本語のテンプレート・skill を変えたら `i18n/en/` の英語版も直し、`python3 tools/i18n-stamp.py --write`。kit.py の新しい表示文は `M()` を通して `i18n/en/messages.json` に足し、`python3 tools/i18n-stamp.py --catalog` で確認する。

- `brain-template/<相棒名>/00_核.md` `01_辞書.md` `02_関係.md` が**見出しだけ**で、本文が空
- `brain-template/partner/03_任せる範囲.md` `review/規準.md` `release/手順.md` が**一般的な既定だけ**（実在のリポジトリ・過去の PR 番号・店・人が出てこない）
- `brain-template/dev/状況/` に `_テンプレート.md` 以外のカードが無い
- `brain-template/dev/報告/` `daily/` `decisions/` `knowledge/` `projects/` が `.gitkeep` だけ
- `claude/skills/*/SKILL.md` に、実在の人・店・リポジトリが出てこない
- `claude/settings.snippet.json` の `permissions.allow` が最小例だけ

## 3. パスとユーザー名

- ホームディレクトリの絶対パスが 0 件（check.sh の組み込みで見る）。すべて `$HOME` か `~`
- `install.sh` にユーザー名の決め打ちが無い

## 4. Orca の設定ファイルを同梱していない

`~/.orca/` `~/.config/orca/` の中身は**一切**入れない（ORCA.md の表を参照）。ファイル名の一覧だけ。

- 新しい Claude Code で動作を確かめ直したら、`lib/kit.py` の `VERIFIED_CLAUDE_CODE` を上げ、確認した版を CHANGELOG に 1 行記す。
- `VERSION`・`package.json` の major・CHANGELOG の最新の版見出しを揃える（`check.sh` が検査する）。

## 5. 最後に

```bash
./check.sh <固有名詞...>     # 0 件
bash tests/lint.sh   # shellcheck と bash 3.2/BSD で動かない書き方（shellcheck が要る）
bash tests/e2e.sh             # 新規・更新・戻しの実走（macOS なら /bin/bash で）
git status                    # clean
```

kit のファイルを変えたら `kitfiles.tsv` を見直す（kit のものか、持ち主のものか）。版を上げたら `VERSION` と `CHANGELOG.md` の節を足す。

README の「確認済み」に、実行した日付と結果を書き足す。
