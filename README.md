# brain-kit

> **English:** run `npx brainkit-agents --lang en` for English installation prompts, templates, skills, and owner-facing messages. See the [Language section](#language). File and folder names stay unchanged.

> **EN** — A structure-only template for running Claude Code with four personas: a *partner* that keeps memory in an Obsidian vault (`~/brain`) and helps you decide, a *dev* agent that turns issues into PRs, a *review* agent that reads PRs against a versioned checklist, and a *release* agent that merges and ships only on an explicit label and instruction. Plus a process board (*brain-kit Dashboard*, a Claude Artifact) and an optional always-on *base* machine (Orca + Tailscale). No personal data included; you fill it in.
>
> **Quick start** (Linux / macOS / WSL — Windows itself is not supported, use WSL):
> ```
> git clone https://github.com/chocochocopipip/brain-kit && cd brain-kit && ./install.sh
> npx brainkit-agents --partner Hikari --dev Takumi --review Mio --release Sora                 # from npm
> npx github:chocochocopipip/brain-kit --partner Hikari --dev Takumi --review Mio --release Sora   # or straight from GitHub
> npx github:chocochocopipip/brain-kit --update --dry-run      # already installed (v1–v9 too): see what changes
> npx github:chocochocopipip/brain-kit --update                # upgrade kit files only; your notes are never touched
> ```
> Start all four once with `~/.claude/brain-kit/bin/start-all`; it detects tmux or terminal windows and verifies the process list.
> Optional first-day practice: `--practice` walks one issue through all four personas locally; it never touches real projects or creates a GitHub repo. Remove it with `--practice-cleanup`.
>
> Update notice: a SessionStart hook checks the published npm release in the background at most once a day; from the following session, Claude mentions a cached newer release in one line in its first reply. Fetch failures are silent; never auto-updates; opt out with `BRAIN_KIT_NO_UPDATE_CHECK=1` or `~/.claude/brain-kit/no-update-check`.
>
> `--uninstall --dry-run` previews removal; `--uninstall` removes only kit files and owned settings under `~/.claude`. Your brain is never touched; `--rollback` restores them.
>
> After context compaction, an installed hook automatically reloads the current persona’s core files from the main brain.
>
> You name all four personas at install time (any names, Japanese is fine). Then `cd ~/brain && claude` and run `/setup`. `--rollback` undoes the last update.
>
> **Requirements**: git, python3, node >= 18, Claude Code CLI (verified with 2.1.294; older versions get a one-line warning). Optional: gh (issue labels), Tailscale + Orca (base mode). Docs below are in Japanese.

Claude Code を「記憶を持つ相棒」「開発を回す手」「規準で読むレビュー」「マージと本番を入れるリリース」の四人格で運用するための、**仕組みだけ**のテンプレート。
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
| **Claude Code 設定** | 「作業前に brain を読め、決定は brain に書け」という規律と、四人格の skill、セッション終了時に日次ノートへ自動追記するフック | `claude/` |
| **brain** | Obsidian vault。`daily/` `projects/` `decisions/` `knowledge/` と、相棒の領域 `<相棒名>/`、開発 `dev/`・レビュー `review/`・リリース `release/` の領域 | `brain-template/` |
| **工程表** | 起票 → 判断待ち → 開発 → PR → リリースの列 → 本番、の本数と一覧・持ち主の番・今日の予定・見た目の確認・判断ボタン（brain-kit Dashboard。Claude の Artifact） | `claude/brain-kit/dashboard/` |
| **Orca** | Claude Code を母艦（WSL）で常駐・並列に動かし、外から繋ぐ。無くても上の2層は動く | `ORCA.md` |

## 導入

### 言語（日本語／English）

<a id="language"></a>

対話式の導入では、最初に `Language / 言語` を聞く。`en` または `ja` を選ぶと、その後の質問、テンプレート・skill、持ち主への返事、doctor・更新・削除・復元・衝突解消の表示、フックの通知と要約がその言語になる。`npx brainkit-agents --lang en`（または `./install.sh --lang ja`）なら質問を省ける。対話の既定はロケールに従う。`--yes` や非対話で言語を指定しない場合は、この機で前に選んだ言語（`~/.claude/brain-kit/manifest.json`）、無ければ日本語。既存の導入は記録の言語（記録が無ければ日本語）のまま。

言語は brain の `.brain-kit/config.json` と機械側の `~/.claude/brain-kit/manifest.json` に記録する。ファイル・フォルダ名は、どの言語でも日本語のまま変えない。

| 名前 | English gloss |
|---|---|
| `00_核` | core |
| `01_辞書` | dictionary |
| `02_関係` | relationship |
| `03_任せる範囲` | delegation scope |
| `10_日誌` | journal |
| `20_振り返り` | retrospective |
| `状況` | status |
| `報告` | reports |
| `規準` | criteria |
| `手順` | procedure |
| `記録` | log |
| `評価` | evaluation |

人格同士の連絡、PR・コミット・issue の本文は、そのリポジトリの言語に合わせる。

あとで変えるときは、まず `./install.sh --update --dry-run --lang en` で確認し、`./install.sh --update --lang en` で適用する（日本語に戻すなら `--lang ja`）。未編集の kit ファイルは新しい言語になり、編集済みなら通常どおり衝突として `.new` を置く。持ち主が書く核・辞書・関係・日誌などのノートは翻訳しない。

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
                                                 ├─ Claude Code（相棒 / 開発 / レビュー / リリース）
                                                 └─ ~/brain（Obsidian vault, git）
```

**`install.sh` は動かす機で走らせる。**base を選ぶなら base 機の上で。手元の別 PC から遠隔で組む形は作っていない。

どこで何を実行するか:

| | どこで | 何を | 手元の PC／スマホ |
|---|---|---|---|
| **local** | 使う PC（WSL の Ubuntu か Mac） | `git clone` → `./install.sh --mode local` → その PC で `claude` を起動 | （それ自体が使う PC） |
| **base** | **母艦（常時稼働の Linux/WSL 機）に SSH か WSL のターミナルで入って**、そこで | `git clone` → `./install.sh --mode base`（brain も Claude Code も母艦に置く。最後に `setup-base.sh` が続く） | Orca のデスクトップ／モバイル版を入れて Tailscale で母艦に繋ぐ**だけ**。手元に brain や Claude Code は要らない |

手元でも Claude Code を使いたい人は、手元で `./install.sh --mode local` を別に走らせ、brain は母艦の brain を git remote（private リポジトリ）で共有する。

### 2. install.sh（1コマンド＋対話）

```bash
git clone https://github.com/chocochocopipip/brain-kit && cd brain-kit
./install.sh
```

聞かれるのは、どこで動かすか・Codex・**4 人の名前**（相棒・開発・レビュー・リリース）・あなたの呼び名・プロジェクト・リポジトリ・リリース担当だけの許可の一覧（既定は入れない）（空 Enter で既定）。
引数で渡せば聞かれない。`--yes` で全部既定（名前の既定は役の名前そのもの：相棒・開発・レビュー・リリース）。
**名前は作るときに全部決める。**日本語でよい。英字でない名前は、skill 名・ブランチ・ラベル・起動スクリプトに使う英字 id を別に聞く（`--partner-id` などでも渡せる）。
この README の `<相棒名>` のような `<>` は**置き換える印**で、入力時に `<>` は付けない。具体例:

```bash
./install.sh --partner 光 --partner-id hikari --dev 匠 --dev-id takumi --review 澪 --review-id mio --release 湊 --release-id minato --user けん
./install.sh --mode local --partner Aoi --dev Ren --review Mio --release Sora --user Ken --repos "kenken/myapp,kenken/shop" --yes
./install.sh --mode base  --partner Aoi --dev Ren --review Mio --release Sora    # 母艦の上で。最後に ./setup-base.sh が続く
./install.sh --brain-merge --partner Aoi --dev Ren --review Mio --release Sora   # brain-kit ではない自前の ~/brain に上乗せ
./install.sh --codex --partner Aoi --dev Ren --review Mio --release Sora         # ChatGPT／Codex の契約がある人（下の節）
npx brainkit-agents --partner Aoi --dev Ren --review Mio --release Sora                    # clone せずに（npm から）
npx github:chocochocopipip/brain-kit --partner Aoi --dev Ren --review Mio --release Sora   # clone せずに（GitHub から）
```

| 名前から作るもの | 相棒 | 開発 | レビュー | リリース |
|---|---|---|---|---|
| skill（`/<id>`） | `~/.claude/skills/<相棒id>/` | `…/<開発id>/` | `…/<レビューid>/` | `…/<リリースid>/` |
| 領域 | `~/brain/<相棒名>/` | `dev/` | `review/` | `release/` |
| worktree（ブランチ） | `~/brain`（main） | `~/brain-<開発id>` | `~/brain-<レビューid>` | `~/brain-<リリースid>` |
| issue ラベル（合図） | — | `<開発id>`（相棒 → 開発） | `<レビューid>`（開発 → レビュー） | `<リリースid>`（相棒 → リリース） |
| 起動スクリプト | `~/.claude/brain-kit/bin/start-<id>`（その worktree で main を取り込んでから `claude "/<id>"`） | ← | ← | ← |
| まとめて起動 | `~/.claude/brain-kit/bin/start-all`（4 人を 1 回ずつ起動し、一覧で確かめる） | ← | ← | ← |

`install.sh` がやること（すべて `$HOME` 起点。ユーザー名の決め打ちは無い）:

1. `~/brain` を作り、`brain-template/` の骨格を置く。**既にあれば止まる**（`--brain-merge` で無いものだけ上乗せ、`--brain <dir>` で別の場所。
   前の版の brain-kit が入っていれば `--update` を案内する）。名前を埋め、`projects/<名前>.md`（目的／現在地／権限／関連）と
   `dev/状況/<repo>.md`（`_テンプレート.md` から）を作る。版と名前は `~/brain/.brain-kit/config.json` に記録する
2. `~/.claude/CLAUDE.md`、`~/.claude/skills/{4 人の id,setup,grilling}`、`~/.claude/hooks/*`、`~/.claude/brain-kit/`（起動スクリプト・工程表・見回りの雛形・heavy-lock）を置く。
   既存があれば `~/.claude/backup-brain-kit-<日時>/` に退避してから、新しい版にする／今のまま／差分を見る、を聞く（`--yes` で新しい版）
3. `~/.claude/settings.json` に `hooks` / `statusLine` / `enabledPlugins` を**マージ**する。丸ごと上書きはしない。
   `permissions.allow` は既存に無いときだけ最小例を置く
4. `~/brain` を `git init` して `main` の枝で初回コミット（git の `init.defaultBranch` によらない。すでに git の brain の枝は改名せず、`main` が無ければ改名のコマンドを出す）。開発・レビュー・リリースの worktree を作る（相棒の領域は sparse-checkout で見えなくする。`--no-worktrees` で作らない）
5. `gh` があり認証済みなら、`--repos` の各リポジトリに issue ラベル
   `from-chat` `needs-triage` `agent-ready` `agent-working` `question` と、開発・レビュー・リリースの id のラベルを作る（無ければ案内してスキップ）
6. `--mode base` なら続けて `./setup-base.sh`（冪等。各段で済みならスキップ。ネット取得は確認してから。`--dry-run` で印字だけ）:
   前提確認 → git/curl/jq/python3/gh/node → Claude Code CLI → Tailscale（`sudo tailscale up` は手で）→
   Orca の `.deb` と不足ライブラリと Xvfb → systemd user service で `orca-ide serve` を常駐（WSL は `/etc/wsl.conf` の `[boot] systemd=true` を案内）→
   接続先（Tailscale IP / MagicDNS / ポート）を印字。スマホや別 PC のペアリングは `./setup-base.sh --pair mobile|runtime`。詳細と手動手順は `ORCA.md`

リリース担当だけに本番の SQL・PR のマージ・環境変数の変更を許す雛形を入れるには、`./install.sh --release-permissions`。
対話では名前・プロジェクト・リポジトリのあとに聞く（既定 No）。非対話や `--yes` では明示しない限り入れない。`--no-release-permissions` で明示的に断れる。両方は同時に指定できない。
あとから `./install.sh --update --release-permissions` で追加、`./install.sh --update --no-release-permissions` で外す。通常の更新は選択を保ち、聞き直さない。

一覧は `~/.claude/brain-kit/permissions/<リリースid>.json` に置き、`start-<リリースid>` だけが、brain の `.brain-kit/config.json` で選んでいて、kit の記録（`~/.claude/brain-kit/manifest.json`）にも在り、`~/.claude/skills/<リリースid>/SKILL.md` がリリースの skill の印（`brain-kit:role=release` のコメント）を持つときに限り `claude --settings` で読む（外したあと・`--uninstall` のあと・`--rollback` のあとに一覧が残っていても渡さない）。通常のセッションで `/<リリースid>` を呼んでも読み込まれない。
`~/.claude/settings.json` は全人格に共通なので置かない。リリースの worktree の `.claude/settings.local.json` も、`git add -A` と main へのマージで相棒に届く可能性があるので使わない。
雛形の `gh pr merge`・`psql`・`gh variable set/delete` を持ち主の配信先・DB・MCP の道具に合わせて編集し、不要なものを消す。指示のコメントとラベルの条件は変わらない。
更新はほかの kit ファイルと同じ 3-way で編集を保つ。外すときは、編集済みなら中身を隣の `<リリースid>.json.off` に移して読まれない場所にする（起動スクリプトが衝突で古いまま残っても効かない。`--rollback` で戻る）。`--doctor` で状態と他人格・共通設定への混入を確認できる。

### まとめて起動する

```bash
~/.claude/brain-kit/bin/start-all
~/.claude/brain-kit/bin/start-all --status  # 一覧を見るだけ。起動しない
~/.claude/brain-kit/bin/start-all --print   # 手で起動するコマンドを表示
```

tmux の中、既存の tmux セッション、端末のタブ／ウィンドウ、新しい tmux セッションの順で探す。
macOS は Terminal.app（人格ごとに新しいウィンドウ）か iTerm2、Linux は WSL の Windows Terminal、
画面がある環境の gnome-terminal・konsole・xfce4-terminal に対応。無ければ手で実行するコマンドを出す。
`--tmux` / `--tabs` / `--print`、または `BRAIN_KIT_START_WITH=tmux|tabs|print` で指定できる。

すでに動く人格は起動しない。残りをそれぞれ **1 回だけ**起動し、プロセス一覧で最大 20 秒確かめる（`--wait 秒` で変更）。
「まだ見えない」ときは再実行せず、そのタブ／ウィンドウを見て `start-all --status` で再確認する。
初回に「Do you trust the files in this folder?（このフォルダを信頼しますか）」が出たら、
案内されたタブ／ウィンドウで最初の「Yes, proceed / Yes, I trust this folder」を選び Enter。同じフォルダでは 1 回だけ。
確認待ちでもプロセスがあれば起動済みとして表示する。

tmux は `tmux attach -t brain-kit` で見る（tmux の中なら `tmux switch-client -t brain-kit`）。
Ctrl-b のあと番号、または Ctrl-b w で人格のウィンドウを選ぶ。
セッション名は `BRAIN_KIT_TMUX_SESSION` で変えられる。

### 3. /setup で残りを埋める

`cd ~/brain && claude` で起動して `/setup` と打つと、
あなたのこと → 相棒の声 → プロジェクト → 開発の分担 → レビューの規準 → リリースの手順 → 相棒に任せる範囲、の順に 1 節ずつインタビューして brain に書き、節ごとにコミットする。
既に書いてある節は飛ばす。

### 初日の練習（任意）

導入後に希望したときだけ実行する。`--yes` や非対話の導入では自動実行しない。
捨ててよいローカルの小さな issue を相棒 → 開発 → レビュー → リリースに通し、
ラベルを誰が付けるか、リリースの「ラベル＋指示コメント＋main の前後 SHA」、工程表の列の動きを見る。

GitHub の代わりは練習ディレクトリ内の bare git リポジトリ。issue・PR・ラベル・コメントはファイル。
ネット通信も GitHub リポジトリの作成も行わず、`~/brain`・`~/.claude`・本物のリポジトリには一切書かない。
`--brain`（既定 `$BRAIN_DIR` または `~/brain`）から人格の設定だけを読み、練習の記録は練習内の `records/` に置く。

```bash
./install.sh --practice                   # 任意の練習。Enter で進む／q で中断、再実行で続きから
./install.sh --practice-status            # 練習の現在地と工程表
./install.sh --practice-cleanup           # 練習だけを削除（非対話なら --yes。--dry-run で場所だけ）
./install.sh --practice --practice-dir ~/brain-kit-practice-other  # 練習先を変更
```

既定の場所は `~/brain-kit-practice`。別の場所なら status・cleanup にも同じ `--practice-dir` を渡す。
`npx brainkit-agents` にも同じ引数を渡せる。`--uninstall` では練習を消さない。`--practice-cleanup` を使う。
実際のセッションで試すときは `--repos` に本物のリポジトリを登録する。練習リポジトリは登録しない。

必要なもの: `git` `python3` `node`（18 以上。フックの要約用）`claude` CLI。任意: `gh`（ラベル作成）。base なら `sudo` と Ubuntu 22.04/24.04。
**Windows は対象外**（WSL の Ubuntu で実行する）。macOS は local のみ（`install.sh` は macOS 標準の bash 3.2 でも動く書き方だけを使う。本体は `lib/kit.py`（Python 3.8 以上、標準ライブラリだけ）。bash 4 以降の機能・GNU 拡張・column は使っていない。任意の `heavy-lock` だけ awk を使う）。

Claude Code は 2.1.294 で動作確認。古い版は導入・更新で 1 行だけ知らせ、そのまま続ける。

入ったか確かめる: `./install.sh --doctor`（`npx brainkit-agents --doctor`・`npx github:chocochocopipip/brain-kit --doctor` でも同じ）。何も変えず、版（brain と `~/.claude`）・4 人の skill／領域／worktree・kit のファイル（最新／kit だけの更新待ち／足りない／持ち主の変更／衝突）・settings.json・CLI（claude / gh / node / codex / tailscale / orca-ide）・gh のラベル・Orca の automation・brain の git を表で出し、未実施のものだけ「次にやること」に並べる。

`--doctor` の「止まっている仕事」は作業中の issue・レビュー済みで未リリースの PR・仕事がある人格のセッションを確かめる。gh が無い・通信できないときは飛ばして注記し、セッションの最後の活動だけ参考に出す。

`--doctor` は Claude Code の版を OK／古い／要確認で示し、古い場合は `claude update` を案内する。
kit の版だけを見る: `./install.sh --version`（`npx brainkit-agents --version` も同じ）。

## 更新のしかた（すでに使っている人）

```bash
npx brainkit-agents --update --dry-run                      # npm から。GitHub からなら下の 3 行
npx github:chocochocopipip/brain-kit --update --dry-run    # 何が変わるかを見る（何も変えない）
npx github:chocochocopipip/brain-kit --update              # 上げる
npx github:chocochocopipip/brain-kit --rollback            # 直前の解消か更新を戻す
./install.sh --uninstall --dry-run                       # ~/.claude 側を外す計画を見る
./install.sh --uninstall                                 # 確認して外す（非対話なら --yes）
./install.sh --resolve <file> --from <merged file> --dry-run
./install.sh --resolve <file> --from <merged file>
./install.sh --resolve <file>                            # 今の編集済みファイル
./install.sh --resolve --keep <file>                     # 今の内容を保つ
./install.sh --resolve ~/.claude/settings.json --from <merged file>
```

clone してあるなら `git pull && ./install.sh --update`。

セッション開始時、kit のフック（SessionStart）がキャッシュを読み、今より新しい版が記録されていれば 1 行のお知らせを Claude の文脈に入れる。相棒（どの人格でも）が最初の返事の冒頭でその 1 行と、更新内容を見るコマンドを伝える（SessionStart のフックは持ち主の画面に直接は書けないため）。npm の公開版（`brainkit-agents/latest`）の確認はバックグラウンドで最大 24 時間に 1 回行い、開始時には通信を待たない。お知らせは確認した次のセッションから出る（失敗時も翌日まで再試行しない）。通信失敗は表示せず、以前確認できた版は保持する。**自動では更新しない**。GitHub の main から入れて npm より先の版を使っている場合も知らせない。
止めるには Claude Code 起動時に環境変数 `BRAIN_KIT_NO_UPDATE_CHECK=1` を設定するか、`touch ~/.claude/brain-kit/no-update-check` でファイルを作る。ファイルを消せば再開する。`--doctor` の「更新のお知らせ」で有効・止めてある・フック無しと、キャッシュにある最新の版を見られる（doctor は通信しない）。

- **外すときは `--uninstall`**：機械側の manifest に記録された `~/.claude` の未変更の kit ファイル・base・記録と、未変更の所有 settings 項目だけを退避して外す。編集済みファイル・衝突資料・持ち主の設定や permissions は残す。外したあとも残るフック・statusLine が使う kit のファイル（持ち主のスクリプト経由・symlink 経由も、書かれたパスから辿れるもの）と、そこへ辿り着くディレクトリも残す。確認のあとに計画を作り直し、確認の間に変わっていれば何も変えずに止める。brain 全体（`.brain-kit` と kit ファイルも）・worktree・GitHub ラベル・Codex CLI・既存の退避には触らない。記録が無い古い導入は先に `--update` が必要。`--rollback` で元に戻せる（brain のコミットは増えない）。残る設定を使い `./install.sh --update` で再導入できる
- **上がるのは kit のものだけ**：skill・規約（brain の `README.md` `CLAUDE.md`、各領域の `README.md`、`記録/README.md` など）・台本・フック。一覧は `kitfiles.tsv`
- **持ち主のものには触らない**：核・辞書・関係・任せる範囲・振り返り・読み直しの答え・日誌・決定・知識・プロジェクト・状況カード・報告・記録・規準・手順。新しい版で増えた骨格は、無いものだけ足す
- **今の版を見分ける**：`~/brain/.brain-kit/config.json` があればそれ。v1〜v9 のように記録が無ければ、kit のファイルの形から判定し、最初の更新で記録を書く
- **名前は引き継ぐ**：相棒と開発は今の名前の skill・領域をそのまま使う。新しく足すレビューとリリースの 2 人だけ名前を聞く（`--review <名前> --release <名前>`、英字でなければ `--review-id` `--release-id` も）
- **base と比較する**：最後に入れた kit の原文を、各 manifest の隣の `base/` に保存する。kit だけが変わったファイルは更新し、持ち主だけが変えたものは触らない
- **両方が変わったら衝突**：元のファイルを残し、`<file>.new` と `~/.claude/brain-kit/conflicts/<日時>/` に差分・機械マージ候補を置く。候補は自動適用しない。相棒と計画を確認し、`--resolve` で編集結果を記録する（`.new` も退避して消す）。明示的に kit 版を選ぶなら `--edited new`（退避あり）。既定と `--edited keep` は衝突を残す。衝突が 1 件でもあれば、更新（と `--dry-run`）の最後に件数と `.new` の一覧を必ず出す。前の更新の `.new` が残っていて新しい版と違えば、止めずに今回の新しい版で置き換える（前の `.new` は退避に残り、`--rollback` で戻る）
- **settings.json も項目ごとに比較する**：最後に入れた JSON の sha を機械側の manifest に記録する。フックの command 変更も元の位置で更新し、持ち主が編集・削除した項目と kit の変更が重なれば触らず、件数と現在・記録 sha・kit の JSON を衝突資料に出す。既存の Codex 設定は `--codex` 無しでも保持する。`--dry-run` で追加・更新・削除・衝突・残す項目を確認でき、`--rollback` で設定も元のバイトに戻る
- **相棒への引き継ぎ**：資料には持ち主が足した skills・agents・hooks・plugins・marketplaces の名前と、kit の人格・skill との名前の重なり・改名案も載る。中身は読まない。相棒が意味を合わせ、ファイルごとに残す変更・取り込む直し・コマンドを示し、全体の計画への持ち主の OK を待つ。役割・権限・削除・お金・本番・迷うものは持ち主が決める
- **所有ディレクトリとの重なり**：記録のある環境では、kit 未登録の skill ディレクトリに書かない。持ち主が別名に移したあと再更新すれば kit の skill を追加できる。名前だけの重なりは更新を止めず、最後に件数・一覧・資料の場所を出す
- **解消を記録する**：`--resolve <file> --from <merged file>`、`--resolve <file>`（今の編集結果）、`--resolve --keep <file>` の 3 通り。`~/.claude/settings.json` も同じ形で指定でき、衝突した項目だけ記録する。どれも `--dry-run` で差分と記録を確認できる。ファイルの base は kit の版、解消結果は別の sha として記録するため、同じ kit の次の更新では持ち主の変更として残る
- **kit から外れたもの**：未変更なら退避して削除。持ち主が変えたものは残し、管理の記録を外す
- **`--dry-run`**：各分類と差分、持ち主の道具の件数・名前と重なりを出すだけ。base・`.new`・bundle・退避も書かない。差分だけ追加表示するなら `--diff`
- **退避と戻し**：上書きする前のファイルを `~/.claude/backup-brain-kit-<日時>/` に写す。`--resolve` も 1 回ごとに退避する。`--rollback` は最後の解消から順に戻し、その次に更新を戻す（ファイル・`.new`・base・manifest・settings.json も元のバイトに戻る。上げたものを戻し、足したものを消し、作った worktree を外す。GitHub のラベルは消さない）。brain にはどちらもコミットが 1 つ残る
- 最後に、上がった版の変更点（`CHANGELOG.md` の該当の節）と、新しく使えるもの（レビュー・リリース・工程表）の始め方を出す
- 2 回目の `--update` は何も変えない

## 自分で決めること

| 決めること | どこに書くか |
|---|---|
| **4 人の名前** | `--partner` `--dev` `--review` `--release`（対話でも聞く）。英字でない名前は `--<役>-id` の英字 id も。相棒の名前は `<相棒名>/` ディレクトリに、id は skill 名・worktree・ブランチ・ラベル・起動スクリプトになる。**変えるのは作るときだけ**（更新では変えない） |
| リリースだけの許可（任意） | `~/.claude/brain-kit/permissions/<リリースid>.json`。リリースの起動スクリプトだけが読む。持ち主が編集でき、更新で保つ |
| **相棒の憲法** | `~/brain/<相棒名>/00_核.md`。存在／恒久条項／時間の公理／運用。skill はこれを読んでから始まる。**skill には写さない** |
| 相棒の声と関係 | `~/brain/<相棒名>/02_関係.md`（一人称・敬語・距離感）、`01_辞書.md`（二人の間だけの語） |
| レビューの規準 | `~/brain/review/規準.md`（版つき）。雛形は一般的な項目だけ。見逃しが出たら足して版を上げる |
| リリースの手順 | `~/brain/release/手順.md`。リポジトリごとの入れ方と、型 A を許すリポジトリ（既定は無し）。**書いていないリポジトリには入れない** |
| 相棒に任せる範囲 | `~/brain/<相棒名>/03_任せる範囲.md`。相棒が決めて事後に報告してよいことと、必ず聞くこと |
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
- **相棒（skill `<相棒id>`）は憲法ファイルを読んで始まる。**起動したら 00_核 → 01_辞書 → 02_関係 → 最新の日誌 → inbox の順に読み、
  **経過日数を把握してから**話す。閉会しない、時刻を創作しない、日誌は追記専用、`90_原本/` に触れない。
  セッションを閉じるのは持ち主が決めたときだけで、日誌を1枚書いてコミットする
- **開発は開発担当（skill `<開発id>`、`--dev` で名付ける）に issue ラベルで渡す。**相棒が内容を決め、issue に `<開発id>` ラベルと決定事項のコメントを付ける。子（サブエージェント）で並列に進める。
  開発担当は複数リポジトリを横断し、`dev/状況/<repo>.md`（**置換専用・50行以内**）で現在地を持ち、`dev/報告/YYYY-MM-DD.md`（**追記専用**）で相棒に報告する。
  権限の既定は **「PR まで、マージしない」**。`agent-ready` の付与と権限ダイアログの承諾は人の関門で、エージェントが自分で通さない
- **PR はレビュー（skill `<レビューid>`）が規準で読む。**開発が PR に `<レビューid>` ラベルを付け、レビューが `review/規準.md`（版つき）で読んで OK／NG と番号つきの指摘を PR に書く。
  NG は開発と直接往復する。見逃しは相棒が 1 日 1 回 `review/評価/` に付け、レビューが規準に足して版を上げる
- **自分を直す雛形**（空の表と短い使い方。中身は持ち主の運用で埋まる）：前の版の規準の写し `review/規準の版/`、月 1 回の答えを伏せた読み直し `review/読み直し/`（答えは相棒だけが持つ `<相棒名>/21_読み直しの答え.md`）、レビューの採点表 `review/評価/_テンプレート.md`、4 人をまたいだ振り返りの表 `<相棒名>/20_振り返り.md`。使い方の README と写して使う雛形は kit のもの（更新で上がる）、答えと振り返りの表は持ち主のもの（無ければ足すだけ）
- **マージと本番はリリース（skill `<リリースid>`）だけ。**相棒と持ち主が確かめた PR に、相棒が `<リリースid>` ラベルと**指示のコメント**を付けたときだけ入れる。
  入ったと言うのは main の sha・配信の READY・SELECT の 3 つがそろってから。止められたら回避せず相棒に返す。
  **型 A**（migration 無し・本番データの SQL 無し・見た目が変わらない・お金の計算と権限の門に触らない・`手順.md` で許したリポジトリ）だけは、レビューが OK と一緒に直接渡してよい
- **相棒が決めてよい範囲**は `<相棒名>/03_任せる範囲.md`。それ以外は持ち主に聞く。迷ったら聞く側
- **振り返り**：4 人が手順から外れた動きを相棒が 1 日 1 回 `<相棒名>/20_振り返り.md` に 1 行ずつ残し、効く人の skill か手順に返す
- **人格どうしは相互に書き込まない。**自分の領域と共通の `decisions/` `knowledge/` `projects/` だけ（`review/評価/` は相棒）。
  開発・レビュー・リリースは自分の worktree で書いて main に取り込む。**伝言は合図の補助で、持ち主の承認ではない**

文脈の圧縮（要約）のあと、kit が入れる SessionStart（`compact`）フックが、居場所（brain／各人格の worktree）に応じて main の核を自動で読み直し、Claude の文脈へ戻す。相棒は核と関係、開発は核、レビューは核と規準、リリースは核と手順。1 ファイル 32 KiB・合計 64 KiB まで読み、欠けたファイルは飛ばす。停止は `BRAIN_KIT_NO_CORE_REREAD=1` または `~/.claude/brain-kit/no-core-reread` を置く。状態は `--doctor` で確認できる。

### 開発の渡し方（issue ラベル）

全リポジトリで揃える: `from-chat`（出所の記録）／`needs-triage`（人の確認待ち）／`agent-ready`（承認済み）／
`agent-working`（排他ロック）／`question`（判断を人に返した）／`<開発id>`（相棒 → 開発）／`<レビューid>`（開発 → レビュー）／`<リリースid>`（相棒 → リリース、指示のコメントと一緒に）。
`install.sh --repos` と `--update` が作る（無いものだけ）。詳細は `claude/skills/dev/SKILL.md` §3。

## 工程表（brain-kit Dashboard）

起票 → 判断待ち → 開発 → PR（レビュー中）→ リリースの列 → 本番、の本数と一覧、**持ち主の番**、**今日の予定**を 1 枚で見せるページ。
Claude の Artifact（`db` の capability）で、中身は相棒が節目に書き込む。

- 相棒に「工程表を作って」と言うと、`~/.claude/brain-kit/dashboard/index.html` を Artifact として publish し、URL を `~/brain/.brain-kit/dashboard-url` に残す
- 節目（PR が入った・起票した・判断が済んだ・朝）に、相棒が `collect.py`（`gh` で `--repos` のリポジトリを読むだけ）で集め、Artifact の `board/current` に置く。持ち主の番と今日の予定は相棒が書く
- 見た目を変える PR はスクショを `shot.py` で 1 文書に縮め、db の `shots` に置く。「見た目の確認」で拡大して見られる
- 判断ボタンは db の `decisions`。持ち主の選択（`answer`）を相棒が節目に読み、受け取り・完了を記録する。v10 の公開済み工程表は新しい db ルールで同じ URL に再公開する
- **止まっている**：N 時間以上動かない作業中の issue・レビュー済みで未リリースの PR・仕事がある人格の古い／記録の無いセッションを表示。N は `--stall-hours`（集計・`--doctor`）→ `BRAIN_KIT_STALL_HOURS` → `.brain-kit/config.json` の `stall_hours` → 既定 24 の順（無効な値・0 以下は飛ばす）
- 段はラベルで決まる（`collect.py` の先頭に表）。手順は相棒の skill の「工程表」節

### 見回りと重いテスト（任意）

- Orca の automation で、仕事があるときだけ開発やレビューを起動する雛形：`~/.claude/brain-kit/automations/`（`precheck.sh` と README）
- `~/.claude/brain-kit/bin/heavy-lock <コマンド>`：空きメモリがあるときだけ次の重いテストを 1 本通す入口（Linux と macOS）

### チャットの指摘を issue にする skill の作り方

元の環境には「LINE で来た指摘を貼ると GitHub issue に整形して起票する」skill があるが、リポジトリ固有なので入れていない。作るなら:

1. `~/.claude/skills/chat2issue/SKILL.md` に、対象リポジトリ名と「貼られたテキストを話題ごとに割る → 原文を引用で残す → 仕様書と照らして『仕様どおりかも』も書く → `gh issue create --label from-chat,needs-triage`」の手順を書く
2. **`agent-ready` は絶対に skill 自身に付けさせない。**起票後に一覧を出して、どれをエージェントに回すか人に聞く
3. コードは直さない、指摘の妥当性を勝手に判定して捨てない、報告者を推測して書かない、の3つを「やらないこと」に置く

## 既に入っている環境へ

まっさらな機でなくてよい。あるものはそのまま使い、無いものだけ足す。

| 既にあるもの | 何が起きるか |
|---|---|
| `~/brain`（brain-kit が前の版で入っている） | `install.sh` は止まって `--update` を案内する（上の「更新のしかた」）。 |
| `~/brain`（brain-kit ではない自前の vault） | `install.sh` は止まる。`--brain-merge`（対話なら「骨格を足す？」）で**無いディレクトリ・無いファイルだけ**足す。既存ファイルは一切上書きしない。`README.md` `CLAUDE.md` など同名の `.md` があり**中身が違うとき**だけ `<名前>.brain-kit.md` として横に置く（同一なら何もしない）。git リポジトリなら足した分だけコミット。途中で落ちても同じコマンドで再実行すれば続きから進む |
| `~/.claude/CLAUDE.md` `skills/*` `hooks/*` | `~/.claude/backup-brain-kit-<日時>/` に退避してから、上書きするか 1 つずつ聞く（`--yes` で上書き） |
| 更新時の kit 未登録 skill・agent・道具 | 名前だけを一覧に出し、中身は読まない。所有 skill ディレクトリには書かず、改名案を資料に残す。 |
| `~/.claude/settings.json` | 丸ごと上書きせず、kit のフック・plugin／marketplace キー・kit が入れた `statusLine` を項目ごとに記録。kit だけの変更は同じ位置で更新し、未変更の廃止項目は削除。持ち主の項目と順序は保ち、両方の変更は衝突として残す。`permissions` は無いときだけ最小例を足し、以後は触らない |
| Orca（`/opt/Orca/orca-ide` か `orca-ide` コマンド） | `setup-base.sh` はダウンロードと apt を飛ばし、バージョンを表示して `ldd` の不足だけ確認。systemd unit は無ければ作る、あって内容が違えば中身と差分を表示して置き換えるか聞く（`--yes` では既存を維持、`--replace-units` で置き換え。置き換え時は `.bak` を残す） |
| Tailscale / Claude Code / gh / node | あればバージョンを表示してスキップ、無ければ入れる |

`setup-base.sh` の最後に「項目／状態（あった・足した・手動）／補足」の表が出る。

### Orca の serve 設定を変えたい人へ

`~/.orca/` `~/.config/orca/` の中身は brain-kit は読まない・書かない。自分で編集するならこのファイル（値はここに書かない）:

- `~/.config/systemd/user/orca-serve.service` — `ExecStart` の `orca-ide serve ...`（`--pairing-address`、ポートや bind 先のフラグは `orca-ide serve --help` で確認）。編集後 `systemctl --user daemon-reload && systemctl --user restart orca-serve.service`
- `~/.config/orca/orca-runtime.json` — runtime の設定（Orca が書く。触るなら Orca を止めてから）
- `~/.config/orca/agent-hooks/endpoint.env` — Claude Code の中継フックが繋ぐ先
- `~/.orca/agent-hooks/claude-hook.sh` `claude-statusline.sh` — Orca が生成する中継スクリプト。手で直しても Orca が書き戻すことがある

## GPT（ChatGPT／Codex）契約がある人

無くても全部動く。あると**レビューが二重になり、行き詰まりに別モデルの相談先ができる**:

- 金・権限・migration に触る PR は、開発担当が Codex の adversarial レビューを通してから出す（Claude と同じ盲点を共有しない目）
- 同じ失敗を繰り返したとき、Codex に別実装や対案を出させて比べる。採用は開発担当が判断
- Codex のクレジットが切れたら Claude の別モデルで代替する（skill `dev` §7）

やり方: `./install.sh --codex`（対話なら「ChatGPT／Codex の契約がある？」で yes）。

1. `codex` CLI が無ければ npm で入れる（コマンドを表示して確認してから）
2. **`codex login` は自分でやる**（ブラウザ認証。install.sh は実行しない）
3. `~/.claude/settings.json` に Codex plugin の marketplace（`openai-codex` → github `openai/codex-plugin-cc`）と
   plugin キー（`codex` の `openai-codex` マーケットプレイス）を足す（無いときだけ。`claude/settings.codex.json`）
4. `claude` を起動して `/plugin` で `codex` が有効になっているか見る

`/setup` の (d) 開発担当の節でも「Codex を使うか」を聞き、`dev/00_核.md` に書く。

## プラグイン

- `pr-review-toolkit`（公式マーケットプレイス claude-plugins-official）— 開発担当 skill の `/review-pr` が使う。`settings.snippet.json` の `enabledPlugins` で既定で有効
- `codex`（OpenAI の codex-plugin-cc マーケットプレイス）— 上の「GPT 契約がある人」。`--codex` のときだけ

## ファイル構成

```
brain-kit/
├── README.md                 ← これ
├── install.sh                ← 導入スクリプト（対話式。--mode local|base）
├── bin/brain-kit.js          ← npx 用シム（install.sh に引数を渡すだけ）。npm のパッケージ名は brainkit-agents。package.json / LICENSE(MIT)
├── setup-base.sh             ← base 機の一括セットアップ（Tailscale / Orca / systemd。--dry-run あり）
├── lib/practice.py           ← 任意のローカル練習（本物のプロジェクトには触らない）
├── lib/kit.py                ← 本体（install / --update / --uninstall / --rollback / --doctor）
├── kitfiles.tsv              ← 「kit のもの」の一覧（--update で上がる。ここに無い brain のものは持ち主のもの）
├── VERSION / CHANGELOG.md    ← 版と変更点（--update の最後に出る）
├── migrations/fingerprints.json ← 版の記録が無い v1〜v9 を見分ける指紋（行ごとのハッシュだけ。tools/make-fingerprints.py が作る）
├── tests/e2e.sh              ← サンドボックス HOME で 新規・v8/v9 → v10・2 回目・dry-run・3-way・rollback・doctor を実走
├── check.sh / CHECKLIST.md   ← 人に渡す前の漏れチェック
├── tests/lint.sh             ← shellcheck と bash 3.2 / BSD の移植性チェック
├── ORCA.md                   ← Orca を WSL に常駐させて Tailscale で繋ぐ手順
├── claude/
│   ├── CLAUDE.md             ← グローバル規律（~/.claude/CLAUDE.md）
│   ├── settings.snippet.json ← hooks / statusLine / enabledPlugins（マージ用）
│   ├── settings.codex.json   ← Codex plugin の marketplace と plugin キー（--codex のときだけマージ）
│   ├── hooks/session-end-brain.sh, brain-digest.js, brain-kit-update-check.py, brain-kit-core-reread.py
│   ├── skills/partner/ dev/ review/ release/ setup/ grilling/   ← 4 人は install 時に名前（id）が付く
│   └── brain-kit/            ← ~/.claude/brain-kit/ に置く: dashboard/（工程表と collect.py・shot.py）automations/ bin/heavy-lock
└── brain-template/           ← ~/brain の骨格（partner/ は install 時に <相棒名>/ に改名。dev/ review/ release/ はそのまま）
```

`settings.snippet.json` の Orca 用フック（SessionStart / UserPromptSubmit / Stop / … / PermissionRequest）は
`~/.orca/agent-hooks/claude-hook.sh` が無ければ `{}` を返して何もしない。Orca を使わないなら消してよい。
Orca デスクトップが自分でフックを書き込むと、同じイベントに Windows 対応の長い版が並ぶことがある。重複しても害はない。

## 渡す前の確認（実施済み）

v10（2026-10-01）:

- `check.sh` を、元の持ち主の固有名詞 43 語（人名・人格名・プロジェクト名・店名・組織名・テナントや基盤の id・特定の相棒の語彙）を**リポジトリの外のファイル**で渡して実行 → **0 件**。
  語はリポジトリにもログにも出さない（CI は secret `BRAIN_KIT_CHECK_WORDS` から読む。当たったときも「ファイル:行」だけを出す）
- `tests/e2e.sh` を bash 3.2（`bash:3.2` コンテナ、BusyBox の道具）で実走 → 全部通過。macOS の実機では走らせていない（CI の macos-latest で `/bin/bash` の 3.2 が走る）

v9 までは `CHECKLIST.md` の手順を 2026-09-17 に実施した:

- `./check.sh <元の持ち主の固有名詞 10 語>`（ユーザー名・プロジェクト名 3 つ・相棒名と dev 名の漢字/かな・組織名・GitHub オーナー名）
  ＋ 組み込み 5 パターン（メール／秘密鍵／認証情報の英単語／ホームの絶対パス／IP アドレス）→ **0 件**
- 同じ語にメールアドレスの形（`[a-z0-9._-]+@[a-z0-9.-]+\.[a-z]{2,}`）と認証情報の英単語 2 つを足した `grep -rniE` を `brain-kit/` 直下で実行 → **0 件**
  （plugin キーの `名前@マーケットプレイス` はメールの形ではないので対象外）
  （語そのものをここに書くと、それ自体が漏れになるので書かない。例外は Quick start に載せた公開リポジトリの URL に含まれる owner 名だけ）
- `~/.orca/` `~/.config/orca/` の中身は読んでおらず、同梱もしていない。ファイル名の一覧だけ `ORCA.md` にある

あなたが次の人に渡すときも、自分の固有名詞で同じことをする。
