# 見回りの雛形（Orca の automation。任意）

Orca の automation は**スケジュール起動のみ**（webhook は無い）。`--precheck` で「仕事があるときだけ本体を走らせる」を作る（exit 0 のときだけ本体が走る）。
ここにあるのは雛形。**実際のコマンドは `orca automations --help` で確かめてから**作る（版で引数が変わることがある）。

## 決まりごと

- **`--workspace-mode new-per-run` を使わない。**毎回パスが変わり、フォルダ信頼のダイアログを毎回引く。人格の worktree（`<brain>-<id>`）を固定で使い、`existing` にする
- **`status: completed` は「起動できた」ことすら意味しない。**`orca terminal read` で中身まで見る
- 見回りで動くのは**読む・起票する・PR を出す**まで。マージと本番の操作は、ラベルと指示のコメントがあるときに <リリース担当名> が手で起動して行う
- 人の関門（`agent-ready` の付与・権限ダイアログ）を自動で通す設定にしない

## 前確認

`~/.claude/brain-kit/automations/precheck.sh <label> [pr]`：brain の `.brain-kit/config.json` のリポジトリを `gh` で見て、そのラベルの open が 1 本でもあれば 0。

| 見回り | 前確認 | 本体（起動するもの） | 目安 |
|---|---|---|---|
| 開発 | `precheck.sh <開発ラベル>` | `~/.claude/brain-kit/bin/start-<開発id>`（worktree `<brain>-<開発id>`） | 1〜2 時間ごと |
| レビュー | `precheck.sh <レビューラベル> pr` | `~/.claude/brain-kit/bin/start-<レビューid>` | 30 分〜1 時間ごと |
| 工程表 | なし | 相棒に「工程表を更新して」（`/<相棒id>` のセッションで） | 朝いちばん |

## 形（雛形）

```bash
# 例: レビュー待ちの PR があるときだけ、<レビュー担当名> を起動する
orca automations create \
  --name "<レビューid>-patrol" \
  --schedule "*/30 * * * *" \
  --workspace-mode existing --worktree "<brain>-<レビューid>" \
  --precheck "$HOME/.claude/brain-kit/automations/precheck.sh <レビューラベル> pr" \
  --command "$HOME/.claude/brain-kit/bin/start-<レビューid>"
# 引数の名前は orca automations create --help で確かめる

orca automations list
orca automations runs <id>
```

## 重いテスト

開発やレビューがテストを走らせるときは `~/.claude/brain-kit/bin/heavy-lock <コマンド>` を通すと、空きメモリがあるときだけ次の 1 本を入れる（任意）。
同時の上限や 1 本分の見込みは環境変数で変える（中のコメント）。
