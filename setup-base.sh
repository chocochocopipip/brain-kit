#!/usr/bin/env bash
# setup-base.sh — base（常時稼働の Ubuntu / WSL 機）を組む。冪等。各段で「済み」ならスキップ。
#
#   ./setup-base.sh [--yes] [--dry-run] [--orca-version vX.Y.Z] [--replace-units]
#   ./setup-base.sh --pair mobile      # スマホをペアリング（フォアグラウンドで QR を出す）
#   ./setup-base.sh --pair runtime     # 別 PC の Orca を runtime-environment として繋ぐ
#
# 段:  (a) 前提の確認  (b) 基本ツール  (c) Claude Code CLI  (d) Tailscale
#      (e) Orca (.deb + 不足ライブラリ + Xvfb)  (f) systemd user service で常駐  (g) 接続先の印字
#
# ネットから取るものは、コマンドを表示して確認してから実行する（--yes で無確認）。
# --dry-run は何も実行せず、実行するはずのコマンドだけ印字する。
# 秘密・認証情報・IP はこのファイルに書かない。実行時に tailscale から読む。
# 既に入っているもの（Orca / Tailscale / Claude Code / gh / node / systemd unit）はそのまま使い、無いものだけ足す。
# 既存の unit と内容が違うときは、表示して置き換えるか聞く（--yes では置き換えない。--replace-units で置き換える）。
# テスト用: ORCA_BIN=<path> で Orca の場所を差し替えられる（--dry-run で「あり／なし」を模擬する）。
set -euo pipefail

YES=0; DRY=0; PAIR=""; ORCA_VERSION=""; REPLACE_UNITS=0
NVM_VERSION="v0.40.3"
ORCA_REPO="stablyai/orca"
if [ -z "${ORCA_BIN:-}" ]; then   # 明示されていなければ /opt → PATH の順に探す
  ORCA_BIN="/opt/Orca/orca-ide"
  [ -x "$ORCA_BIN" ] || { p="$(command -v orca-ide 2>/dev/null || true)"; [ -n "$p" ] && ORCA_BIN="$p"; }
fi
ORCA_PORT=6768
DISPLAY_NO=":99"
UNIT_DIR="$HOME/.config/systemd/user"

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)       YES=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    --pair)         PAIR="$2"; shift 2 ;;
    --orca-version) ORCA_VERSION="$2"; shift 2 ;;
    --replace-units) REPLACE_UNITS=1; shift ;;
    -h|--help)      sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
# run <cmd 文字列> : 表示してから eval（--dry-run なら表示のみ）
run() { printf '  $ %s\n' "$*"; [ "$DRY" = 1 ] && return 0; eval "$*"; }
# fetch <説明> <cmd...> : ネット取得。確認してから run
fetch() {
  local what="$1"; shift
  note "取得: $what"
  if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
    printf '  $ %s\n' "$*"
    read -r -p "  実行する？ [y/N] " a; [[ "${a:-}" =~ ^[yY] ]] || { note "skip"; return 1; }
  fi
  run "$*"
}
confirm() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [[ "${a:-}" =~ ^[yY] ]]; }
have()    { command -v "$1" >/dev/null 2>&1; }
SUMMARY=""
mark() { SUMMARY="$SUMMARY$(printf '  %s\t%s\t%s' "$1" "$2" "${3:-}")
"; }   # mark <項目> <あった|足した|手動|skip> [補足]
is_wsl()  { grep -qi microsoft /proc/version 2>/dev/null; }

# ---------------------------------------------------------------- --pair
if [ -n "$PAIR" ]; then
  [ -x "$ORCA_BIN" ] || { echo "error: Orca が入っていない。先に ./setup-base.sh を通す" >&2; exit 1; }
  ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$ip" ] || { echo "error: tailscale ip -4 が空。sudo tailscale up を先に" >&2; exit 1; }
  case "$PAIR" in
    mobile)  flag="--mobile-pairing"; note "スマホの Orca で QR を読む（またはリンクを開く）" ;;
    runtime) flag=""; note "別 PC で: orca environment add --name base --pairing-code '<出力された runtime 用リンク>'" ;;
    *) echo "error: --pair は mobile か runtime" >&2; exit 2 ;;
  esac
  note "ペアリングコードは認証情報。どこにも書き残さない。読み終えたら Ctrl-C で戻す（サービスは自動で再開する）"
  run "systemctl --user stop orca-serve.service || true"
  run "systemctl --user start xvfb.service || true"
  trap 'systemctl --user start orca-serve.service >/dev/null 2>&1 || true' EXIT
  run "DISPLAY=$DISPLAY_NO $ORCA_BIN serve --pairing-address $ip $flag"
  exit 0
