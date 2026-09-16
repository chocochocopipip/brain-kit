# Orca を母艦（WSL）に常駐させ、スマホから直接つなぐ

> **`./setup-base.sh` が以下を一括でやる**（`install.sh --mode base` の最後に呼ばれる。`--dry-run` で中身だけ印字）。
> 段: 前提確認 → 基本ツール → Claude Code → Tailscale → Orca（.deb・不足ライブラリ・Xvfb）→ systemd user service → 接続先の印字。
> ペアリングは `./setup-base.sh --pair mobile|runtime`。
> ここから下は**同じことを手でやる手順**と、その理由・失敗の記録。スクリプトが止まったときに読む。

Orca（stablyai/orca）は Claude Code などのエージェントをワークツリー単位で並べて動かす IDE。
デスクトップ版をノートで開いていないと母艦に届かない構成をやめ、**母艦の WSL に Orca 本体を入れて
`orca-ide serve` を常駐させ、Tailscale で直接つなぐ。**

## 結論（先に読む）

- Orca の実体を WSL 内にネイティブ導入し、`orca-ide serve` を **Tailscale と同じ名前空間**で走らせる
- **着手前に必ず `tailscale status` で、繋ぎたい端末が tailnet にいるかを確認する。**
  サーバー側をどう直しても、受け手が網の外にいれば届かない

## 手順

### 0. 前提の確認（ここを飛ばさない）

```bash
tailscale status
```

**接続元・接続先の両方が一覧に出ていること。**片方だけ確認して進むと、以降の切り分けが全部無駄になる。
スマホが居なければ Tailscale アプリを入れ、**同じアカウント**でログインする。

WSL 側の Tailscale IP を控える（`--pairing-address` に使う）:

```bash
tailscale ip -4      # WSL の中で叩く。Windows 側の値ではない
```

### 1. Orca（Linux 版）を WSL に入れる

配布物は GitHub Releases（`gh release view <version> --repo stablyai/orca` で一覧可）。

```bash
mkdir -p ~/opt && cd ~/opt
curl -fsSL -O https://github.com/stablyai/orca/releases/download/<version>/orca-ide_<version>_amd64.deb
sudo apt install -y "$HOME/opt/orca-ide_<version>_amd64.deb"
```

**この .deb は依存関係を宣言していない。**`ii` になっても起動しないので、共有ライブラリを実測して入れる:

```bash
ldd /opt/Orca/orca-ide | grep "not found"   # 実測してから入れる
sudo apt install -y libnss3 libnspr4 libasound2t64   # Ubuntu 24.04 の例
```

**推測で列挙せず `ldd` の実測から引くこと。**

### 2. ディスプレイを用意する（WSLg に依存しないこと）

`serve` はヘッドレスだが **Electron が X を要求する。**X が無いと `Missing X server or $DISPLAY` → `SIGSEGV` で落ちる。

**WSLg の `:0` を使ってはいけない。**WSLg の weston は落ちることがあり、落ちると Orca も道連れになる。
**自前で Xvfb を `:99` に立てる。**

```bash
command -v Xvfb || sudo apt install -y xvfb
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
```

### 3. サーバーを起動する

```bash
DISPLAY=:99 orca-ide serve --pairing-address <TailscaleのIP> --mobile-pairing
```

```
Orca server ready
Bound endpoint: ws://<全インターフェース>:6768
Advertised endpoint: ws://<TailscaleのIP>:6768
Mobile pairing QR: (QR)
Pairing URL: orca://pair?code=...
```

- `--mobile-pairing` はモバイル用スコープ。**付けない場合は runtime-environment 用**（別 PC の Orca を繋ぐ側）のリンクが出る
- フォアグラウンドで動く。切り離すなら後述の systemd に載せる
- **`pkill -f "orca-ide serve"` は使わないこと。**実行中のシェル自身のコマンドラインにマッチして自分を殺す

### 4. ペアリング

出力された `orca://pair?code=...` をスマホで開く（または QR を読む）。

> **ペアリングコードは認証情報。**brain にも他所にも書かない。起動ログにも残るので、確認後に削除する。

### 5. 検証

```bash
ss -lntp | grep 6768        # LISTEN しているか
ss -tnp  | grep 6768        # ESTAB があるか（接続元 IP を確認）
```

