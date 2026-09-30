# CHANGELOG

更新（`./install.sh --update`）の最後に、上がった版より新しい節だけが出る。版は `VERSION`、brain には `.brain-kit/config.json` に記録される。

## v10

- **更新（`--update`）**：kit のもの（skill・規約・台本・フック）だけを新しい版に上げる。持ち主のもの（核・辞書・関係・日誌・決定・知識・プロジェクト・記録）には触らない。
  - 版の記録が無い古い入れ方（v1〜v9）も、ファイルの形から見分けて、最初の更新で記録を書く
  - 相棒と開発の名前はそのまま引き継ぐ。新しく足す人格だけ名前を聞く
  - 手で直した kit のファイルは上書きしない。新しい版にする／今のままにする／差分を見る、の 3 択。対話が無ければ今のまま
  - `--dry-run` で、足すもの・上げるもの・触らないもの・手で直したもの、と差分を出す
  - 上書きの前に `~/.claude/backup-brain-kit-<日時>/` へ退避。`--rollback` で直前の更新を戻す
- **`--doctor`**：版・人格・古いもの・足りないもの・手で直したもの・gh のラベル・Orca の状態を表で出す

## v9

- 相棒の skill と憲法の雛形から、特定の相棒に固有の言い回しを外し、中立な語にした

## v8

- macOS 標準の bash 3.2 と BSD awk で動くように直した

## v7

- `--doctor`：何も変えずに状態を表で出す

## v6

- `--codex`：Codex CLI と plugin の連携。開発担当の skill に「別モデルで疑わせる」節

## v5

- 公開の準備：LICENSE（MIT）、`npx` で動かすための `bin/brain-kit.js`

## v4

- 既存環境への上乗せ：`--brain-merge`（無いものだけ足す）

## v3

- `--mode local|base` と `setup-base.sh`（母艦の一括セットアップ）

## v2

- `install.sh` を対話式に、`/setup` skill、開発担当の名前を `--dev` で

## v1

- 最初の版：Claude Code + brain + Orca の仕組みだけのテンプレート
