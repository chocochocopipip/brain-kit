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

## 導入

### 1. どこで動かすかを選ぶ（local ／ base）

| | local | base |
|---|---|---|
| 何 | 手元の 1 台で Claude Code + brain を動かす | 常時稼働の Linux/WSL 機を**母艦**にし、手元 PC・スマホから Tailscale で繋ぐ |
| 向く人 | まず試す。1 台で完結 | 家に置きっぱなしの機がある。外からもエージェントを見たい・動かしたい |
| 追加でやること | 無し | `setup-base.sh`（Tailscale・Orca・systemd 常駐。`install.sh --mode base` が続けて呼ぶ） |

base の絵:

```
 手元 PC（Orca デスクトップ）─┐
                              ├─ Tailscale ──▶ base（常時稼働の Ubuntu / WSL）
 スマホ（Orca モバイル）──────┘                 ├─ orca-ide serve（systemd user service, :6768）
                                                 ├─ Claude Code（相棒 / 開発担当）
                                                 └─ ~/brain（Obsidian vault, git）
```

**`install.sh` は動かす機で走らせる。**base を選ぶなら base 機の上で。手元の別 PC から遠隔で組む形は作っていない。

### 2. install.sh（1コマンド＋対話）

```bash
git clone <このリポジトリ> && cd brain-kit
./install.sh
```

聞かれるのは 6 つ（空 Enter で既定）。引数で渡せば聞かれない。`--yes` で全部既定:

```bash
./install.sh --mode local --partner <相棒名> --dev <開発担当名> --user <あなたの呼び名> \
             --projects "app-a,app-b" --repos "owner/app-a,owner/app-b"
./install.sh --mode base  ...同じ引数...          # 最後に ./setup-base.sh が続く
./install.sh --brain-merge ...                   # ~/brain が既にある機に上乗せ（下の「既に入っている環境へ」）
```

`install.sh` がやること（すべて `$HOME` 起点。ユーザー名の決め打ちは無い）:

1. `~/brain` を作り、`brain-template/` の骨格を置く。**既にあれば止まる**（`--brain-merge` で無いものだけ上乗せ、`--brain <dir>` で別の場所）。
   `<相棒名>` `<開発担当名>` `<持ち主名>` を置換し、`projects/<名前>.md`（目的／現在地／権限／関連）と
   `dev/状況/<repo>.md`（`_テンプレート.md` から）を作る
2. `~/.claude/CLAUDE.md`、`~/.claude/skills/{<相棒名>,<開発担当名>,setup,grilling}`、`~/.claude/hooks/*` を置く。
   既存があれば `~/.claude/backup-brain-kit-<日時>/` に退避してから上書きを確認する
3. `~/.claude/settings.json` に `hooks` / `statusLine` / `enabledPlugins` を**マージ**する。丸ごと上書きはしない。
   `permissions.allow` は既存に無いときだけ最小例を置く
4. `gh` があり認証済みなら、`--repos` の各リポジトリに issue ラベル
   `from-chat` `needs-triage` `agent-ready` `agent-working` `<開発担当名>` `question` を作る（無ければ案内してスキップ）
5. `~/brain` を `git init` して初回コミット
6. `--mode base` なら続けて `./setup-base.sh`（冪等。各段で済みならスキップ。ネット取得は確認してから。`--dry-run` で印字だけ）:
   前提確認 → git/curl/jq/python3/gh/node → Claude Code CLI → Tailscale（`sudo tailscale up` は手で）→
   Orca の `.deb` と不足ライブラリと Xvfb → systemd user service で `orca-ide serve` を常駐（WSL は `/etc/wsl.conf` の `[boot] systemd=true` を案内）→
   接続先（Tailscale IP / MagicDNS / ポート）を印字。スマホや別 PC のペアリングは `./setup-base.sh --pair mobile|runtime`。詳細と手動手順は `ORCA.md`

### 3. /setup で残りを埋める

