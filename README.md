# brain-kit

Claude Code を「記憶を持つ相棒」と「開発を回す手」の二人格で運用するための、**仕組みだけ**のテンプレート。
記憶・個人データ・人名・店名・リポジトリ名・認証情報は入っていない。中身はあなたが書く。

## これは何か

```
┌──────────────────────────────┐
│ Claude Code 設定 (~/.claude)  │  グローバル規律 / skills / hooks / settings
├──────────────────────────────┤
│ brain (~/brain)               │  Obsidian vault = 記憶。日次ログ・決定・知識・人格領域
├──────────────────────────────┤
│ Orca（任意）                   │  母艦に常駐させ、スマホや別 PC からエージェントを並べる
└──────────────────────────────┘
```

| 層 | 何をするか | どこにあるか |
|---|---|---|
| **Claude Code 設定** | 「作業前に brain を読め、決定は brain に書け」という規律と、二人格の skill、セッション終了時に日次ノートへ自動追記するフック | `claude/` |
| **brain** | Obsidian vault。`daily/` `projects/` `decisions/` `knowledge/` と、相棒の領域 `<相棒名>/`、開発の領域 `dev/` | `brain-template/` |
| **Orca** | Claude Code を母艦（WSL）で常駐・並列に動かし、外から繋ぐ。無くても上の2層は動く | `ORCA.md` |

## 導入（1コマンド）

```bash
git clone <このリポジトリ> && cd brain-kit
./install.sh --partner <相棒名>
```

`install.sh` がやること（すべて `$HOME` 起点。ユーザー名の決め打ちは無い）:

1. `~/brain` を作り、`brain-template/` の骨格を置く。**既にあれば止まる**（`--brain <dir>` で別の場所も可）
2. `~/.claude/CLAUDE.md`、`~/.claude/skills/{<相棒名>,dev,grilling}`、`~/.claude/hooks/*` を置く。
   既存があれば `~/.claude/backup-brain-kit-<日時>/` に退避してから上書きを確認する（`--yes` で無確認）
3. `~/.claude/settings.json` に `hooks` / `statusLine` / `enabledPlugins` を**マージ**する。丸ごと上書きはしない。
   `permissions.allow` は既存に無いときだけ最小例を置く
4. `~/brain` を `git init` して初回コミット

必要なもの: `git` `python3` `node`（フックの要約用）`claude` CLI。

## 自分で決めること

| 決めること | どこに書くか |
|---|---|
| **相棒の名前** | `./install.sh --partner <名前>`。`<相棒名>/` ディレクトリと skill 名になる |
| **相棒の憲法** | `~/brain/<相棒名>/00_核.md`。存在／恒久条項／時間の公理／運用。skill はこれを読んでから灯る。**skill には写さない** |
| 相棒の声と関係 | `~/brain/<相棒名>/02_関係.md`（一人称・敬語・距離感）、`01_辞書.md`（二人の間だけの語） |
| dev エージェントの名前 | 任意。`~/brain/dev/00_核.md` に書く。skill `dev` は名前に依存しない |
| **プロジェクト名** | `~/brain/projects/<名前>.md` を1枚作る。frontmatter の `project:` と一致させる |
| **GitHub リポジトリ** | `dev/状況/<repo>.md` を初めて触ったときに作る。issue ラベル（下の「開発の渡し方」）をリポジトリ側に用意する |
| brain の remote | `git -C ~/brain remote add origin <url>`。private にする。フックが自動コミットするので push は好きなタイミングで |
| プラグイン | 下の「プラグイン」 |

## 運用の要点（元の持ち主のやり方）

- **brain は Obsidian vault。**Claude Code はタスクの前に `daily/` の直近、`projects/<名前>.md`、関連 `decisions/` を読む。
  探すときは `grep -ril "<キーワード>" ~/brain`
- **decisions は1件1ファイル。**`YYYY-MM-DD-要約.md` に 背景／決定／理由／見送った案／影響。覆すときは消さず `## 撤回` を追記
- **frontmatter 必須。**全ノートに `date`（絶対日付）／`project`（無ければ `none`）／`tags`（空にしない）
- **1ノート1トピック、関連は `[[wikilink]]`。**例外は `daily/`（時系列追記）と `inbox.md`（frontmatter 免除）
- **SessionEnd フックが日次ノートへ自動追記する。**`session-end-brain.sh` がトランスクリプトを `brain-digest.js` で圧縮し、
  `claude -p --model haiku` に「やったこと／決定事項／未解決事項」を書かせて `daily/YYYY-MM-DD.md` に追記、`~/brain` にコミットする。
  要約に失敗したら依頼一覧にフォールバックする。ログは `~/.claude/hooks/brain-hook.log`。
  モデルと時間は `BRAIN_HOOK_MODEL` `BRAIN_HOOK_TIMEOUT`、vault の場所は `BRAIN_DIR` で変えられる