**ペアリングはプロセスではなくデバイスに紐づく。**サーバを再起動しても、ディスプレイを変えても、
ユニットを書き換えても、**スマホ側の再ペアリングは不要。**

## 常駐（systemd user サービス）

`~/.config/systemd/user/` に2本置く。**Xvfb を別ユニットにして依存させるのが要点。**

`xvfb.service`:
```ini
[Unit]
Description=Xvfb on :99 (Orca 用。WSLg/weston に依存しないため)
After=default.target
[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp
Restart=always
RestartSec=2
[Install]
WantedBy=default.target
```

`orca-serve.service`（公式ガイド `docs/reference/headless-linux-server.md` 準拠）:
```ini
[Unit]
Description=Orca headless runtime server
Requires=xvfb.service
After=xvfb.service default.target
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Type=simple
Environment=DISPLAY=:99
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=/usr/bin/orca-ide serve --pairing-address <TailscaleのIP> --mobile-pairing
StandardOutput=null          # ペアリングコードを journald に残さない
StandardError=journal
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5
[Install]
WantedBy=default.target
```

各行の理由（どれも実害の再発防止）:

- **`StartLimitBurst=5` / `StartLimitIntervalSec=300`** — 無制限にしてはいけない。
  一度の起動失敗が数千回のリスタートになり、その間 `systemctl is-active` が **`active` を返し続ける。**
  上限に達すると `systemctl start` も拒否される → `systemctl --user reset-failed orca-serve.service` で解除
- **`RestartPreventExitStatus=3`** — exit 3 は「別プロセスが userData プロファイルを保持中」。再試行しても成功しない
- **`KillMode=mixed`** — 停止シグナルを主プロセスにだけ送る。Electron が切断し終わるまで Xvfb を生かす
- **`LIBGL_ALWAYS_SOFTWARE=1`** — WSL に GPU は無い。ソフトウェア GL を強制する

```bash
systemctl --user daemon-reload
systemctl --user enable --now xvfb.service orca-serve.service
sudo loginctl enable-linger "$USER"   # ログインしていなくても起動させる（要 root）
```

注意: `Documentation=file://...` に日本語を URL エンコードして書くと `%E3` などが systemd の指定子として解釈される。コメント行で書く。

## 失敗の記録（同じ道を二度通らないため）

### ① リレーのシムでは `serve` できない
別 PC の Orca から母艦へ SSH リレーで入れた `~/.orca-relay/bin/orca` は**薄いシム**で、コマンドを転送するだけ。
`serve` は明示的に拒否される。母艦で本体を入れて直接走らせる。

### ② Windows 側に入れると名前空間が合わない
母艦が Windows + WSL2 のとき、Windows 側に Orca を入れて serve しても**スマホから届かない。**
Tailscale が WSL の中で動いているなら、`tailscale0` は WSL 側のインターフェースで、WSL2 と Windows はネットワーク名前空間が別。
**`tailscale ip -4` を叩いた場所と、サーバーを置く場所を揃える。**

### ③ 本当の原因は受け手側だった
①②を直しても届かなかった原因は、**スマホが tailnet に居なかった**こと。
環境ノートに「全デバイスを Tailscale で接続」と書いてあっても、**記録は書かれた時点の意図であって、現在の事実ではない。**

### ④ WSLg（weston）が周期的に SIGSEGV する
`Missing X server or $DISPLAY` でも `/tmp/.X11-unix/X0` への接続は成功する、という症状なら WSLg 側を疑う:

```bash
grep "terminated with signal 11" /mnt/wslg/stderr.log
```

weston が落ちる → X が消える → Orca が SIGSEGV → WSLGd が weston を再起動 → ループ。
**ソケットの存在は X の健全性を意味しない。**対処は **WSLg を直すのではなく、依存を切る**（自前 Xvfb `:99`）。
GUI 層をヘッドレスサーバーの単一障害点にしない。

## 公式ガイドとの差分（意図的に外したところ）

`gh api repos/stablyai/orca/contents/docs/reference/headless-linux-server.md -H "Accept: application/vnd.github.raw"` で読める。