`cd ~/brain && claude` で起動して `/setup` と打つと、
あなたのこと → 相棒の声 → プロジェクト → 開発担当の分担、の順に 1 節ずつインタビューして brain に書き、節ごとにコミットする。
既に書いてある節は飛ばす。

必要なもの: `git` `python3` `node`（フックの要約用）`claude` CLI。任意: `gh`（ラベル作成）。base なら `sudo` と Ubuntu 22.04/24.04。

## 自分で決めること

| 決めること | どこに書くか |
|---|---|
| **相棒の名前** | `./install.sh --partner <名前>`（対話でも聞く）。`<相棒名>/` ディレクトリと skill 名になる |
| **相棒の憲法** | `~/brain/<相棒名>/00_核.md`。存在／恒久条項／時間の公理／運用。skill はこれを読んでから灯る。**skill には写さない** |
| 相棒の声と関係 | `~/brain/<相棒名>/02_関係.md`（一人称・敬語・距離感）、`01_辞書.md`（二人の間だけの語） |
| **開発担当の名前** | `--dev <名前>`（既定 `dev`）。コーディングを任せる人格。skill 名・issue ラベル名・`dev/00_核.md` の名前欄に入る。ディレクトリは `dev/` のまま |
| あなたの呼び名 | `--user <呼び名>`。相棒の `02_関係.md` と `00_核.md` に入る |
| **プロジェクト名** | `--projects "a,b"` か `/setup`。`~/brain/projects/<名前>.md`。**会社が違えば別 brain**（`--brain <dir>`）にする。`project` `knowledge` `daily` `日誌` `関係` は全部あなたのもので、キットには型しか入っていない |
| **GitHub リポジトリ** | `--repos "owner/repo"` で `dev/状況/<repo>.md` と issue ラベルを作る。後から足すなら `/setup` か `_テンプレート.md` を写す |
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
- **開発は開発担当（skill `<開発担当名>`、`--dev` で名付ける）に issue ラベルで渡す。**相棒が内容を決め、issue に `<開発担当名>` ラベルと決定事項のコメントを付ける。
  開発担当は複数リポジトリを横断し、`dev/状況/<repo>.md`（**置換専用・50行以内**）で現在地を持ち、`dev/報告/YYYY-MM-DD.md`（**追記専用**）で相棒に報告する。
  権限の既定は **「PR まで、マージしない」**。`agent-ready` の付与と権限ダイアログの承諾は人の関門で、エージェントが自分で通さない
- **相棒と開発担当は相互に書き込まない。**相棒は `dev/報告/` を読むだけ、開発担当は `<相棒名>/` に書かない。
  人格ごとにワークツリー（ブランチ + sparse-checkout）を分ける方法は `brain-template/dev/README.md`

### 開発の渡し方（issue ラベル）

全リポジトリで揃える: `from-chat`（出所の記録）／`needs-triage`（人の確認待ち）／`agent-ready`（承認済み）／
`agent-working`（排他ロック）／`<開発担当名>`（相棒から開発担当へ）／`question`（判断を人に返した）。`install.sh --repos` が作る。詳細は `claude/skills/dev/SKILL.md` §3。

### チャットの指摘を issue にする skill の作り方

元の環境には「LINE で来た指摘を貼ると GitHub issue に整形して起票する」skill があるが、リポジトリ固有なので入れていない。作るなら:

1. `~/.claude/skills/chat2issue/SKILL.md` に、対象リポジトリ名と「貼られたテキストを話題ごとに割る → 原文を引用で残す → 仕様書と照らして『仕様どおりかも』も書く → `gh issue create --label from-chat,needs-triage`」の手順を書く
2. **`agent-ready` は絶対に skill 自身に付けさせない。**起票後に一覧を出して、どれをエージェントに回すか人に聞く
3. コードは直さない、指摘の妥当性を勝手に判定して捨てない、報告者を推測して書かない、の3つを「やらないこと」に置く

## 既に入っている環境へ