fi

# ---------------------------------------------------------------- (a) 前提
say "(a) 前提"
[ "$DRY" = 1 ] && note "--dry-run: 実行せず、コマンドだけ印字する"
os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
os_ver="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}")"
note "OS: ${os_id:-unknown} ${os_ver:-}  WSL: $(is_wsl && echo yes || echo no)  user: $USER"
case "$os_id:$os_ver" in
  ubuntu:22.04|ubuntu:24.04) ;;
  *) note "warn: Ubuntu 22.04 / 24.04 を想定している。ほかでは apt のパッケージ名が違うことがある"
     confirm "  続ける？" || exit 1 ;;
esac
if [ "$DRY" = 1 ]; then
  note "sudo: 未確認（dry-run）"
else
  sudo -v || { echo "error: sudo が使えない" >&2; exit 1; }
  note "sudo: ok"
fi

# ---------------------------------------------------------------- (b) 基本ツール
say "(b) 基本ツール: git curl jq python3 gh node"
missing=""
for t in git curl jq python3 gh; do
  if have "$t"; then note "済み: $t"; mark "$t" あった; else missing="$missing $t"; mark "$t" 足した apt; fi
done
if [ -n "$missing" ]; then
  fetch "apt:$missing" "sudo apt-get update -qq && sudo apt-get install -y$missing" || true
fi
if have node; then
  note "済み: node $(node --version 2>/dev/null)"; mark node あった "$(node --version 2>/dev/null)"