| 公式 | この手順 | 理由 |
|---|---|---|
| AppImage を `/opt/orca` に | `.deb` で `/opt/Orca/orca-ide` | 両方入れると**二重インストール**になり、どちらが serve しているか分からなくなる |
| 専用システムユーザ `orca` を作り `User=orca` | 自分のユーザーの **user サービス** | セッションは自分のリポジトリ・worktree・git 認証で動く必要がある |
| `/etc/systemd/system/`（system サービス） | `~/.config/systemd/user/` | 上に同じ。**未ログイン時の起動には `loginctl enable-linger` が必須** |
| Orca に Xvfb を自動起動させる | 自前 `xvfb.service` を明示 | Orca 再起動のたびにディスプレイを作り直させない |

健全性チェックは `--json` で `{"type":"orca_server_ready",...}` が1行出るのを見るのが公式流。
ただし**その行にはペアリング URL が含まれる**ので、ログに残す場合は注意。

## 別 PC の Orca から母艦 runtime を使う

**「セッションを移す」操作は存在しない。**セッションの履歴はそれをホストしている runtime 側にある。
新規セッションを母艦 runtime に立てたいなら、母艦を runtime-environment としてペアリングする:

```bash
# 母艦: drop-in で一時的に --mobile-pairing を外し、--json の出力をファイルに落とす
mkdir -p ~/.config/systemd/user/orca-serve.service.d
cat > ~/.config/systemd/user/orca-serve.service.d/10-runtime-pairing.conf <<'CONF'
[Service]
ExecStart=
ExecStart=/usr/bin/orca-ide serve --pairing-address <TailscaleのIP> --json
StandardOutput=file:/path/to/pairing.json
CONF
systemctl --user daemon-reload && systemctl --user restart orca-serve.service
# pairing.json から .pairing.url を chmod 600 のファイルに取り出す（scope が "runtime" であること）
```

```bash
# 別 PC: ssh でコードを取って、そのまま食わせる。画面にもヒストリにも残らない
orca environment add --name base --pairing-code "$(ssh <母艦> cat /path/to/pairing.url)"
orca environment list   # base が出れば成功
```

終わったら **drop-in を消して restart、ペアリングファイルは `shred -u`。**

- `orca environment add` は**ローカルに保存するだけ**。判定は `orca environment list` で行う
- 単一インスタンスロックがあるため、**ペアリング用に2本目の serve を並べて立てることはできない**（`exit 3`）
- **ペアリングオファーには期限がある。**出したら続けて使う

以後、`--environment <name>` を付ければ別 PC から母艦の runtime を直接操作できる:

```bash
orca worktree list   --environment base
orca terminal create --environment base --worktree active --command "claude"
orca repo add        --environment base --path "$HOME/repos/<repo>"
```

疎通確認は `orca worktree list --environment base` が**エラーにならず `No worktrees found.` を返すこと。**
「空」は失敗ではない。`orca repo` には **`rm` が無い**。登録は足すだけなので、入れる前に対象を決めること。

## Orca が生成する設定ファイル（自分の環境で作る。人からコピーしない）

以下は初回起動・ペアリング時に Orca が自動生成する。**デバイス鍵・ペアリング状態・認証情報を含むので、
他人の環境からコピーしない。**brain-kit にも入っていない。

| 場所 | 中身 |
|---|---|
| `~/.orca/agent-hooks/claude-hook.sh` `claude-statusline.sh` `codex-hook.sh` | Claude Code の hooks / statusLine から呼ばれる中継。Orca が書く |
| `~/.orca/sessions/` | セッション状態 |
| `~/.config/orca/orca-devices.json` | ペアリング済みデバイス |
| `~/.config/orca/orca-e2ee-keypair.json` `agent-session-authority.key` | 鍵 |
| `~/.config/orca/orca-runtime.json` `orca-profile-index.json` `orca-stats.json` | runtime / プロファイル / 統計 |
| `~/.config/orca/agent-hooks/endpoint.env` | フックが繋ぐ先 |
| `~/.config/orca/daemon/` | pid・sock・認証ファイル |
| `~/.config/orca/orchestration.db` `profiles/` `logs/` `terminal-history/` | DB・プロファイル・ログ |

**自分で決める・設定するもの**は次の4つだけ:

1. `--pairing-address` に入れる Tailscale IP（systemd ユニットに書く）
2. スマホ／別 PC のペアリング（上の手順）
3. `orca repo add` で登録するリポジトリ
4. automation（スケジュール起動のみ。`--precheck` と `--workspace-mode existing` を使う。skill `dev` §6）

起動時に「OS keyring is unavailable」系の警告（保存する認証情報が平文になる）が出たら、WSL に gnome-keyring を入れる。