まっさらな機でなくてよい。あるものはそのまま使い、無いものだけ足す。

| 既にあるもの | 何が起きるか |
|---|---|
| `~/brain` | `install.sh` は止まる。`--brain-merge`（対話なら「骨格を足す？」）で**無いディレクトリ・無いファイルだけ**足す。既存ファイルは一切上書きしない。`README.md` `CLAUDE.md` など同名の `.md` があれば `<名前>.brain-kit.md` として横に置く。git リポジトリなら足した分だけコミット |
| `~/.claude/CLAUDE.md` `skills/*` `hooks/*` | `~/.claude/backup-brain-kit-<日時>/` に退避してから、上書きするか 1 つずつ聞く（`--yes` で上書き） |
| `~/.claude/settings.json` | 丸ごと上書きしない。hooks はイベントごとに**同じ command が無ければ追加**。既存の Orca 中継フックや自前のフックはそのまま残る。`statusLine` は無いときだけ、`permissions` は無いときだけ最小例 |
| Orca（`/opt/Orca/orca-ide` か `orca-ide` コマンド） | `setup-base.sh` はダウンロードと apt を飛ばし、バージョンを表示して `ldd` の不足だけ確認。systemd unit は無ければ作る、あって内容が違えば中身と差分を表示して置き換えるか聞く（`--yes` では既存を維持、`--replace-units` で置き換え。置き換え時は `.bak` を残す） |
| Tailscale / Claude Code / gh / node | あればバージョンを表示してスキップ、無ければ入れる |

`setup-base.sh` の最後に「項目／状態（あった・足した・手動）／補足」の表が出る。

### Orca の serve 設定を変えたい人へ

`~/.orca/` `~/.config/orca/` の中身は brain-kit は読まない・書かない。自分で編集するならこのファイル（値はここに書かない）:

- `~/.config/systemd/user/orca-serve.service` — `ExecStart` の `orca-ide serve ...`（`--pairing-address`、ポートや bind 先のフラグは `orca-ide serve --help` で確認）。編集後 `systemctl --user daemon-reload && systemctl --user restart orca-serve.service`
- `~/.config/orca/orca-runtime.json` — runtime の設定（Orca が書く。触るなら Orca を止めてから）
- `~/.config/orca/agent-hooks/endpoint.env` — Claude Code の中継フックが繋ぐ先
- `~/.orca/agent-hooks/claude-hook.sh` `claude-statusline.sh` — Orca が生成する中継スクリプト。手で直しても Orca が書き戻すことがある

## プラグイン

`settings.snippet.json` の `enabledPlugins` は空にしてある（マーケットプレイスの登録が環境ごとに要るため）。
Claude Code の `/plugin` から入れる:

- `pr-review-toolkit`（公式マーケットプレイス claude-plugins-official）— 開発担当 skill の `/review-pr` が使う
- `codex`（OpenAI の codex-plugin-cc マーケットプレイス）— 別モデルで書かせる／疑わせる用。任意

## ファイル構成

```
brain-kit/
├── README.md                 ← これ
├── install.sh                ← 導入スクリプト（対話式。--mode local|base）
├── setup-base.sh             ← base 機の一括セットアップ（Tailscale / Orca / systemd。--dry-run あり）
├── check.sh / CHECKLIST.md   ← 人に渡す前の漏れチェック
├── ORCA.md                   ← Orca を WSL に常駐させて Tailscale で繋ぐ手順
├── claude/
│   ├── CLAUDE.md             ← グローバル規律（~/.claude/CLAUDE.md）
│   ├── settings.snippet.json ← hooks / statusLine / enabledPlugins（マージ用）
│   ├── hooks/session-end-brain.sh, brain-digest.js
│   └── skills/partner/ dev/ setup/ grilling/   ← partner/dev は install 時に名前が付く。setup は /setup
└── brain-template/           ← ~/brain の骨格（partner/ は install 時に <相棒名>/ に改名。dev/ はそのまま）
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