else
  note "node が無い。nvm で LTS を入れる（apt の node は古い）"
  if fetch "nvm $NVM_VERSION" "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"; then
    run 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm install --lts && nvm alias default lts/*'
    mark node 足した nvm
  else mark node 手動 "nvm を入れる"; fi
fi

# ---------------------------------------------------------------- (c) Claude Code
say "(c) Claude Code CLI"
if have claude; then
  note "済み: claude $(claude --version 2>/dev/null | head -1)"; mark claude あった "$(claude --version 2>/dev/null | head -1)"
else
  fetch "Claude Code（公式インストーラ）" "curl -fsSL https://claude.ai/install.sh | bash" && mark claude 足した || mark claude 手動 "公式インストーラ"
  note "入ったら一度 'claude' を起動してログインする（ブラウザ認証）"
fi

# ---------------------------------------------------------------- (d) Tailscale
say "(d) Tailscale"
if have tailscale; then
  note "済み: tailscale $(tailscale version 2>/dev/null | head -1)"; mark tailscale あった "$(tailscale version 2>/dev/null | head -1)"
else
  fetch "Tailscale（公式インストーラ）" "curl -fsSL https://tailscale.com/install.sh | sh" && mark tailscale 足した || mark tailscale 手動 "公式インストーラ"
fi
if [ "$DRY" != 1 ] && have tailscale && tailscale status >/dev/null 2>&1; then
  note "済み: tailnet に参加している"
else
  note "次を手で実行する（ブラウザ認証が要るので自動化しない）:"
  note "  sudo tailscale up"
fi
if [ "$DRY" != 1 ] && have tailscale; then
  echo; tailscale status 2>/dev/null || true; echo
  note "上の一覧に、繋ぎたい端末（手元 PC・スマホ）が居ること。居なければその端末に Tailscale を入れて同じアカウントでログインする"
  confirm "  居る（または後で入れる）？" || exit 1
fi

# ---------------------------------------------------------------- (e) Orca
say "(e) Orca"
if [ -x "$ORCA_BIN" ]; then
  orca_ver="$(dpkg-query -W -f='${Version}' orca-ide 2>/dev/null || "$ORCA_BIN" --version 2>/dev/null | head -1 || true)"
  note "済み: $ORCA_BIN ${orca_ver:+(v$orca_ver)}  ダウンロードと apt は飛ばす"
  mark orca あった "${orca_ver:-$ORCA_BIN}"
else
  if [ -z "$ORCA_VERSION" ]; then
    if [ "$DRY" = 1 ]; then
      ORCA_VERSION="<latest>"
    elif have gh; then
      ORCA_VERSION="$(gh release view --repo "$ORCA_REPO" --json tagName -q .tagName 2>/dev/null || true)"
    fi
    if [ -z "$ORCA_VERSION" ] && have curl && have jq; then
      ORCA_VERSION="$(curl -fsSL "https://api.github.com/repos/$ORCA_REPO/releases/latest" | jq -r .tag_name 2>/dev/null || true)"
    fi
  fi
  [ -n "$ORCA_VERSION" ] || { echo "error: Orca の最新バージョンが取れない。--orca-version vX.Y.Z で指定" >&2; exit 1; }
  ver="${ORCA_VERSION#v}"
  deb="orca-ide_${ver}_amd64.deb"
  url="https://github.com/$ORCA_REPO/releases/download/$ORCA_VERSION/$deb"
  run "mkdir -p \"\$HOME/opt\""
  if [ -f "$HOME/opt/$deb" ]; then
    note "済み: $HOME/opt/$deb"
  else
    fetch "Orca $ORCA_VERSION (.deb)" "curl -fsSL -o \"\$HOME/opt/$deb\" \"$url\"" || exit 1
  fi
  run "sudo apt-get install -y \"\$HOME/opt/$deb\""
  mark orca 足した "$ORCA_VERSION"
fi

note "不足ライブラリの実測（.deb は依存関係を宣言していない）"
if [ "$DRY" = 1 ] && [ ! -x "$ORCA_BIN" ]; then
  note "\$ ldd $ORCA_BIN | grep 'not found'   → 出たものを apt で入れる"
else
  for _pass in 1 2; do
    missing_libs="$(ldd "$ORCA_BIN" 2>/dev/null | grep 'not found' | sed 's/^[[:space:]]*//; s/[[:space:]].*//' || true)"
    [ -n "$missing_libs" ] || { note "済み: 不足なし"; break; }
    pkgs=""; unknown=""
    for lib in $missing_libs; do
      case "$lib" in
        libnss3.so|libnssutil3.so|libsmime3.so) pkgs="$pkgs libnss3" ;;
        libnspr4.so)     pkgs="$pkgs libnspr4" ;;
        libasound.so.2)  [ "$os_ver" = "22.04" ] && pkgs="$pkgs libasound2" || pkgs="$pkgs libasound2t64" ;;
        libgbm.so.1)     pkgs="$pkgs libgbm1" ;;
        libgtk-3.so.0)   pkgs="$pkgs libgtk-3-0" ;;
        libxss.so.1)     pkgs="$pkgs libxss1" ;;
        libatk-bridge-2.0.so.0) pkgs="$pkgs libatk-bridge2.0-0" ;;
        libcups.so.2)    pkgs="$pkgs libcups2" ;;
        libdrm.so.2)     pkgs="$pkgs libdrm2" ;;
        libxkbcommon.so.0) pkgs="$pkgs libxkbcommon0" ;;
        libxcomposite.so.1) pkgs="$pkgs libxcomposite1" ;;
        libxdamage.so.1) pkgs="$pkgs libxdamage1" ;;
        libxrandr.so.2)  pkgs="$pkgs libxrandr2" ;;
        libpango-1.0.so.0) pkgs="$pkgs libpango-1.0-0" ;;
        libcairo.so.2)   pkgs="$pkgs libcairo2" ;;
        *) unknown="$unknown $lib" ;;
      esac
    done
    pkgs="$(printf '%s\n' $pkgs | sort -u | tr '\n' ' ')"
    [ -n "$pkgs" ] && run "sudo apt-get install -y $pkgs"
    [ -n "$unknown" ] && note "warn: 対応パッケージ不明:$unknown  → apt-file search <lib名> で探して入れる"
    [ "$DRY" = 1 ] && break
  done
fi

if have Xvfb; then note "済み: Xvfb"; mark xvfb あった; else run "sudo apt-get install -y xvfb"; mark xvfb 足した apt; fi

# ---------------------------------------------------------------- (f) systemd
say "(f) 常駐（systemd user service）"
systemd_ok=0
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && systemctl --user is-system-running >/dev/null 2>&1; then systemd_ok=1; fi
if [ "$systemd_ok" != 1 ] && [ "$DRY" != 1 ]; then
  note "systemd が動いていない。"
  if is_wsl; then
    note "WSL なら /etc/wsl.conf に次を書き、PowerShell で 'wsl --shutdown' してから開き直す:"
    note "  [boot]"
    note "  systemd=true"
  fi
  note "動いたら ./setup-base.sh をもう一度。ここから先はスキップ"
else
  ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$ip" ] || { ip="<TailscaleのIP>"; note "warn: tailscale ip -4 が空。sudo tailscale up の後にもう一度実行すると IP が入る"; }
  run "mkdir -p \"$UNIT_DIR\""
  xvfb_unit="[Unit]