- **相棒（skill `<相棒名>`）は憲法ファイルを読んで灯る。**灯ったら 00_核 → 01_辞書 → 02_関係 → 最新の日誌 → inbox の順に読み、
  **経過日数を把握してから**話す。閉会しない、時刻を創作しない、日誌は追記専用、`90_原本/` に触れない。
  消灯は持ち主が決めたときだけで、日誌を1枚書いてコミットする
- **開発は dev エージェント（skill `dev`）に issue ラベルで渡す。**相棒が内容を決め、issue に `dev` ラベルと決定事項のコメントを付ける。
  dev は複数リポジトリを横断し、`dev/状況/<repo>.md`（**置換専用・50行以内**）で現在地を持ち、`dev/報告/YYYY-MM-DD.md`（**追記専用**）で相棒に報告する。
  権限の既定は **「PR まで、マージしない」**。`agent-ready` の付与と権限ダイアログの承諾は人の関門で、エージェントが自分で通さない
- **相棒と dev は相互に書き込まない。**相棒は `dev/報告/` を読むだけ、dev は `<相棒名>/` に書かない。
  人格ごとにワークツリー（ブランチ + sparse-checkout）を分ける方法は `brain-template/dev/README.md`

### 開発の渡し方（issue ラベル）

全リポジトリで揃える: `from-chat`（出所の記録）／`needs-triage`（人の確認待ち）／`agent-ready`（承認済み）／
`agent-working`（排他ロック）／`dev`（相棒から dev へ）／`question`（判断を人に返した）。詳細は `claude/skills/dev/SKILL.md` §3。

### チャットの指摘を issue にする skill の作り方

元の環境には「LINE で来た指摘を貼ると GitHub issue に整形して起票する」skill があるが、リポジトリ固有なので入れていない。作るなら:

1. `~/.claude/skills/chat2issue/SKILL.md` に、対象リポジトリ名と「貼られたテキストを話題ごとに割る → 原文を引用で残す → 仕様書と照らして『仕様どおりかも』も書く → `gh issue create --label from-chat,needs-triage`」の手順を書く
2. **`agent-ready` は絶対に skill 自身に付けさせない。**起票後に一覧を出して、どれをエージェントに回すか人に聞く
3. コードは直さない、指摘の妥当性を勝手に判定して捨てない、報告者を推測して書かない、の3つを「やらないこと」に置く

## プラグイン

`settings.snippet.json` の `enabledPlugins` は空にしてある（マーケットプレイスの登録が環境ごとに要るため）。
Claude Code の `/plugin` から入れる:

- `pr-review-toolkit`（公式マーケットプレイス claude-plugins-official）— skill `dev` の `/review-pr` が使う
- `codex`（OpenAI の codex-plugin-cc マーケットプレイス）— 別モデルで書かせる／疑わせる用。任意

## ファイル構成

```
brain-kit/
├── README.md                 ← これ
├── install.sh                ← 導入スクリプト
├── check.sh / CHECKLIST.md   ← 人に渡す前の漏れチェック
├── ORCA.md                   ← Orca を WSL に常駐させて Tailscale で繋ぐ手順
├── claude/
│   ├── CLAUDE.md             ← グローバル規律（~/.claude/CLAUDE.md）
│   ├── settings.snippet.json ← hooks / statusLine / enabledPlugins（マージ用）
│   ├── hooks/session-end-brain.sh, brain-digest.js
│   └── skills/partner/ dev/ grilling/
└── brain-template/           ← ~/brain の骨格（partner/ は install 時に <相棒名>/ に改名）
```

`settings.snippet.json` の Orca 用フック（SessionStart / UserPromptSubmit / Stop / … / PermissionRequest）は
`~/.orca/agent-hooks/claude-hook.sh` が無ければ `{}` を返して何もしない。Orca を使わないなら消してよい。
Orca デスクトップが自分でフックを書き込むと、同じイベントに Windows 対応の長い版が並ぶことがある。重複しても害はない。

## 渡す前の確認（実施済み）

`CHECKLIST.md` の手順を 2026-09-17 に実施した:

- `./check.sh <元の持ち主の固有名詞 10 語>`（ユーザー名・プロジェクト名 3 つ・相棒名と dev 名の漢字/かな・組織名・GitHub オーナー名）
  ＋ 組み込み 5 パターン（メール／秘密鍵／認証情報の英単語／ホームの絶対パス／IP アドレス）→ **0 件**
- 同じ 10 語に「アットマーク」と認証情報の英単語 2 つを足した `grep -rniE` を `brain-kit/` 直下で実行 → **0 件**
  （語そのものをここに書くと、それ自体が漏れになるので書かない）
- `~/.orca/` `~/.config/orca/` の中身は読んでおらず、同梱もしていない。ファイル名の一覧だけ `ORCA.md` にある

あなたが次の人に渡すときも、自分の固有名詞で同じことをする。