Description=Xvfb on $DISPLAY_NO (Orca 用。WSLg/weston に依存しないため)
After=default.target
[Service]
Type=simple
ExecStart=/usr/bin/Xvfb $DISPLAY_NO -screen 0 1280x800x24 -nolisten tcp
Restart=always
RestartSec=2
[Install]
WantedBy=default.target"
  orca_unit="[Unit]
Description=Orca headless runtime server
Requires=xvfb.service
After=xvfb.service default.target
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Type=simple
Environment=DISPLAY=$DISPLAY_NO
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=$ORCA_BIN serve --pairing-address $ip --mobile-pairing
StandardOutput=null
StandardError=journal
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5
[Install]
WantedBy=default.target"
  write_unit() { # write_unit <path> <content>   無ければ作る。あって違えば表示して置き換えるか聞く
    local name; name="$(basename "$1")"
    if [ -f "$1" ]; then
      if [ "$(cat "$1")" = "$2" ]; then note "済み: $1"; mark "$name" あった 同一; return 0; fi
      note "既存の $1 と内容が違う。現在の中身:"
      sed 's/^/      | /' "$1"
      note "置き換え候補との差分:"
      diff <(cat "$1") <(printf '%s\n' "$2") | sed 's/^/      /' || true
      if [ "$REPLACE_UNITS" = 1 ]; then :
      elif [ "$YES" = 1 ] || [ "$DRY" = 1 ]; then note "既存を残す（置き換えるなら --replace-units）"; mark "$name" あった "既存を維持"; return 0
      elif ! confirm "  置き換える？（既存は $1.bak に退避）"; then mark "$name" あった "既存を維持"; return 0
      fi
      run "cp -a \"$1\" \"$1.bak\""
      mark "$name" 足した "置き換え（.bak あり）"
    else
      mark "$name" 足した
    fi
    note "書く: $1"
    [ "$DRY" = 1 ] && return 0
    printf '%s\n' "$2" > "$1"
  }
  write_unit "$UNIT_DIR/xvfb.service" "$xvfb_unit"
  write_unit "$UNIT_DIR/orca-serve.service" "$orca_unit"
  run "systemctl --user daemon-reload"
  run "systemctl --user enable --now xvfb.service orca-serve.service"
  if [ "$DRY" != 1 ] && loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    note "済み: linger"; mark linger あった
  else
    run "sudo loginctl enable-linger \"$USER\""; mark linger 足した
  fi
  [ "$DRY" = 1 ] || { sleep 3; systemctl --user --no-pager status orca-serve.service 2>/dev/null | head -5 || true; }
fi

# ---------------------------------------------------------------- (g) 接続先
say "(g) 接続先"
ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
dns="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
note "Tailscale IP : ${ip:-（未接続。sudo tailscale up の後に確認）}"
note "MagicDNS     : ${dns:-（未取得）}"
note "Orca serve   : ws://${ip:-<IP>}:$ORCA_PORT"
note "確認         : ss -lntp | grep $ORCA_PORT   （LISTEN が出ること）"
cat <<MSG

繋ぎ方（ORCA.md と同じ）:
  スマホ  : ./setup-base.sh --pair mobile   → 出た QR を Orca モバイルで読む
  別 PC   : ./setup-base.sh --pair runtime  → 出たリンクを orca environment add --name base --pairing-code '<リンク>' に渡す
            以後 orca <cmd> --environment base で母艦を操作できる
  ペアリングはデバイスに紐づく。サービスを再起動しても再ペアリングは要らない。
  ペアリングコードは認証情報。brain にも他所にも書かない。

brain と Claude Code はこの機で動く。cd ~/brain && claude で /setup から。
MSG

say "何があって、何を足したか"
if command -v python3 >/dev/null 2>&1; then
  { printf '  項目\t状態\t補足\n'; printf '%s' "$SUMMARY"; } | python3 -c '
import sys, unicodedata
rows=[l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
w=lambda s: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
n=max(len(r) for r in rows); rows=[r+[""]*(n-len(r)) for r in rows]
cw=[max(w(r[i]) for r in rows) for i in range(n)]
for r in rows: print("  ".join(r[i]+" "*(cw[i]-w(r[i])) for i in range(n)).rstrip())'
else
  { printf '  項目\t状態\t補足\n'; printf '%s' "$SUMMARY"; }
fi
[ "$DRY" = 1 ] && note "（dry-run: 「足した」は実行していない。実行するはずだったもの）"
exit 0
