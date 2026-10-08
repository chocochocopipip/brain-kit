#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""brain-kit の本体。install.sh から呼ぶ（直接呼んでもよい）。Python 3.8 以上、標準ライブラリだけ。

  kit.py install  [名前などの引数]      新しく入れる
  kit.py update   [--dry-run] [...]    kit のものだけを新しい版に上げる（持ち主のものには触らない）
  kit.py resolve  --target <file>     確認した解消結果を退避して記録する
  kit.py uninstall [--dry-run] [--yes]  この機の kit だけを外す
  kit.py rollback                      直前の更新（か install）を戻す
  kit.py doctor                        何も変えずに状態を表で出す

持ち主のもの（核・辞書・関係・日誌・決定・知識・プロジェクト・記録・規準・手順）には、どの経路でも書かない。
kit のもの（kitfiles.tsv の一覧）だけを、退避してから上げる。更新では両方が変わったファイルを衝突として残す。
"""
from __future__ import print_function

import argparse
import datetime
import difflib
import errno
import hashlib
import io
import importlib.util
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
KIT_STATE = os.path.join(CLAUDE, "brain-kit")            # この機の kit の状態（manifest・起動スクリプトなど）
CLAUDE_MANIFEST = os.path.join(KIT_STATE, "manifest.json")


def read_version():
    try:
        return int(io.open(os.path.join(KIT, "VERSION"), encoding="utf-8").read().strip())
    except Exception:
        return 0


LANG_NAMES = {"ja": "日本語", "en": "English"}
_LANG = "ja"
_CATALOG = None


def set_lang(code):
    global _LANG
    _LANG = code if code in LANG_NAMES else "ja"


def M(msgid, lang=None):
    """表示文の翻訳。lang を渡すと、表示の言語ではなくその言語で返す（brain に書く中身は cfg の言語で作る）。"""
    global _CATALOG
    if (lang or _LANG) == "ja":
        return msgid
    if _CATALOG is None:
        _CATALOG = load_json(os.path.join(KIT, "i18n", "en", "messages.json"), {}) or {}
    return _CATALOG.get(msgid, msgid)


def record_lang(*records):
    """記録から持ち主の言語を読む。前の記録が使えなければ次へ、どれも無ければ日本語（言語を選べる前の入れ方）。
    dict でない記録や ja/en 以外の値は読み飛ばす（壊れた記録で rollback などを止めない）。"""
    for record in records:
        value = record.get("lang") if isinstance(record, dict) else None
        if isinstance(value, str) and value in LANG_NAMES:
            return value
    return "ja"


def content_lang(cfg):
    """brain に書く中身の言語（表示の --lang とは別）。"""
    return record_lang(cfg)


def language_name(code):
    # The stored template mark is the native name; owner-facing output is translated.
    return M(LANG_NAMES.get(code, LANG_NAMES["ja"]))


VERSION = read_version()
# この kit の動作を確かめた Claude Code の版。上げるときは CHANGELOG にも記す（CHECKLIST.md）。
VERIFIED_CLAUDE_CODE = "2.1.294"

ROLES = ["partner", "dev", "review", "release"]
ROLE_JA = {"partner": "相棒", "dev": "開発", "review": "レビュー", "release": "リリース"}
DEFAULT_ID = {"partner": "partner", "dev": "dev", "review": "review", "release": "release"}
NAME_MARK = {"partner": "<相棒名>", "dev": "<開発担当名>", "review": "<レビュー担当名>", "release": "<リリース担当名>"}
ID_MARK = {"partner": "<相棒id>", "dev": "<開発id>", "review": "<レビューid>", "release": "<リリースid>"}
LABEL_MARK = {"dev": "<開発ラベル>", "review": "<レビューラベル>", "release": "<リリースラベル>"}
AREA = {"dev": "dev", "review": "review", "release": "release"}   # partner の領域は <相棒名>/
WORKTREE_ROLES = ["dev", "review", "release"]                      # 相棒は brain（main）そのもので動く
COMMON_LABELS = ["from-chat", "needs-triage", "agent-ready", "agent-working", "question"]
RESERVED_DIRS = {"dev", "review", "release", "daily", "projects", "decisions", "knowledge", "archive",
                 "inbox.md", "README.md", "CLAUDE.md"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")

STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
TODAY = datetime.date.today().isoformat()


# ------------------------------------------------------------------ 小道具
def say(msg):
    if sys.stdout.isatty():
        print("\033[1m%s\033[0m" % msg)
    else:
        print(msg)


def die(msg, code=1):
    print("error: " + msg, file=sys.stderr)
    sys.exit(code)


def sha(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def read_text(path):
    try:
        with io.open(path, encoding="utf-8", newline="") as f:
            return f.read()
    except (IOError, OSError, UnicodeDecodeError):
        return None


def write_text(path, text, exe=False):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if exe:
        os.chmod(path, 0o755)


def load_json(path, default=None):
    t = read_text(path)
    if t is None:
        return default
    try:
        return json.loads(t)
    except ValueError:
        return default


def dump_json(obj):
    return json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def tilde(path):
    return "~" + path[len(HOME):] if path == HOME or path.startswith(HOME + os.sep) else path


def interactive(args=None):
    if args is not None and getattr(args, "yes", False):
        return False
    return os.environ.get("BRAIN_KIT_INTERACTIVE") == "1" or sys.stdin.isatty()


def ask(q, default="", args=None):
    if not interactive(args):
        return default
    try:
        sys.stdout.write("%s%s: " % (q, " [%s]" % default if default else ""))
        sys.stdout.flush()
        a = sys.stdin.readline()
    except (EOFError, KeyboardInterrupt):
        print()
        die(M("中断した"), 130)
    if a == "":
        return default
    a = a.strip()
    return a or default


def run(cmd, cwd=None, inp=None, timeout=60):
    try:
        r = subprocess.run(cmd, cwd=cwd, input=inp, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:  # noqa: BLE001  コマンドが無い・時間切れ
        return 127, "", str(e)


def have(cmd):
    return shutil.which(cmd) is not None


def claude_version_warning(missing=False, result=None):
    """版の注意を最大 1 行で返す。確認できなくても処理は続ける。"""
    if result is None:
        if not have("claude"):
            return M("warn: Claude Code CLI（claude）が無い。版を確かめられない（このまま続ける）") if missing else None
        result = run(["claude", "--version"], timeout=15)
    rc, out, err = result
    match = re.match(r"\s*(\d+\.\d+\.\d+)", out)
    if rc != 0 or not match:
        lines = (out or err).splitlines()
        detail = lines[0][:60] if lines else M("終了コード %s、出力なし") % rc
        return M("warn: Claude Code の版を読めない（claude --version: %s）。このまま続ける") % detail
    version = match.group(1)
    if tuple(map(int, version.split("."))) < tuple(map(int, VERIFIED_CLAUDE_CODE.split("."))):
        return (M("warn: Claude Code %s は動作を確かめた版（%s）より古い。"
                "claude update で上げられる（このまま続ける）") % (version, VERIFIED_CLAUDE_CODE))
    return None


def split_csv(s):
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def valid_name(n):
    return bool(n) and not re.search(r"[/\s<>]", n) and not n.startswith(".")


def to_id(name):
    """名前が英数字だけなら、それを小文字にして id に使う。日本語などは None（id を別に聞く）。"""
    low = (name or "").lower()
    return low if ID_RE.match(low) else None


# ------------------------------------------------------------------ 設定（brain に置く版と名前の記録）
def brain_state_dir(brain):
    return os.path.join(brain, ".brain-kit")


def config_path(brain):
    return os.path.join(brain_state_dir(brain), "config.json")


def brain_manifest_path(brain):
    return os.path.join(brain_state_dir(brain), "manifest.json")


def persona(cfg, role):
    return cfg["personas"][role]


def label_of(cfg, role):
    p = persona(cfg, role)
    return p.get("label") or p["id"]


def worktree_of(cfg, role):
    if role == "partner":
        return cfg["brain"]
    return cfg["brain"] + "-" + persona(cfg, role)["id"]


def area_of(cfg, role):
    return persona(cfg, "partner")["name"] if role == "partner" else AREA[role]


def marks(cfg):
    lang = content_lang(cfg)
    t = {"<持ち主名>": cfg.get("owner") or M("持ち主", lang), "<brain>": tilde(cfg["brain"])}
    t["<持ち主の言語>"] = LANG_NAMES[lang]
    for r in ROLES:
        p = cfg["personas"].get(r)
        if not p:
            continue
        t[NAME_MARK[r]] = p["name"]
        t[ID_MARK[r]] = p["id"]
        if r in LABEL_MARK:
            t[LABEL_MARK[r]] = label_of(cfg, r)
    return t


def render(text, cfg, flags):
    if "render" in flags:
        for k, v in marks(cfg).items():
            text = text.replace(k, v)
    for f in flags:
        if f.startswith("skill:"):
            role = f.split(":", 1)[1]
            text = re.sub(r"^name: .*$", "name: " + persona(cfg, role)["id"], text, count=1, flags=re.M)
    return text


# ------------------------------------------------------------------ kit のファイルの一覧
def load_kitfiles(cfg):
    rows = []
    for line in io.open(os.path.join(KIT, "kitfiles.tsv"), encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        src, dst = parts[0], parts[1]
        flags = [f for f in (parts[2] if len(parts) > 2 else "").split(",") if f]
        # まだ名前の決まっていない役のファイルは飛ばす（v10 より前の設定を読むときなど）
        roles = re.findall(r"\{(\w+)\.(?:id|name)\}", dst) + [f.split(":")[1] for f in flags if f.startswith("skill:")]
        if src.startswith("gen:start:"):
            roles.append(src.split(":")[2])
        if any(r not in cfg["personas"] for r in roles):
            continue
        rows.append((src, expand_dst(dst, cfg), flags))
    return rows


def expand_dst(dst, cfg):
    if dst.startswith("~/"):
        dst = os.path.join(HOME, dst[2:])
    dst = dst.replace("{brain}", cfg["brain"])

    def sub(m):
        return persona(cfg, m.group(1))[m.group(2)]
    return re.sub(r"\{(\w+)\.(id|name)\}", sub, dst)


def kit_srcs():
    out = set()
    for line in io.open(os.path.join(KIT, "kitfiles.tsv"), encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            out.add(line.split("\t")[0])
    return out


def owner_files(cfg):
    """brain-template/ のうち kit のものではないファイル（持ち主のもの）。無ければ足すだけ。"""
    srcroot = os.path.join(KIT, "brain-template")
    kits = kit_srcs()
    rows = []
    for root, dirs, files in os.walk(srcroot):
        dirs.sort()
        rel = os.path.relpath(root, srcroot)
        parts = [] if rel == "." else rel.split(os.sep)
        role_dir = parts[0] if parts else None
        if role_dir in ("review", "release") and role_dir not in cfg["personas"]:
            continue
        out_parts = list(parts)
        if out_parts and out_parts[0] == "partner":
            out_parts[0] = persona(cfg, "partner")["name"]
        for name in sorted(files):
            src_rel = "/".join(["brain-template"] + parts + [name])
            if src_rel in kits:
                continue
            flags = ["render"] if name.endswith(".md") else []
            # npm は .gitignore という名前をパッケージに入れないので、点なしで持って書くときに戻す
            out_name = ".gitignore" if not parts and name == "gitignore" else name
            rows.append((src_rel, os.path.join(cfg["brain"], *(out_parts + [out_name])), flags))
    return rows


def source_path(src, cfg):
    lang = content_lang(cfg)
    if lang in LANG_NAMES and lang != "ja":
        translated = os.path.join(KIT, "i18n", lang, src)
        if os.path.isfile(translated):
            return translated
    return os.path.join(KIT, src)


def source_text(src, cfg, flags):
    if src == "gen:start-all":
        return gen_start_all(cfg)
    if src.startswith("gen:start:"):
        return gen_start(src.split(":")[2], cfg)
    return render(io.open(source_path(src, cfg), encoding="utf-8").read(), cfg, flags)


def gen_start_all(cfg):
    def path_expr(path):
        # HOME 配下は実行時の HOME を使い、残りは shell の単引用で守る。
        home = os.path.abspath(HOME)
        if os.path.commonpath([os.path.abspath(path), home]) == home:
            return '"$HOME"/' + shlex.quote(os.path.relpath(path, home))
        return shlex.quote(path)

    lines = []
    for role in ROLES:
        if role not in cfg["personas"]:
            continue
        p = persona(cfg, role)
        lines.extend([
            "ids+=(%s)" % shlex.quote(p["id"]),
            "names+=(%s)" % shlex.quote(p["name"]),
            "labels+=(%s)" % shlex.quote(M(ROLE_JA[role], content_lang(cfg))),
            "dir=%s" % path_expr(worktree_of(cfg, role)),
            '[ -d "$dir" ] || dir=%s' % path_expr(cfg["brain"]),
            'dirs+=("$dir")',
            'scripts+=("$HOME"/%s)' % shlex.quote(".claude/brain-kit/bin/start-" + p["id"]),
        ])
    template = read_text(source_path("lib/start-all.sh", cfg))
    return template.replace("# @personas@", "\n".join(lines))


def gen_start(role, cfg):
    p = persona(cfg, role)
    lang = content_lang(cfg)   # 中身は brain の言語（--lang で表示だけ変えても同じバイト）
    wt = worktree_of(cfg, role)
    lines = [
        "#!/usr/bin/env bash",
        M("# %s（%s）を起動する。brain-kit が作った（--update で上がる。手で直すなら別名で写す）", lang) % (p["name"], M(ROLE_JA[role], lang)),
        M("#   start-%s [claude に渡す引数...]", lang) % p["id"],
        "set -u",
        'dir="%s"' % wt,
        '[ -d "$dir" ] || dir="%s"' % cfg["brain"],
        'cd "$dir" || exit 1',
    ]
    if role != "partner":
        lines.append(M("# main の決定・規約を取り込んでから始める（衝突したら何もしない）", lang))
        lines.append('git merge -q --no-edit main >/dev/null 2>&1 || git merge --abort >/dev/null 2>&1')
    # worktree が無く brain で始まるときも、要約のあとのフックが自分の人格の核を読むように役を渡す
    lines.append("export BRAIN_KIT_PERSONA=%s" % role)
    lines.append('exec claude "$@" "/%s"' % p["id"])
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------ 古い入れ方（v1〜v9）の判定
def load_fingerprints():
    return load_json(os.path.join(KIT, "migrations", "fingerprints.json"), {}) or {}


def _h(line):
    return hashlib.sha256(line.encode("utf-8")).hexdigest()[:16]


def fingerprint_versions(src, text, legacy_marks, fps):
    """text が src の古い版のどれかと（名前を除いて）一致すれば、その版の番号の一覧を返す。"""
    cands = fps.get(src) or []
    lines = text.split("\n")
    hit = []
    for fp in cands:
        if len(fp["lines"]) != len(lines):
            continue
        toks = [t for t in fp["marks"] if legacy_marks.get(t)]
        # 名前 → 印 に戻す組み合わせ（2^n 通り、n <= 3）。持ち主名が「持ち主」でも崩れないように全部試す
        combos = [[]]
        for t in toks:
            combos = combos + [c + [t] for c in combos]
        ok = True
        for i, line in enumerate(lines):
            if src.startswith("claude/skills/") and line.startswith("name: "):
                line = "name: *"
            want = fp["lines"][i]
            if _h(line) == want:
                continue
            found = False
            for c in combos[1:]:
                l2 = line
                for t in sorted(c, key=lambda k: -len(legacy_marks[k])):
                    l2 = l2.replace(legacy_marks[t], t)
                if _h(l2) == want:
                    found = True
                    break
            if not found:
                ok = False
                break
        if ok:
            hit.extend(fp["versions"])
    return sorted(set(hit))


def detect_legacy(brain):
    """版の記録が無い brain（v1〜v9）から、相棒・開発の名前と版を読み取る。見つからなければ None。"""
    if not os.path.isdir(brain):
        return None
    partners = []
    for d in sorted(os.listdir(brain)):
        if d.startswith(".") or d in RESERVED_DIRS:
            continue
        if os.path.isfile(os.path.join(brain, d, "00_核.md")):
            partners.append(d)
    has_dev = os.path.isdir(os.path.join(brain, "dev"))
    if not partners and not has_dev:
        return None
    info = {"partner": partners[0] if len(partners) == 1 else None, "partners": partners}
    # skill を探す（v1〜v9 は skill のディレクトリ名 = 名前）
    sdir = os.path.join(CLAUDE, "skills")
    pskill = dskill = None
    if os.path.isdir(sdir):
        for d in sorted(os.listdir(sdir)):
            t = read_text(os.path.join(sdir, d, "SKILL.md"))
            if t is None or d in ("setup", "grilling"):
                continue
            if "憲法は `~/brain/" in t and pskill is None:
                pskill = d
            elif "状況カード" in t and "~/brain/dev/" in t and dskill is None:
                dskill = d
    if info["partner"] is None and pskill and pskill in partners:
        info["partner"] = pskill
    info["partner_skill"] = pskill
    info["dev"] = dskill
    core = read_text(os.path.join(brain, info["partner"] or "", "00_核.md")) if info["partner"] else None
    m = re.search(r"^持ち主: *(.+)$", core or "", re.M)
    info["owner"] = m.group(1).strip() if m else "持ち主"
    # 開発担当の名前は dev/00_核.md の見出しにも入っている
    dcore = read_text(os.path.join(brain, "dev", "00_核.md")) or ""
    m = re.search(r"^# (.+)$", dcore, re.M)
    info["dev_title"] = m.group(1).strip() if m else None
    # リポジトリは状況カードから
    repos = []
    cards = os.path.join(brain, "dev", "状況")
    if os.path.isdir(cards):
        for f in sorted(os.listdir(cards)):
            t = read_text(os.path.join(cards, f)) or ""
            m = re.search(r"^リポジトリ: `([^`/]+/[^`]+)`", t, re.M)
            if m:
                repos.append(m.group(1))
    info["repos"] = repos
    return info


def legacy_version(cfg, fps):
    """kit のファイルの指紋から版を推す。(版の一覧, 説明) を返す。"""
    lt = legacy_marks(cfg)
    votes = None
    for src, dst, flags in load_kitfiles(cfg):
        if src not in ("claude/skills/partner/SKILL.md", "claude/skills/dev/SKILL.md", "claude/skills/setup/SKILL.md"):
            continue
        t = read_text(dst)
        if t is None:
            continue
        vs = set(fingerprint_versions(src, t, lt, fps))
        if not vs:
            continue
        votes = vs if votes is None else (votes & vs or votes)
    if not votes:
        return None, M("v9 以前（版の記録なし。kit の skill が手で直してあり、版を絞れない）")
    lo, hi = min(votes), max(votes)
    return hi, ("v%d" % hi if lo == hi else M("v%d〜v%d") % (lo, hi)) + M("（版の記録なし。ファイルの形から判定）")


def legacy_marks(cfg):
    return {"<相棒名>": persona(cfg, "partner")["name"], "<開発担当名>": persona(cfg, "dev")["name"],
            "<持ち主名>": cfg.get("owner") or "持ち主"}


# ------------------------------------------------------------------ 名前を決める
def id_taken_by_other(pid, cfg_manifest):
    """~/.claude/skills/<id> が kit のもの以外で既に使われているか。"""
    p = os.path.join(CLAUDE, "skills", pid)
    return os.path.isdir(p) and bool(os.listdir(p)) and not claude_dir_owned("skills", pid, cfg_manifest)


def claude_dir_owned(part, name, manifest):
    prefix = ".claude/%s/%s/" % (part, name)
    return any(key.startswith(prefix) for key in manifest.get("files", {}))


def choose_persona(role, args, used_ids, cmanifest, fixed=None):
    """役の名前と id を決める。引数 > 対話 > 既定（役の名前）の順。"""
    if fixed:
        return fixed
    name = getattr(args, role) or ""
    if not name:
        name = ask(M("  %sの名前（呼び名。日本語でよい）") % M(ROLE_JA[role]), M(ROLE_JA[role]), args)
    if not valid_name(name):
        die(M("%sの名前が空か、使えない文字（/ 空白 < >）を含む: %r") % (M(ROLE_JA[role]), name), 2)
    if role == "partner" and name in RESERVED_DIRS:
        die(M("相棒の名前 %s は brain のディレクトリ名と重なる。別の名前にする") % name, 2)
    pid = getattr(args, role + "_id") or to_id(name)
    if not pid:
        pid = ask(M("  %s の英字 id（skill 名・ブランチ・ラベル・起動スクリプトに使う。小文字・数字・-）") % name,
                  DEFAULT_ID[role], args)
    pid = pid.lower()
    if not ID_RE.match(pid):
        die(M("%s の id %r が使えない（小文字・数字・- で 40 字まで）。--%s-id で渡す") % (name, pid, role), 2)
    while pid in used_ids or pid in ("setup", "grilling") or id_taken_by_other(pid, cmanifest):
        why = M("ほかの役と重なる") if pid in used_ids or pid in ("setup", "grilling") else \
            M("~/.claude/skills/%s が kit の外で既にある") % pid
        if not interactive(args):
            die(M("%s の id %r は %s。--%s-id <別の id> で渡す") % (name, pid, why, role), 2)
        pid = ask(M("  id %s は%s。別の id") % (pid, why), pid + "-2", args).lower()
        if not ID_RE.match(pid):
            die(M("id %r が使えない") % pid, 2)
    used_ids.add(pid)
    p = {"name": name, "id": pid}
    if role != "partner":
        p["label"] = pid
    return p


# ------------------------------------------------------------------ settings.json
def settings_sha(value):
    return sha(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")))


def settings_entries(obj):
    """kit の項目を、イベントと command／キーで識別する。"""
    entries = {}
    for event, groups in obj.get("hooks", {}).items():
        for group in groups:
            entries[("hooks." + event, group["hooks"][0]["command"])] = group
    if "statusLine" in obj:
        entries[("statusLine", "")] = obj["statusLine"]
    for part in ("enabledPlugins", "extraKnownMarketplaces"):
        for key, value in obj.get(part, {}).items():
            entries[(part, key)] = value
    return entries


def settings_get(obj, entry):
    """settings の JSON から kit の項目（イベントと command／キー）の値を取る。無ければ None。"""
    part, key = entry
    if part.startswith("hooks."):
        return next((g for g in obj.get("hooks", {}).get(part[6:], [])
                     if any(h.get("command") == key for h in g.get("hooks", []))), None)
    if part == "statusLine":
        return obj.get(part)
    return obj.get(part, {}).get(key)


def settings_name(entry):
    part, key = entry
    return part + (": " + key[:60] if part.startswith("hooks.") else "." + key if key else "")


def plan_settings(codex=False, manifest=None, text=None):
    path = os.path.join(CLAUDE, "settings.json")
    raw = read_text(path) if text is None else text
    cur = {}
    if raw is not None:
        try:
            cur = json.loads(raw)
        except ValueError as e:
            die(M("%s が JSON として読めない: %s") % (path, e))
        if not isinstance(cur, dict):
            die(M("settings.json は JSON オブジェクトにする"), 2)
    manifest = manifest or {}
    record = {}
    for part, values in manifest.get("settings", {}).items():
        if part == "statusLine":
            record[(part, "")] = values
        else:
            for key, value in values.items():
                record[(part, key)] = value
    absent = object()

    def current(entry):
        part, key = entry
        if part.startswith("hooks."):
            for group in cur.get("hooks", {}).get(part[6:], []):
                if any(h.get("command") == key for h in group.get("hooks", [])):
                    return group
            return absent
        if part == "statusLine":
            return cur.get(part, absent)
        return cur.get(part, {}).get(key, absent)

    snip = load_json(os.path.join(KIT, "claude/settings.snippet.json"))
    theirs = settings_entries(snip)
    extra = settings_entries(load_json(os.path.join(KIT, "claude/settings.codex.json")))
    # 前の更新で衝突になり、まだ --resolve していない項目。kit の値と一致するまで、足す・上げる・外すをしない
    pending = {tuple(e) for e in manifest.get("settings_conflicts", [])}
    if codex or any(e in record or e in pending for e in extra) or (
            "settings" not in manifest and any(current(e) is not absent for e in extra)):
        theirs.update(extra)
    plan = {"path": path, "raw": raw, "record": {}, "add": [], "update": [],
            "remove": [], "keep": [], "conflict": [], "theirs": theirs}
    owned = dict(record)

    def change(entry, value, old):
        part, key = entry
        if part.startswith("hooks."):
            event = part[6:]
            groups = cur.setdefault("hooks", {}).setdefault(event, [])
            if old is absent:
                groups.append(value)
            else:
                index = next(i for i, g in enumerate(groups) if g is old)
                if value is absent:
                    groups.pop(index)
                    if not groups:
                        del cur["hooks"][event]
                    if not cur["hooks"]:
                        del cur["hooks"]
                else:
                    groups[index] = value
        else:
            dst = cur if part == "statusLine" else cur.setdefault(part, {})
            key = part if part == "statusLine" else key
            if value is absent:
                del dst[key]
            else:
                dst[key] = value

    def conflict(entry, old, rec, new, reason=None):
        reason = reason or M("両方が変えた")
        plan["conflict"].append({"entry": entry, "name": settings_name(entry), "reason": reason,
                                 "ours": None if old is absent else old, "recorded": rec,
                                 "theirs": None if new is absent else new})

    # 同じイベントで消えた command と増えた command が 1 つずつなら、command の変更として対応付ける。
    # 複数あると対応が決まらないので、どれも触らずに衝突として出す（古い記録は残し、新しいものは足さない）。
    paired = set()
    # 解消待ちの未登録のフック（持ち主が消したもの・変えたもの）も、command の変更の元として数える
    known = list(record) + [e for e in sorted(pending) if e not in record]
    for part in dict.fromkeys(e[0] for e in known if e[0].startswith("hooks.")):
        removed = [e for e in known if e[0] == part and e not in theirs]
        added = [e for e in theirs if e[0] == part and e not in record and current(e) is absent]
        if not removed or not added:
            continue
        if len(removed) > 1 or len(added) > 1:
            paired.update(removed + added)
            for e in removed:
                conflict(e, current(e), record.get(e), absent, M("command の変更が複数あり対応が決まらない"))
            for e in added:
                conflict(e, absent, None, theirs[e], M("command の変更が複数あり対応が決まらない"))
            continue
        for old_entry, new_entry in zip(removed, added):
            paired.update((old_entry, new_entry))
            old, new, rec = current(old_entry), theirs[new_entry], record.get(old_entry)
            if old is not absent and rec is not None and settings_sha(old) == rec and \
                    old_entry not in pending and new_entry not in pending:
                change(old_entry, new, old)
                owned.pop(old_entry, None)
                owned[new_entry] = settings_sha(new)
                plan["update"].append(settings_name(new_entry))
            else:
                # 古い記録は残す（消すと次の更新で新しい command を未登録として足してしまう）。
                conflict(old_entry, old, rec, new,
                         M("持ち主が消した／kit が変えた") if old is absent else M("持ち主が変えた／command が変わった"))
                conflict(new_entry, current(new_entry), None, new, M("command の変更先（元の項目と一緒に確認する）"))

    for entry in dict.fromkeys(list(theirs) + list(record)):
        if entry in paired:
            continue
        old, new, rec = current(entry), theirs.get(entry, absent), record.get(entry)
        old_sha = settings_sha(old) if old is not absent else None
        new_sha = settings_sha(new) if new is not absent else None
        name = settings_name(entry)
        # 持ち主が手で消しても「足す」にしない。理由は最初の衝突と同じ言葉にする（資料を作り直さない）
        if entry in pending and new is absent:
            owned.pop(entry, None)            # kit から外れた。解消待ちのものは消さず、持ち主のものとして残す
            if old is not absent:
                plan["keep"].append(name)
            continue
        if entry in pending and old_sha != new_sha:
            conflict(entry, old, rec, new, M("未登録の項目と kit が違う") if rec is None else
                     M("持ち主が消した／kit が変えた") if old is absent else M("両方が変えた"))
            continue
        if rec is None:
            if old is absent:
                change(entry, new, old)
                plan["add"].append(name)
                owned[entry] = new_sha
            elif old_sha == new_sha:
                owned[entry] = new_sha
            elif entry[0] != "statusLine":
                conflict(entry, old, rec, new, M("未登録の項目と kit が違う"))
        elif new is absent:
            owned.pop(entry)
            if old is not absent:
                if old_sha == rec:
                    change(entry, absent, old)
                    plan["remove"].append(name)
                else:
                    plan["keep"].append(name)
        elif old is absent:
            if new_sha != rec:
                conflict(entry, old, rec, new, M("持ち主が消した／kit が変えた"))
        elif old_sha == new_sha:
            owned[entry] = new_sha
        elif old_sha == rec:
            change(entry, new, old)
            owned[entry] = new_sha
            plan["update"].append(name)
        elif new_sha != rec:
            conflict(entry, old, rec, new)
    if "permissions" not in cur and "permissions" in snip:
        cur["permissions"] = snip["permissions"]
        plan["add"].append(M("permissions(最小例)"))
    for (part, key), value in owned.items():
        if part == "statusLine":
            plan["record"][part] = value
        else:
            plan["record"].setdefault(part, {})[key] = value
    plan["changed"] = bool(plan["add"] or plan["update"] or plan["remove"])
    plan["new"] = json.dumps(cur, ensure_ascii=False, indent=2) + "\n" if plan["changed"] else raw
    return plan


# ------------------------------------------------------------------ 計画（何を足す・上げる・触らない）
class Item(object):
    def __init__(self, kind, src, dst, flags, new, read_current=True):
        self.kind, self.src, self.dst, self.flags, self.new = kind, src, dst, flags, new
        self.cur = read_text(dst) if read_current and os.path.exists(dst) else None
        self.exists = os.path.exists(dst)
        self.state = None
        self.choice = None

    @property
    def exe(self):
        return "exec" in self.flags


def manifest_key(path, cfg):
    if path.startswith(cfg["brain"] + os.sep):
        return "brain", os.path.relpath(path, cfg["brain"])
    return "claude", os.path.relpath(path, HOME)


def base_path(dst, cfg):
    where, key = manifest_key(dst, cfg)
    root = brain_state_dir(cfg["brain"]) if where == "brain" else KIT_STATE
    return os.path.join(root, "base", key)


def skill_dir(dst):
    prefix = os.path.join(CLAUDE, "skills") + os.sep
    return dst[len(prefix):].split(os.sep)[0] if dst.startswith(prefix) else None


def build_plan(cfg, manifests, legacy, fps, mode="update"):
    """base・持ち主・kit を比較する。install の確認は従来どおり。"""
    items = []
    lt = legacy_marks(cfg) if legacy else None
    for src, dst, flags in load_kitfiles(cfg):
        directory = skill_dir(dst)
        collision = (mode == "update" and "files" in manifests["claude"] and directory and
                     os.path.isdir(os.path.join(CLAUDE, "skills", directory)) and
                     bool(os.listdir(os.path.join(CLAUDE, "skills", directory))) and
                     not claude_dir_owned("skills", directory, manifests["claude"]))
        it = Item("kit", src, dst, flags, source_text(src, cfg, flags), read_current=not collision)
        if collision:
            it.state, it.base = "collision", None
            items.append(it)
            continue
        where, key = manifest_key(dst, cfg)
        ent = (manifests[where].get("files") or {}).get(key)
        bp = base_path(dst, cfg)
        it.base = read_text(bp) if ent else None
        if it.base is not None and sha(it.base) != ent.get("sha"):
            it.base = None
        if not os.path.exists(bp) and ent and it.cur is not None and sha(it.cur) == ent.get("sha"):
            it.base = it.cur
        if not it.exists:
            it.state = "add"
        elif it.cur == it.new:
            it.state = "same"
        elif mode == "install":
            if ent and it.cur is not None and sha(it.cur) == ent.get("sha"):
                it.state = "upgrade"
            elif ent and ent.get("declined") == sha(it.new):
                it.state = "declined"
            else:
                it.state = "edited"
        elif it.base is not None and it.cur == it.base:
            it.state = "upgrade"
        elif it.base is not None and it.new == it.base:
            it.state = "owner"
        elif not ent and legacy and it.cur is not None and fingerprint_versions(src, it.cur, lt, fps):
            it.state = "upgrade"
        else:
            it.state = "conflict"
        items.append(it)
    tracked = {manifest_key(it.dst, cfg) for it in items}
    dropped = set()
    if mode == "update":
        # HOME に // が混ざっても（macOS の TMPDIR は / で終わる）比べられるように、正規化してから比べる
        for where, root in (("brain", os.path.abspath(cfg["brain"])), ("claude", os.path.abspath(CLAUDE))):
            base_root = os.path.abspath(cfg["brain"] if where == "brain" else HOME)
            for key, ent in sorted((manifests[where].get("files") or {}).items()):
                dst = os.path.abspath(os.path.join(base_root, key))
                # 別の manifest や領域外（claude 側は ~/.claude の外）を指す記録は扱わない。
                if (where, key) in tracked or manifest_key(dst, cfg) != (where, key):
                    continue
                if not dst.startswith(root + os.sep):
                    continue
                if not os.path.realpath(dst).startswith(os.path.realpath(root) + os.sep):
                    continue
                it = Item("kit", None, dst, [], None)
                it.state = "dropped"
                it.base = read_text(base_path(dst, cfg))
                it.remove = it.cur is not None and sha(it.cur) == ent.get("sha")
                dropped.add(dst)
                items.append(it)
    for src, dst, flags in owner_files(cfg):
        if dst in dropped:
            continue
        it = Item("owner", src, dst, flags, None, read_current=False)
        it.state = "keep" if it.exists else "add"
        if it.state == "add":
            it.new = io.open(source_path(src, cfg), "rb").read()
            if "render" in flags:
                it.new = render(it.new.decode("utf-8"), cfg, flags)
        items.append(it)
    return items


def diff_text(a, b, path):
    return "".join(difflib.unified_diff((a or "").splitlines(True), (b or "").splitlines(True),
                                        M("今: ") + tilde(path), M("新: ") + tilde(path)))


def diff_count(a, b):
    plus = minus = 0
    for l in difflib.unified_diff((a or "").splitlines(), (b or "").splitlines(), lineterm="", n=0):
        if l.startswith("+") and not l.startswith("+++"):
            plus += 1
        elif l.startswith("-") and not l.startswith("---"):
            minus += 1
    return plus, minus


def owner_inventory(cfg, manifests, items, sett_record):
    """kit の外は名前だけ集める。設定は JSON のキーと command だけを見る。"""
    inventory = {part: [] for part in ("skills", "agents", "hooks", "plugins", "marketplaces")}
    manifest = manifests["claude"]
    planned = {skill_dir(it.dst) for it in items if it.kind == "kit" and it.state != "dropped"}
    for part in ("skills", "agents"):
        root = os.path.join(CLAUDE, part)
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            if claude_dir_owned(part, name, manifest) or ".claude/%s/%s" % (part, name) in manifest.get("files", {}):
                continue
            if part == "skills" and (name in planned or not os.path.isdir(os.path.join(root, name))):
                continue
            inventory[part].append(name)
    known = set()
    for part, keys in sett_record.items():
        if part != "statusLine":
            known.update((part, key) for key in keys)
    for snippet in ("settings.snippet.json", "settings.codex.json"):
        known.update(settings_entries(load_json(os.path.join(KIT, "claude", snippet), {})))
    cur = load_json(os.path.join(CLAUDE, "settings.json"), {}) or {}
    hooks = set()
    for event, groups in cur.get("hooks", {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                command = hook.get("command")
                if isinstance(command, str) and ("hooks." + event, command) not in known:
                    hooks.add(("hooks." + event, command))
    inventory["hooks"] = [part + ": " + command for part, command in sorted(hooks)]
    for part, label in (("enabledPlugins", "plugins"), ("extraKnownMarketplaces", "marketplaces")):
        inventory[label] = sorted(key for key in cur.get(part, {}) if (part, key) not in known)
    return inventory


def name_collisions(cfg, items, inventory):
    names = {p[key].lower() for p in cfg["personas"].values() for key in ("id", "name")}
    names.update(skill_dir(it.dst).lower() for it in items
                 if it.kind == "kit" and it.state != "dropped" and skill_dir(it.dst))
    collisions = []
    for part in ("skills", "agents"):
        for name in inventory[part]:
            stem = (os.path.splitext(name)[0] if part == "agents" and
                    not os.path.isdir(os.path.join(CLAUDE, part, name)) else name)
            if stem.lower() in names:
                collisions.append(M("%s/%s: 持ち主の方を %s-own に改名するか、役割を統合するか、相棒と持ち主で決める")
                                  % (part, name, stem))
    for it in items:
        if it.state == "collision":
            collisions.append(M("%s: 持ち主の方を別名に移すか、kit の方を使わないか（この場所には書かない）") % tilde(it.dst))
    return collisions


def inventory_lines(inventory):
    return [M("%s: %d 件（%s）") % (part, len(names), M("、").join(names) or M("なし"))
            for part, names in inventory.items()]


def print_collisions(collisions, bundle):
    if collisions:
        print(M("名前の重なり: %d 件") % len(collisions))
        for line in collisions:
            print("  " + line)
        if bundle:
            print(M("衝突の資料: %s") % tilde(bundle))


# ------------------------------------------------------------------ 退避と戻し
def backup_seq(meta):
    seq = meta.get("seq")
    return seq if isinstance(seq, int) and not isinstance(seq, bool) and seq > 0 else None


def meta_sha(directory):
    path = os.path.join(directory, "meta.json")
    return sha(open_bytes(path)) if os.path.isfile(path) else None


def read_backup_meta(d):
    """~/.claude/<d>/meta.json を読む。(meta, None)、無い（本物のディレクトリで meta.json だけ無い）なら (None, None)、
    確かめられない・壊れているなら (None, 理由)。FIFO などで止まらないよう、普通のファイルでなければ開かない。"""
    top = os.path.join(CLAUDE, d)
    path = os.path.join(top, "meta.json")
    try:
        if not stat.S_ISDIR(os.lstat(top).st_mode):
            return None, M("退避がディレクトリでない（symlink・ファイル）")
        if not stat.S_ISREG(os.lstat(path).st_mode):
            return None, M("meta.json が普通のファイルでない")
    except OSError as e:
        if e.errno == errno.ENOENT and os.path.isdir(top) and not os.path.islink(top):
            return None, None
        return None, M("確かめられない: %s") % e
    m = load_json(path)
    if not isinstance(m, dict) or not m:
        return None, M("読めない・JSON の object でない")
    return m, None


def scan_backups():
    """(今ある退避（戻し済みも含む）の通し番号の最大 + 1, {通し番号の無い退避の名前: その meta.json の sha})。
    一覧は新しい退避の meta に残し、番号の無い退避がこの退避より前に書き終わっていたことの証にする
    （古い版の kit をあとで・同時に使うと、番号の無い退避が番号のある退避より新しくなりうる）。"""
    top, legacy = 0, {}
    if os.path.isdir(CLAUDE):
        for d in sorted(os.listdir(CLAUDE)):
            if d.startswith("backup-brain-kit-"):
                m, why = read_backup_meta(d)
                if why or m is None:
                    continue   # 壊れた退避は --rollback が止まる。ここでは開かずに飛ばす
                if "seq" not in m:
                    legacy[d] = meta_sha(os.path.join(CLAUDE, d))
                elif backup_seq(m):
                    top = max(top, backup_seq(m))
    return top + 1, legacy


class Backup(object):
    def __init__(self, kind, meta):
        self.dir = os.path.join(CLAUDE, "backup-brain-kit-%s" % STAMP)
        n = 1
        while os.path.exists(self.dir):
            n += 1
            self.dir = os.path.join(CLAUDE, "backup-brain-kit-%s-%d" % (STAMP, n))
        # 作った順は壁時計でなく通し番号で持つ。時計は NTP や仮想機械の時刻合わせで数 ms 戻ることがあり、
        # 同じ秒の退避の created や、前の秒に戻った STAMP では新旧が入れ替わる
        seq, legacy = scan_backups()
        self.meta = dict(meta, kind=kind, stamp=STAMP, seq=seq, legacy_before=legacy,
                         created=datetime.datetime.now().isoformat(timespec="microseconds"),
                         overwritten=[], added={}, worktrees=[], rolled_back=False)
        self.opened = False

    def _open(self):
        if not self.opened:
            os.makedirs(os.path.join(self.dir, "files"))
            self.opened = True

    def save(self, path):
        """上書きする前に写す。"""
        if path in self.meta["overwritten"] or not os.path.exists(path):
            return
        self._open()
        dst = os.path.join(self.dir, "files", path.lstrip(os.sep))
        if not os.path.isdir(os.path.dirname(dst)):
            os.makedirs(os.path.dirname(dst))
        shutil.copy2(path, dst)
        self.meta["overwritten"].append(path)
        self._journal()

    def added(self, path, text):
        self._open()
        self.meta["added"][path] = sha(text)
        self._journal()

    def worktree(self, path, branch, new_branch):
        self._open()
        self.meta["worktrees"].append({"path": path, "branch": branch, "new_branch": new_branch})
        self._journal()

    def _journal(self):
        """書き換えの前に meta.json を書く。途中で落ちても --rollback がこの退避を拾えるように。"""
        write_atomic(os.path.join(self.dir, "meta.json"), dump_json(self.meta))

    def close(self):
        if self.opened:
            self._journal()
        return self.dir if self.opened else None


def write_atomic(path, text):
    """隣の一時ファイルに書いてから置き換える。書きかけで落ちても前の内容が残る。"""
    tmp = path + ".tmp"
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def put(path, text, backup, exe=False):
    if os.path.exists(path):
        backup.save(path)
    else:
        backup.added(path, text)
    if isinstance(text, bytes):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(text)
        if exe:
            os.chmod(path, 0o755)
    else:
        write_text(path, text, exe=exe)


# ------------------------------------------------------------------ worktree とラベル
def git(brain, *a, **kw):
    return run(["git", "-C", brain] + list(a), **kw)


def worktree_branches(brain):
    rc, out, _ = git(brain, "worktree", "list", "--porcelain")
    res = {}
    cur = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = line[9:]
        elif line.startswith("branch refs/heads/") and cur:
            res[line[len("branch refs/heads/"):]] = cur
    return res


def plan_worktrees(cfg, roles):
    """作る worktree の一覧。在るもの・同じブランチが別の場所に在るものは作らない。"""
    brain = cfg["brain"]
    out = []
    if git(brain, "rev-parse", "--verify", "-q", "HEAD")[0] != 0:
        return out
    wts = worktree_branches(brain)
    for r in roles:
        if r not in cfg["personas"]:
            continue
        b = persona(cfg, r)["id"]
        path = worktree_of(cfg, r)
        if b in wts:
            continue                                   # そのブランチはもうどこかで開いている
        if os.path.exists(path):
            out.append((r, path, b, "skip"))         # 別のものが在る。触らない
            continue
        out.append((r, path, b, "add"))
    return out


def make_worktree(cfg, role, path, branch, backup):
    brain = cfg["brain"]
    new_branch = git(brain, "rev-parse", "--verify", "-q", "refs/heads/" + branch)[0] != 0
    cmd = ["worktree", "add", "-q"] + (["-b", branch, path] if new_branch else [path, branch])
    rc, out, err = git(brain, *cmd)
    if rc != 0:
        print(M("  warn: worktree %s を作れなかった: %s") % (tilde(path), err.strip()))
        return
    backup.worktree(path, branch, new_branch)
    # 相棒の領域だけを見えなくする（tree からは消さない）
    rc1 = run(["git", "-C", path, "sparse-checkout", "init", "--no-cone"])[0]
    rc2 = run(["git", "-C", path, "sparse-checkout", "set", "--stdin"],
              inp="/*\n!/%s/\n" % persona(cfg, "partner")["name"])[0]
    note = "" if rc1 == 0 and rc2 == 0 else M("（sparse-checkout は失敗。相棒の領域も見えている）")
    print(M("  worktree: %s（ブランチ %s）%s") % (tilde(path), branch, note))


def wanted_labels(cfg):
    ls = list(COMMON_LABELS)
    for r in ("dev", "review", "release"):
        if r in cfg["personas"]:
            ls.append(label_of(cfg, r))
    return ls


def gh_ready():
    return have("gh") and run(["gh", "auth", "status"], timeout=15)[0] == 0


def ensure_labels(cfg, dry):
    repos = cfg.get("repos") or []
    if not repos:
        print(M("  ラベル: リポジトリが無いので飛ばす（--repos か brain の .brain-kit/config.json の repos）"))
        return
    if not gh_ready():
        print(M("  ラベル: gh が無いか未認証なので飛ばす。後で作る: %s") % " ".join(wanted_labels(cfg)))
        return
    for r in repos:
        if "/" not in r:
            print(M("  skip: %s は owner/repo 形式ではない") % r)
            continue
        rc, out, _ = run(["gh", "label", "list", "-R", r, "--limit", "200", "--json", "name", "--jq", ".[].name"], timeout=30)
        have_ = set(out.splitlines()) if rc == 0 else set()
        missing = [l for l in wanted_labels(cfg) if l not in have_]
        if not missing:
            print(M("  ラベル %s: 全部ある") % r)
            continue
        if dry:
            print(M("  ラベル %s: 足す %s") % (r, " ".join(missing)))
            continue
        for l in missing:
            if run(["gh", "label", "create", l, "-R", r, "--force"], timeout=30)[0] != 0:
                print(M("  warn: %s に %s を作れなかった") % (r, l))
        print(M("  ラベル %s: 足した %s") % (r, " ".join(missing)))


# ------------------------------------------------------------------ 書く（install と update で共通）
def apply_items(items, cfg, backup, args, mode):
    """計画どおりに書く。更新の衝突は残し、install の edited は確認する。"""
    written, kept = [], []
    for it in items:
        if it.kind == "owner":
            if it.state == "add":
                if isinstance(it.new, bytes):
                    d = os.path.dirname(it.dst)
                    if not os.path.isdir(d):
                        os.makedirs(d)
                    with open(it.dst, "wb") as f:
                        f.write(it.new)
                    backup.added(it.dst, it.new)
                else:
                    put(it.dst, it.new, backup)
                written.append(it)
            continue
        if it.state == "dropped":
            if it.remove:
                backup.save(it.dst)
                os.remove(it.dst)
            bp = base_path(it.dst, cfg)
            if os.path.isfile(bp):
                backup.save(bp)
                os.remove(bp)
            written.append(it)
            continue
        if it.state in ("add", "upgrade"):
            put(it.dst, it.new, backup, it.exe)
            written.append(it)
        elif it.state in ("edited", "conflict"):
            it.choice = choose_edited(it, args, mode)
            if it.choice == "new":
                put(it.dst, it.new, backup, it.exe)
                written.append(it)
            else:
                kept.append(it)
                # 前の更新の .new が残っていて中身が違えば、今回の新しい版で置き換える（前のものは退避に残る）
                if mode == "update" and read_text(it.dst + ".new") != it.new:
                    it.new_replaced = os.path.exists(it.dst + ".new")
                    put(it.dst + ".new", it.new, backup, it.exe)
        elif it.state == "same" and it.exe and not os.access(it.dst, os.X_OK):
            backup.save(it.dst)
            os.chmod(it.dst, 0o755)
        if it.state in ("add", "upgrade", "same") or it.choice == "new":
            if read_text(base_path(it.dst, cfg)) != it.new:
                put(base_path(it.dst, cfg), it.new, backup)
    return written, kept


def write_conflicts(items, cfg, backup, settings=(), inventory=None, collisions=()):
    """同じ衝突は既存の bundle を再利用する。候補は実ファイルへ戻さない。"""
    if not items and not settings and not collisions:
        return None
    files = {}
    notes = [M("# 更新の衝突\n")]
    for it in items:
        where, key = manifest_key(it.dst, cfg)
        stem = os.path.join("files", where, key)
        ours = open_bytes(it.dst)
        files[stem + ".ours"] = ours
        files[stem + ".theirs"] = it.new
        notes.append("\n## %s\n\n.new: %s.new\n" % (tilde(it.dst), tilde(it.dst)))
        if it.base is None:
            notes.append(M("\nbase 不明。git merge-file: not possible without base\n"))
            notes.append("\n### ours → theirs\n\n```diff\n%s```\n" % diff_text(it.cur, it.new, it.dst))
        else:
            files[stem + ".base"] = it.base
            with tempfile.TemporaryDirectory() as tmp:
                paths = [os.path.join(tmp, name) for name in ("ours", "base", "theirs")]
                for path, text in zip(paths, (ours, it.base, it.new)):
                    if isinstance(text, bytes):
                        with open(path, "wb") as f:
                            f.write(text)
                    else:
                        write_text(path, text)
                try:
                    result = subprocess.run(
                        ["git", "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "theirs"] + paths,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
                    rc, merged = result.returncode, result.stdout
                except (OSError, subprocess.TimeoutExpired):
                    rc, merged = -1, b""
            # git の負の終了値はシェルでは 255 になる。
            result = "clean" if rc == 0 else "%d conflict markers" % rc if 0 < rc <= 127 else M("エラー")
            files[stem + ".merged"] = merged
            notes.append(M("\nbase 既知。git merge-file: %s\n") % result)
            for name, text in (("ours", it.cur), ("theirs", it.new)):
                notes.append("\n### base → %s\n\n```diff\n%s```\n" % (name, diff_text(it.base, text, it.dst)))
    if settings:
        notes.append("\n## settings.json\n")
        for entry in settings:
            notes.append("\n### %s\n\n%s\n" % (entry["name"], entry["reason"]))
            for title, key in ((M("現在（ours）"), "ours"), (M("記録した sha"), "recorded"), (M("kit（theirs）"), "theirs")):
                notes.append("\n%s\n\n```json\n%s```\n" % (title, dump_json(entry[key])))
    notes.append(M("\n## 持ち主が足した agent と道具（kit の外。中身は読んでいない）\n\n"))
    notes.extend("- " + line + "\n" for line in inventory_lines(inventory or {
        part: [] for part in ("skills", "agents", "hooks", "plugins", "marketplaces")}))
    notes.append(M("\n## 名前の重なり\n\n"))
    notes.extend("- " + line + "\n" for line in (collisions or [M("なし")]))
    notes.append(M("\n## 解き方\n\n相棒と資料を読み、書く前に全体の計画を持ち主に見せて OK をもらう。"
                 "まず同じコマンドに --dry-run を付けて確かめる。\n\n"
                 "```bash\n./install.sh --resolve <file> --from <merged file>\n"
                 "./install.sh --resolve <file>   # 今の編集済みファイルを結果にする\n"
                 "./install.sh --resolve --keep <file>\n"
                 "./install.sh --resolve ~/.claude/settings.json --from <merged file>\n"
                 "./install.sh --resolve ~/.claude/settings.json\n"
                 "./install.sh --resolve --keep ~/.claude/settings.json\n```\n\n"
                 "./install.sh --rollback は最後の resolve から先に戻し、次に更新を戻す。\n"))
    files["README.md"] = "".join(notes)
    root = os.path.join(KIT_STATE, "conflicts")
    if os.path.isdir(root):
        for name in sorted(os.listdir(root), reverse=True):
            candidate = os.path.join(root, name)
            if all(os.path.isfile(os.path.join(candidate, key)) and
                   open_bytes(os.path.join(candidate, key)) == as_bytes(text) for key, text in files.items()):
                return candidate
    stamp = os.path.basename(backup.dir).replace("backup-brain-kit-", "", 1)
    target = os.path.join(root, stamp)
    n = 1
    while os.path.exists(target):
        n += 1
        target = os.path.join(root, stamp + "-%d" % n)
    for key, text in files.items():
        put(os.path.join(target, key), text, backup)
    return target


def as_bytes(text):
    return text if isinstance(text, bytes) else text.encode("utf-8")


def open_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def choose_edited(it, args, mode):
    """手で直した kit のファイル: 新しい版にする／今のままにする／差分を見る。"""
    forced = getattr(args, "edited", None)
    if forced in ("new", "keep"):
        return forced
    if mode == "update":
        return "keep"
    if mode == "install" and getattr(args, "yes", False):
        return "new"                                  # install --yes は v9 までと同じく退避して上書き
    if not interactive(args):
        return "keep"
    while True:
        p, m = diff_count(it.cur, it.new)
        a = ask(M("  %s は手で直してある（新しい版との差 +%d -%d）。 [n] 新しい版にする / [k] 今のままにする / [d] 差分を見る")
                % (tilde(it.dst), p, m), "k", args).lower()
        if a.startswith("n"):
            return "new"
        if a.startswith("k"):
            return "keep"
        if a.startswith("d"):
            sys.stdout.write(diff_text(it.cur, it.new, it.dst) or M("  （差なし）\n"))


def update_manifests(items, cfg, manifests):
    for it in items:
        if it.kind != "kit":
            continue
        where, key = manifest_key(it.dst, cfg)
        files = manifests[where].setdefault("files", {})
        if it.state in ("add", "upgrade", "same") or it.choice == "new":
            files[key] = {"sha": sha(it.new)}
        elif it.state == "dropped":
            files.pop(key, None)
        elif it.state == "conflict":
            # 旧版から引き継いだ未解消の kit も登録し、次回に所有ディレクトリと取り違えない。
            files.setdefault(key, {"sha": ""})
        elif it.choice == "keep" and it.state == "edited":
            ent = dict(files.get(key) or {})
            ent["declined"] = sha(it.new)
            ent.setdefault("sha", "")
            files[key] = ent
    for where in ("brain", "claude"):
        manifests[where]["version"] = VERSION
    manifests["claude"]["lang"] = content_lang(cfg)
    package = load_json(os.path.join(KIT, "package.json"))
    if isinstance(package, dict) and isinstance(package.get("version"), str):
        manifests["claude"]["package_version"] = package["version"]


def write_state(cfg, manifests, backup):
    put(config_path(cfg["brain"]), dump_json(cfg), backup)
    put(brain_manifest_path(cfg["brain"]), dump_json(manifests["brain"]), backup)
    put(CLAUDE_MANIFEST, dump_json(manifests["claude"]), backup)


def load_manifests(brain):
    return {"brain": load_json(brain_manifest_path(brain), {}) or {},
            "claude": load_json(CLAUDE_MANIFEST, {}) or {}}


def commit_brain(cfg, paths, msg):
    brain = cfg["brain"]
    if git(brain, "rev-parse", "--is-inside-work-tree")[0] != 0:
        return
    rel = sorted({os.path.relpath(p, brain) for p in paths if p.startswith(brain + os.sep)})
    if not rel:
        return
    git(brain, "add", "-A", "--", *rel)
    rc, _, _ = git(brain, "diff", "--cached", "--quiet", "--", *rel)
    if rc == 0:
        return
    rc, _, err = git(brain, "commit", "-q", "-m", msg, "--", *rel)
    if rc != 0:
        print(M("  warn: brain のコミットに失敗（git の user.name / user.email を設定してから git -C %s commit）") % tilde(brain))
    else:
        print(M("  brain にコミットした: %s") % msg)


# ------------------------------------------------------------------ 出力
def print_plan(items, sett, wts, dry, verbose_diff):
    def rows(kind, state):
        return [it for it in items if it.kind == kind and it.state == state]
    groups = [
        (M("足すもの（kit）"), rows("kit", "add")),
        (M("上げるもの（kit だけが変わった）"), rows("kit", "upgrade")),
        (M("手で直したもの（kit。上書きせずに聞く）"), rows("kit", "edited")),
        (M("持ち主だけが変えたもの（触らない）"), rows("kit", "owner")),
        (M("両方が変えたもの（衝突。<file>.new を置く）"), rows("kit", "conflict")),
        (M("持ち主のディレクトリと重なるもの（書かない）"), rows("kit", "collision")),
        (M("kit から外れたもの（消す・残す）"), rows("kit", "dropped")),
        (M("足すもの（持ち主の領域の骨格。無いものだけ）"), rows("owner", "add")),
    ]
    for title, rs in groups:
        if not rs:
            continue
        print(M("  %s: %d 件") % (title, len(rs)))
        for it in rs:
            extra = ""
            if it.state in ("upgrade", "edited", "owner", "conflict", "dropped"):
                p, m = diff_count(it.cur, it.new)
                extra = "  (+%d -%d)" % (p, m)
            if it.state == "dropped":
                extra += "  " + (M("消す") if it.remove else M("残す") if it.exists else M("記録を外す"))
            print("    %s%s" % (tilde(it.dst), extra))
    same = len(rows("kit", "same"))
    keep = len(rows("owner", "keep"))
    print(M("  変わらないもの（kit、最新）: %d 件") % same)
    print(M("  触らないもの（持ち主のもの。核・辞書・関係・日誌・決定・知識・プロジェクト・記録など）: %d 件＋brain の中身すべて") % keep)
    for state, title in (("add", M("に足すもの")), ("update", M("で上げるもの（kit だけが変わった）")),
                         ("remove", M("から外すもの（kit から外れた、変えていない）")),
                         ("conflict", M("の衝突（触らない）")), ("keep", M("で残すもの（kit から外れた、持ち主が変えた）"))):
        if sett[state]:
            print(M("  settings.json %s: %d 件") % (title, len(sett[state])))
            for entry in sett[state]:
                print("    " + (entry["name"] + M("（") + entry["reason"] + M("）") if state == "conflict" else entry))
    for r, path, b, what in wts:
        print(M("  worktree %s: %s（ブランチ %s）") % (M("足す") if what == "add" else M("作らない（別のものが在る）"), tilde(path), b))
    if verbose_diff:
        if sett["changed"]:
            sys.stdout.write(diff_text(sett["raw"], sett["new"], sett["path"]))
        for it in items:
            if it.kind == "kit" and it.state in ("upgrade", "edited", "conflict", "owner", "dropped"):
                print()
                sys.stdout.write(diff_text(it.cur, it.new, it.dst))


def changelog_since(v_from):
    if _LANG == "en":
        return M("変更履歴（日本語）: %s") % tilde(os.path.join(KIT, "CHANGELOG.md"))
    t = read_text(os.path.join(KIT, "CHANGELOG.md")) or ""
    out = []
    for block in re.split(r"(?m)^## ", t)[1:]:
        m = re.match(r"v(\d+)", block)
        if m and (v_from is None or int(m.group(1)) > v_from):
            out.append("## " + block.rstrip())
    return "\n\n".join(out)


# ------------------------------------------------------------------ install
def cmd_install(args):
    warning = claude_version_warning()
    if warning:
        print(warning)
    brain = os.path.abspath(os.path.expanduser(args.brain))
    cman = load_json(CLAUDE_MANIFEST, {}) or {}
    if os.path.exists(config_path(brain)):
        die(M("%s には brain-kit が入っている（版の記録あり）。更新は --update") % tilde(brain), 1)
    legacy = detect_legacy(brain)
    if legacy and (legacy.get("partner_skill") or legacy.get("dev")):
        die(M("%s には前の版の brain-kit が入っている。更新は --update（名前はそのまま引き継ぐ）") % tilde(brain), 1)
    if os.path.exists(brain) and os.listdir(brain) and not args.brain_merge:
        if not interactive(args):
            die(M("%s が既にある。上乗せするなら --brain-merge、別の場所にするなら --brain <dir>。会社が違えば別 brain にする。") % tilde(brain), 1)
        if not ask(M("  %s が既にある。骨格を足す？（無いものだけ足す。既存ファイルは触らない）[y/N]") % tilde(brain), "n", args).lower().startswith("y"):
            sys.exit(1)

    say(M("[1/6] 名前を決める（4 人。空 Enter で既定。英字でない名前は id も聞く）"))
    used = set()
    personas = {}
    for r in ROLES:
        personas[r] = choose_persona(r, args, used, cman)
    owner = args.user or ask(M("  あなたの呼び名（相棒があなたをどう呼ぶか）"), M("持ち主"), args)
    projects = split_csv(args.projects if args.projects is not None else ask(M("  プロジェクト名（カンマ区切り。無ければ空）"), "", args))
    repos = split_csv(args.repos if args.repos is not None else ask(M("  GitHub リポジトリ owner/repo（カンマ区切り。無ければ空）"), "", args))
    # main() で決めた言語（--lang、無ければこの機の記録、無ければ日本語）で作って記録する
    cfg = {"version": VERSION, "lang": args.lang or _LANG, "brain": brain, "owner": owner, "personas": personas, "repos": repos,
           "installed_at": TODAY, "updated_at": TODAY, "history": [{"date": TODAY, "to": VERSION, "how": "install"}]}
    print(M("言語: %s（%s）") % (language_name(cfg["lang"]), cfg["lang"]))
    for r in ROLES:
        p = personas[r]
        print(M("  %s: %s（id %s）") % (M(ROLE_JA[r]), p["name"], p["id"]))
    print(M("  呼び名: %s  projects: %s  repos: %s  brain: %s") % (owner, ",".join(projects) or M("なし"), ",".join(repos) or M("なし"), tilde(brain)))

    backup = Backup("install", {"brain": brain, "from": None, "to": VERSION})
    manifests = {"brain": {}, "claude": cman}
    say(M("[2/6] brain と ~/.claude にファイルを置く"))
    if not os.path.isdir(brain):
        os.makedirs(brain)
    items = build_plan(cfg, manifests, False, {}, mode="install")
    # --brain-merge: 同名の .md で中身が違う kit のファイルは横に置く（v9 までと同じ）
    if args.brain_merge:
        for it in items:
            if it.kind == "kit" and it.state == "edited" and it.dst.startswith(brain + os.sep) and it.dst.endswith(".md"):
                alt = it.dst[:-3] + ".brain-kit.md"
                if not os.path.exists(alt):
                    put(alt, it.new, backup)
                    print(M("  横に置いた（既存と中身が違う）: %s") % tilde(alt))
                it.state = "declined"
    written, kept = apply_items(items, cfg, backup, args, "install")
    print(M("  置いた: %d 件、今のまま: %d 件") % (len(written), len(kept)))
    make_projects(cfg, projects, backup)
    make_cards(cfg, repos, backup)

    say(M("[3/6] settings.json にマージ（丸ごと上書きしない）"))
    sett = plan_settings(args.codex, manifests["claude"])
    if sett["changed"]:
        put(sett["path"], sett["new"], backup)
    manifests["claude"]["settings"] = sett["record"]
    print(M("  追加: %s") % (", ".join(sett["add"]) if sett["add"] else M("なし（すべて既にあった）")))

    update_manifests(items, cfg, manifests)
    write_state(cfg, manifests, backup)

    say("[4/6] git: %s" % tilde(brain))
    if git(brain, "rev-parse", "--is-inside-work-tree")[0] != 0:
        git(brain, "init", "-q")
        msg = M("brain: 初期化（brain-kit v%d）") % VERSION
    else:
        msg = M("brain: brain-kit v%d の骨格を追加") % VERSION
    git(brain, "add", "-A")
    if git(brain, "diff", "--cached", "--quiet")[0] != 0:
        if git(brain, "commit", "-q", "-m", msg)[0] != 0:
            print(M("  warn: コミットに失敗（git の user.name / user.email を設定してから再実行）"))
        else:
            print(M("  コミットした: %s") % msg)

    say(M("[5/6] worktree（開発・レビュー・リリースの居場所）"))
    if args.no_worktrees:
        print(M("  --no-worktrees なので作らない"))
    else:
        for r, path, b, what in plan_worktrees(cfg, WORKTREE_ROLES):
            if what == "add":
                make_worktree(cfg, r, path, b, backup)
            else:
                print(M("  作らない: %s が既にある（worktree ではない）") % tilde(path))

    say(M("[6/6] issue ラベル"))
    ensure_labels(cfg, False)
    bdir = backup.close()
    finish_message(cfg, bdir, None)


def make_projects(cfg, projects, backup):
    for p in projects:
        f = os.path.join(cfg["brain"], "projects", p + ".md")
        if os.path.exists(f):
            continue
        put(f, M("---\ndate: %s\nproject: %s\ntags: [project]\n---\n\n# %s\n\n## 目的\n<!-- 何のためのプロジェクトか。1〜3行 -->\n\n"
               "## 現在地\n<!-- いまどこまで来ているか。動いたら書き換える -->\n\n## 権限\n"
               "<!-- エージェントに許すこと。書かなければ「PR まで、マージしない」 -->\n- PR まで。マージしない\n\n"
               "## 関連\n<!-- リポジトリ、決定ノート、人 -->\n") % (TODAY, p, p), backup)
        print("  projects/%s.md" % p)


def make_cards(cfg, repos, backup):
    tpl = read_text(os.path.join(cfg["brain"], "dev", "状況", "_テンプレート.md"))
    if tpl is None:
        return
    for r in repos:
        short = r.split("/")[-1]
        f = os.path.join(cfg["brain"], "dev", "状況", short + ".md")
        if os.path.exists(f):
            continue
        s = tpl.replace("<repo>", short).replace("2026-01-01", TODAY)
        s = s.replace("# %s\n" % short, M("# %s\n\nリポジトリ: `%s`\n") % (short, r), 1)
        put(f, s, backup)
        print(M("  dev/状況/%s.md（%s）") % (short, r))


def finish_message(cfg, bdir, v_from):
    p = {r: persona(cfg, r) for r in ROLES if r in cfg["personas"]}
    b = tilde(cfg["brain"])
    print()
    print(M("完了（brain-kit v%d）。") % VERSION)
    print("  brain     : %s" % b)
    for r in ROLES:
        if r in p:
            print(M("  %-8s: %s（/%s、領域 %s/、起動 ~/.claude/brain-kit/bin/start-%s）")
                  % (M(ROLE_JA[r]), p[r]["name"], p[r]["id"], area_of(cfg, r), p[r]["id"]))
    print(M("  ~/.claude/brain-kit/bin/start-all（4 人をまとめて起動。1 回だけ起動し、一覧で確かめる）"))
    if bdir:
        print(M("  退避      : %s（--rollback で戻せる）") % tilde(bdir))
    print()
    print(M("次にやること:"))
    print(M("  1. cd %s && claude → /setup（持ち主のこと・声・プロジェクト・4 人の分担を埋める）") % b)
    print(M("  2. 相棒は /%s、開発は /%s、レビューは /%s、リリースは /%s")
          % tuple(p[r]["id"] if r in p else "-" for r in ROLES))
    print(M("  3. 工程表（brain-kit Dashboard）は相棒の skill の「工程表」節。README の「工程表」"))
    print(M("  4. 初日の練習（任意）: ./install.sh --practice（ローカル限定・本物には触らない。--practice-cleanup で消せる）"))


# ------------------------------------------------------------------ update
def resolve_config(args, cman, quiet=False):
    """版の記録があれば読む。無ければ古い入れ方（v1〜v9）として形から読み取る。(cfg, from_version, 説明, legacy)"""
    brain = os.path.abspath(os.path.expanduser(args.brain))
    cfg = load_json(config_path(brain))
    if cfg:
        cfg["brain"] = brain
        # 言語の記録が無い brain は機械側の記録、それも無ければ日本語（中身を作る言語）
        cfg["lang"] = record_lang(cfg, cman)
        v = cfg.get("version")
        return cfg, v, M("v%s（brain の .brain-kit/config.json）") % v, False
    info = detect_legacy(brain)
    if not info:
        return None, None, M("入っていない"), False
    if not info.get("partner"):
        if not args.partner:
            die(M("相棒の領域（00_核.md を持つディレクトリ）が %s。--partner <名前> で指定する")
                % (M("複数ある: ") + ", ".join(info["partners"]) if info["partners"] else M("見つからない")), 2)
        info["partner"] = args.partner
    dev = info.get("dev") or info.get("dev_title") or args.dev or "dev"
    personas = {
        "partner": {"name": info["partner"], "id": info.get("partner_skill") or info["partner"]},
        "dev": {"name": dev, "id": dev, "label": dev},
    }
    cfg = {"version": None, "brain": brain, "owner": info["owner"], "personas": personas, "repos": info["repos"],
           "installed_at": None, "history": []}
    fps = load_fingerprints()
    v, desc = legacy_version(cfg, fps)
    return cfg, v, desc, True


def cmd_update(args):
    cman = load_json(CLAUDE_MANIFEST, {}) or {}
    cfg, v_from, desc, legacy = resolve_config(args, cman)
    if cfg is None:
        die(M("%s に brain-kit が見つからない。新しく入れるなら --update を付けずに実行する") % tilde(os.path.expanduser(args.brain)), 1)
    # 記録が無ければ機械側の記録、それも無ければ日本語（言語を選べるようになる前の入れ方）
    old_lang = record_lang(cfg, cman)
    cfg["lang"] = args.lang or old_lang
    if old_lang != cfg["lang"]:
        print(M("言語: %s → %s") % (language_name(old_lang), language_name(cfg["lang"])))
        print(M("持ち主のノート（核・辞書・関係・日誌など）は kit では翻訳しない。"))
    dry = args.dry_run
    say(M("brain-kit の更新%s: %s → v%d") % (M("（--dry-run: 何も変えない）") if dry else "", desc, VERSION))
    warning = claude_version_warning(missing=True)
    if warning:
        print(warning)
    for r in ("partner", "dev"):
        p = persona(cfg, r)
        print(M("  %s: %s（/%s）… 引き継ぐ") % (M(ROLE_JA[r]), p["name"], p["id"]))
    if args.repos is not None:
        cfg["repos"] = sorted(set((cfg.get("repos") or []) + split_csv(args.repos)))

    # 新しく足す役（レビュー・リリース）だけ名前を聞く
    new_roles = [r for r in ROLES if r not in cfg["personas"]]
    if new_roles:
        say(M("新しく足す人格: %s") % M("・").join(M(ROLE_JA[r]) for r in new_roles))
        used = {persona(cfg, r)["id"] for r in cfg["personas"]}
        for r in new_roles:
            if dry and not (getattr(args, r) or interactive(args)):
                cfg["personas"][r] = {"name": M(ROLE_JA[r]), "id": DEFAULT_ID[r], "label": DEFAULT_ID[r]}
                print(M("  %s: 名前は実行のときに聞く（既定 %s）") % (M(ROLE_JA[r]), M(ROLE_JA[r])))
                continue
            cfg["personas"][r] = choose_persona(r, args, used, cman)
            print(M("  %s: %s（/%s）") % (M(ROLE_JA[r]), cfg["personas"][r]["name"], cfg["personas"][r]["id"]))

    manifests = load_manifests(cfg["brain"])
    fps = load_fingerprints() if legacy else {}
    items = build_plan(cfg, manifests, legacy, fps)
    sett = plan_settings(args.codex, manifests["claude"])
    inventory = owner_inventory(cfg, manifests, items, manifests["claude"].get("settings", {}))
    collisions = name_collisions(cfg, items, inventory)
    wts = [] if args.no_worktrees else plan_worktrees(cfg, WORKTREE_ROLES)
    print_plan(items, sett, wts, dry, args.diff or dry)
    if dry:
        print(M("持ち主が足した agent と道具（名前だけ）:"))
        for line in inventory_lines(inventory):
            print("  " + line)
        print_collisions(collisions, None)
        if cfg.get("repos"):
            ensure_labels(cfg, True)
        print()
        print(M("--dry-run なので何も変えていない。上げるなら --dry-run を外して同じコマンド。"))
        if getattr(args, "edited", None) != "new":
            conf = [it for it in items if it.kind == "kit" and it.state == "conflict"]
            for it in conf:
                it.new_replaced = os.path.exists(it.dst + ".new") and read_text(it.dst + ".new") != it.new
            print_conflicts(conf, None)
        print_settings_conflicts(sett, None)
        return

    backup = Backup("update", {"brain": cfg["brain"], "from": v_from, "to": VERSION})
    written, kept = apply_items(items, cfg, backup, args, "update")
    if sett["changed"]:
        put(sett["path"], sett["new"], backup)
    manifests["claude"]["settings"] = sett["record"]
    # 衝突した項目を覚えておく（持ち主が手で消したあとの --resolve でも、どの項目だったか分かるように）
    pending = sorted({tuple(c["entry"]) for c in sett["conflict"]})
    if pending:
        manifests["claude"]["settings_conflicts"] = [list(e) for e in pending]
    else:
        manifests["claude"].pop("settings_conflicts", None)
    # 版の記録（無ければ最初の更新で書く）
    cfg["version"] = VERSION
    cfg["updated_at"] = TODAY
    cfg.setdefault("history", []).append({"date": TODAY, "from": v_from, "to": VERSION, "how": "update"})
    if v_from == VERSION and not written and not sett["changed"] and not [w for w in wts if w[3] == "add"] \
            and os.path.exists(config_path(cfg["brain"])):
        cfg["history"].pop()            # 何も変わらない 2 回目の更新は記録も増やさない
        cfg["updated_at"] = (load_json(config_path(cfg["brain"])) or {}).get("updated_at", TODAY)
    update_manifests(items, cfg, manifests)
    inventory = owner_inventory(cfg, manifests, items, sett["record"])
    collisions = name_collisions(cfg, items, inventory)
    bundle = write_conflicts(kept, cfg, backup, sett["conflict"], inventory, collisions)
    before = {p: read_text(p) for p in (config_path(cfg["brain"]), brain_manifest_path(cfg["brain"]), CLAUDE_MANIFEST)}
    new_state = {config_path(cfg["brain"]): dump_json(cfg), brain_manifest_path(cfg["brain"]): dump_json(manifests["brain"]),
                 CLAUDE_MANIFEST: dump_json(manifests["claude"])}
    for p, t in new_state.items():
        if before[p] != t:
            put(p, t, backup)
    for r, path, b, what in wts:
        if what == "add":
            make_worktree(cfg, r, path, b, backup)
    ensure_labels(cfg, False)
    touched = list(backup.meta["overwritten"]) + list(backup.meta["added"])
    commit_brain(cfg, touched, M("brain-kit: v%s → v%d に更新（kit のものだけ）") % (v_from if v_from else "?", VERSION))
    bdir = backup.close()

    print()
    changed = len(set(backup.meta["overwritten"]) | set(backup.meta["added"]))
    if changed == 0 and not backup.meta["worktrees"]:
        print(M("変わったもの: なし（すでに v%d）") % VERSION)
    else:
        print(M("変わったもの: %d 件（kit %d、持ち主の領域の骨格 %d、ほかは記録・衝突資料など）")
              % (changed, len([i for i in written if i.kind == "kit"]), len([i for i in written if i.kind == "owner"])))
    if bdir:
        print(M("退避: %s（戻すなら ./install.sh --rollback）") % tilde(bdir))
    if v_from != VERSION:
        cl = changelog_since(v_from)
        if cl:
            print()
            print(M("この版で変わったこと（CHANGELOG.md）:"))
            print(cl)
        if new_roles:
            print()
            print(M("新しく使えるもの:"))
            print_new_roles(cfg, new_roles)
    if any(it.src == "gen:start-all" for it in written):
        print(M("~/.claude/brain-kit/bin/start-all（4 人をまとめて起動。1 回だけ起動し、一覧で確かめる）"))
    print_conflicts(kept, bundle)
    print_settings_conflicts(sett, bundle)
    print_collisions(collisions, bundle)


def print_settings_conflicts(sett, bundle):
    if sett["conflict"]:
        print(M("settings.json の衝突: %d 件（そのまま。kit の版は資料に）") % len(sett["conflict"]))
        for entry in sett["conflict"]:
            print(M("  %s（%s）") % (entry["name"], entry["reason"]))
        if bundle:
            print(M("衝突の資料: %s") % tilde(bundle))


def print_conflicts(kept, bundle):
    """衝突が 1 件でもあれば、更新の最後に必ず件数と .new の一覧を出す（黙って終わらない）。"""
    if not kept:
        return
    print()
    print(M("衝突: %d 件（元のファイルはそのまま。新しい版は隣の .new）") % len(kept))
    for it in kept:
        note = M("（前の更新の .new を今回の新しい版で置き換える。前のものは退避）") if getattr(it, "new_replaced", False) else ""
        print("  %s.new%s" % (tilde(it.dst), note))
    if bundle:
        print(M("衝突の資料: %s") % tilde(bundle))
    print(M("相棒と資料を読んで計画を確認し、--resolve で解消する。kit の版にするなら --update --edited new（退避あり）。"))


def print_new_roles(cfg, roles):
    b = tilde(cfg["brain"])
    for r in roles:
        p = persona(cfg, r)
        if r == "review":
            print(M("  レビュー %s: 開発が PR に `%s` ラベルを付けると、%s が %s/review/規準.md で読んで判定する。"
                  " 起動は ~/.claude/brain-kit/bin/start-%s（または worktree で /%s）") % (p["name"], label_of(cfg, r), p["name"], b, p["id"], p["id"]))
        elif r == "release":
            print(M("  リリース %s: 相棒が確認した PR に `%s` ラベルと指示のコメントを付けたときだけ、マージと本番の操作をする。"
                  " 手順は %s/release/手順.md。起動は ~/.claude/brain-kit/bin/start-%s") % (p["name"], label_of(cfg, r), b, p["id"]))
    print(M("  工程表（brain-kit Dashboard）: 相棒の skill の「工程表」節。~/.claude/brain-kit/dashboard/"))
    print(M("  続けて /setup で、足した人格の節（規準・手順・任せる範囲）を埋める"))


# ------------------------------------------------------------------ resolve
def cmd_resolve(args):
    if not args.target:
        die(M("--resolve に対象のファイルが要る"), 2)
    if args.keep and args.from_file:
        die(M("--keep と --from は一緒に使えない"), 2)
    target = os.path.abspath(os.path.expanduser(args.target))
    cman = load_json(CLAUDE_MANIFEST, {}) or {}
    cfg, _, _, legacy = resolve_config(args, cman)
    if cfg is None:
        die(M("brain-kit が入っていない。先に install か --update を実行する"), 2)
    if legacy:
        # 版の記録が無い入れ方で一部だけ記録すると、次の更新が kit の skill を持ち主のものと取り違える
        die(M("版の記録が無い（v1〜v9 の入れ方）。先に --update で記録を作ってから --resolve する"), 2)
    manifests = load_manifests(cfg["brain"])
    # macOS の /var → /private/var のように、cwd と HOME でディレクトリの書き方が違っても見つける。
    # ファイル名の symlink はたどらない（別のファイルを kit のファイルとして扱わない）
    def same(a, b):
        return (os.path.realpath(os.path.dirname(a)), os.path.basename(a)) == \
            (os.path.realpath(os.path.dirname(b)), os.path.basename(b))
    settings_path = os.path.join(CLAUDE, "settings.json")
    settings = same(target, settings_path)
    if settings:
        target = settings_path
    it = None
    if settings:
        if os.path.islink(target) and args.from_file:
            # dotfiles などで symlink にしている人もいるので、書かない形（その場で直す・--keep）は受け付ける
            die(M("settings.json は symlink。--from では書かない。指す先をその場で直して --resolve <file> か --keep を使う"), 2)
        if not os.path.isfile(target):
            die(M("settings.json が無い。--resolve は今ある settings.json の衝突だけを扱う（作り直すなら --update）"), 2)
        sett = plan_settings(args.codex, manifests["claude"])
        current = sett["raw"]
        pending = {tuple(e) for e in manifests["claude"].get("settings_conflicts", [])}
        if not sett["conflict"] and not pending and not args.from_file:
            die(M("settings.json に衝突は無い"), 2)
    else:
        items = build_plan(cfg, manifests, legacy, load_fingerprints() if legacy else {}, mode="update")
        it = next((i for i in items if i.kind == "kit" and same(i.dst, target)), None)
        if it is None:
            die(M("kit のファイルではない。持ち主のファイルは kit では解消しない: %s") % tilde(target), 2)
        if it.state in ("add", "dropped", "collision") or not (
                it.state == "conflict" or os.path.exists(target + ".new")):
            die(M("衝突ではない: %s") % tilde(target), 2)
        if os.path.exists(target + ".new") and read_text(target + ".new") != it.new:
            die(M(".new が今の kit と違う版。先に --update を実行する"), 2)
        if os.path.islink(it.dst):
            die(M("%s は symlink。指す先は kit のものではないので、--resolve では書かない") % tilde(it.dst), 2)
        current = it.cur
        target = it.dst
    result = read_text(os.path.abspath(os.path.expanduser(args.from_file))) if args.from_file else current
    if result is None:
        die(M("解消結果を UTF-8 で読めない"), 2)
    if not args.keep and re.search(r"^(<<<<<<< |>>>>>>> )", result, re.M):
        die(M("解消結果に衝突マーカーが残っている"), 2)
    if settings:
        # 書く前の衝突も残しておき、--from で一致した項目も受け入れた版を記録する。
        after = plan_settings(args.codex, manifests["claude"], text=result)
        record = manifests["claude"].setdefault("settings", {})
        # 更新が覚えた衝突も含める（持ち主が項目を手で消すと、今の計画では「足す」に見えるため）
        entries = pending | {tuple(c["entry"]) for c in sett["conflict"] + after["conflict"]}
        # --from で変えた・消した kit の項目も、持ち主が決めたものとして記録する（次の更新で戻さない）
        before_obj, result_obj = json.loads(current or "{}"), json.loads(result)
        recorded = [(part, "") if part == "statusLine" else (part, key)
                    for part, values in record.items() for key in ([""] if part == "statusLine" else values)]
        entries |= {e for e in list(after["theirs"]) + recorded
                    if settings_get(before_obj, e) != settings_get(result_obj, e)}
        manifests["claude"].pop("settings_conflicts", None)
        for part, key in sorted(entries):
            value = after["theirs"].get((part, key))
            if (part, key) in after["theirs"]:
                if part == "statusLine":
                    record[part] = settings_sha(value)
                else:
                    record.setdefault(part, {})[key] = settings_sha(value)
            elif part == "statusLine":
                record.pop(part, None)
            elif part in record:
                record[part].pop(key, None)
                if not record[part]:
                    record.pop(part)
        mp = CLAUDE_MANIFEST
        manifest = manifests["claude"]
        detail = M("settings.json の衝突項目だけ kit の sha を記録する（廃止項目は記録を外す）")
    else:
        where, key = manifest_key(target, cfg)
        manifest = manifests[where]
        manifest.setdefault("files", {})[key] = {"sha": sha(it.new), "merged": sha(result)}
        mp = brain_manifest_path(cfg["brain"]) if where == "brain" else CLAUDE_MANIFEST
        detail = M("base と sha に kit の版、merged に解消結果の sha を記録する")
    print(M("解消%s: %s") % (M("（--dry-run）") if args.dry_run else "", tilde(target)))
    if args.dry_run:
        sys.stdout.write(diff_text(current, result, target))
    print("  " + detail)
    if it and os.path.exists(target + ".new"):
        print(M("  .new を退避して消す: %s.new") % tilde(target))
    if args.dry_run:
        print(M("--dry-run なので何も変えていない。退避も作らない。"))
        return
    backup = Backup("resolve", {"brain": cfg["brain"], "from": VERSION, "to": VERSION, "target": target})
    if result != current:
        put(target, result, backup, it.exe if it else False)
    if it:
        if os.path.exists(target + ".new"):
            backup.save(target + ".new")
            os.remove(target + ".new")
        if read_text(base_path(target, cfg)) != it.new:
            put(base_path(target, cfg), it.new, backup)
    if read_text(mp) != dump_json(manifest):
        put(mp, dump_json(manifest), backup)
    if not backup.opened:
        backup.save(mp)  # 同じ内容の --from でも、この解消を先に戻せるようにする。
    # 今の内容をそのまま結果にしたときも、受け入れた中身を記録と一緒にコミットする
    touched = list(backup.meta["overwritten"]) + list(backup.meta["added"]) + [target]
    commit_brain(cfg, touched, M("brain-kit: 更新の衝突を解消"))
    bdir = backup.close()
    print(M("解消した: %s%s") % (tilde(target), M("（今の内容を保った）") if result == current else ""))
    if bdir:
        print(M("退避: %s（--rollback でこの解消を戻せる）") % tilde(bdir))


# ------------------------------------------------------------------ uninstall（機械側の記録だけを使う）
def plan_uninstall(args):
    """何を消す・残すかを決める（何も書かない）。確認のあとにもう一度呼び、同じ計画になるかを比べる。"""
    # HOME に // が混ざっても（macOS の TMPDIR は / で終わる）比べられるように、正規化した形だけを使う
    claude, claude_manifest, kit_state = (os.path.abspath(p) for p in (CLAUDE, CLAUDE_MANIFEST, KIT_STATE))
    brain = os.path.abspath(os.path.expanduser(args.brain))
    manifest = load_json(claude_manifest, {}) or {}
    if not manifest.get("files"):
        die(M("kit の記録が無い（v1〜v9 の導入か、未導入）。先に --update で記録を作る"))
    cfg = load_json(config_path(brain))
    protected = [brain]
    if cfg:
        protected.append(cfg["brain"])
        protected.extend(worktree_of(cfg, r) for r in WORKTREE_ROLES if r in cfg["personas"])
    protected = [os.path.abspath(p) for p in protected]
    settings_path = os.path.join(claude, "settings.json")
    base = os.path.join(kit_state, "base")
    conflicts = os.path.join(kit_state, "conflicts")
    remove, keep, unsafe = set(), set(), set()

    def inside(path, directory):
        return path == directory or path.startswith(directory + os.sep)

    def safe(path):
        parent = os.path.realpath(os.path.dirname(path))
        real = os.path.realpath(path)
        return (path.startswith(claude + os.sep) and
                inside(parent, os.path.realpath(claude)) and not os.path.islink(path) and
                not any(p.startswith("backup-brain-kit-") for p in
                        os.path.relpath(path, claude).split(os.sep) +
                        os.path.relpath(real, os.path.realpath(claude)).split(os.sep)) and
                not any(inside(path, p) or inside(real, os.path.realpath(p)) for p in protected))

    rendered, expected = {}, {}
    if cfg:
        rendered = {os.path.abspath(dst): (src, flags) for src, dst, flags in load_kitfiles(cfg)}
    for key, ent in manifest["files"].items():
        path = os.path.abspath(os.path.join(HOME, key))
        if not safe(path) or path in (settings_path, claude_manifest) or inside(path, conflicts):
            unsafe.add(path)
            continue
        if os.path.lexists(path):
            if os.path.isfile(path) and sha(open_bytes(path)) == ent.get("sha"):
                remove.add(path)
                expected[path] = ent.get("sha")
            else:
                keep.add(path)
        new = path + ".new"
        if os.path.lexists(new):
            if not safe(new):
                unsafe.add(new)
            elif os.path.isfile(new) and path in rendered and open_bytes(new) == as_bytes(
                    source_text(rendered[path][0], cfg, rendered[path][1])):
                remove.add(new)
                expected[new] = sha(open_bytes(new))
            else:
                keep.add(new)

    # base は kit の原文。symlink はたどらず、その他の状態や衝突資料は残す。
    other = set()
    directories = set()
    for root, dirs, files in os.walk(kit_state, followlinks=False):
        dirs.sort()
        for name in files + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
            path = os.path.join(root, name)
            if path == claude_manifest or path in remove or path in keep or path in unsafe:
                continue
            # base は記録のある kit のファイルの原文だけを消す（記録の sha と一致するもの）。ほかは残す
            ent = manifest["files"].get(os.path.relpath(path, base)) if inside(path, base) else None
            if ent and safe(path) and os.path.isfile(path) and sha(open_bytes(path)) == ent.get("sha"):
                remove.add(path)
                expected[path] = ent.get("sha")
            else:
                other.add(path)
        if inside(root, base) and safe(root):
            directories.add(root)
    # manifest 自体が symlink なら参照先も記録もそのまま残す。
    if safe(claude_manifest) and os.path.isfile(claude_manifest):
        remove.add(claude_manifest)
        expected[claude_manifest] = sha(open_bytes(claude_manifest))
    else:
        unsafe.add(claude_manifest)

    cur, settings_raw = {}, None
    if os.path.lexists(settings_path):
        try:
            settings_raw = open_bytes(settings_path)
            cur = json.loads(settings_raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as e:
            die(M("settings.json が JSON として読めない: %s") % e)
        if not isinstance(cur, dict):
            die(M("settings.json は JSON オブジェクトにする"))
    pending = {tuple(e) for e in manifest.get("settings_conflicts", [])}
    settings_remove, settings_keep = [], []
    for part, values in manifest.get("settings", {}).items():
        if part != "statusLine" and part not in ("enabledPlugins", "extraKnownMarketplaces") and not part.startswith("hooks."):
            continue
        entries = [("", values)] if part == "statusLine" else values.items()
        for key, recorded in entries:
            entry = (part, key)
            old = settings_get(cur, entry)
            if old is None:
                continue
            if settings_sha(old) != recorded or entry in pending:
                settings_keep.append(settings_name(entry))
                continue
            settings_remove.append(settings_name(entry))
            if part.startswith("hooks."):
                event = part[6:]
                groups = cur["hooks"][event]
                groups.remove(old)
                if not groups:
                    del cur["hooks"][event]
                if not cur["hooks"]:
                    del cur["hooks"]
            elif part == "statusLine":
                del cur[part]
            else:
                del cur[part][key]
                if not cur[part]:
                    del cur[part]
    settings_writable = safe(settings_path)
    # 外したあとも settings.json に残るフック・statusLine（持ち主が変えた kit の項目・衝突待ち・持ち主が足したもの）が
    # 呼ぶ kit のファイルは消さない。消すと、残したフックが無いファイルを呼び続ける。
    # command の文字列に、そのファイルのパス（絶対パス・~/・$HOME/・${HOME}/ の形）が含まれていれば「使う」とみなす。
    remaining = cur if settings_writable else (json.loads(settings_raw.decode("utf-8")) if settings_raw else {})
    commands = []
    for event, groups in (remaining.get("hooks") or {}).items():
        for group in groups if isinstance(groups, list) else []:
            for hook in (group.get("hooks") or []) if isinstance(group, dict) else []:
                if isinstance(hook, dict) and isinstance(hook.get("command"), str):
                    commands.append(("hooks." + event, hook["command"]))
    status = remaining.get("statusLine")
    if isinstance(status, dict) and isinstance(status.get("command"), str):
        commands.append(("statusLine", status["command"]))
    used = {}

    def forms(path):
        out = {path}
        for home in {HOME, os.path.abspath(HOME)}:
            if path.startswith(os.path.abspath(home) + os.sep):
                rel = os.path.relpath(path, os.path.abspath(home))
                out.update([os.path.join(home, rel), "~/" + rel, "$HOME/" + rel, "${HOME}/" + rel])
        return out

    candidates = sorted((remove | keep) - {claude_manifest})   # 記録のある kit のファイル（変えたものも）

    def mark(path, why):
        if path in remove:
            used[path] = why
            remove.discard(path)

    # 辿るときは ~/.claude の中の symlink もたどる（消すかどうかの safe() とは別。読むだけ）。
    # 指す先が記録のある kit のファイルなら、その記録のパスとして残す
    real_claude = os.path.realpath(claude)
    by_real = {}
    for c in candidates:
        by_real.setdefault(os.path.realpath(c), []).append(c)

    def canonical(path):
        """path が指すもの。記録のある kit のファイルなら、同じ実体を指す記録のパスを全部（symlink の別名も）"""
        real = os.path.realpath(path)
        # Machine metadata is optional: retained kit hooks fall back to Japanese without it.
        # It is removed on uninstall, and is not an executable dependency to traverse.
        if real == os.path.realpath(claude_manifest):
            return []
        if real in by_real:
            return by_real[real]
        if real.startswith(real_claude + os.sep) and os.path.isfile(real):
            return [real]
        return []

    def named_files(text, heres=()):
        """text に書かれた ~/.claude の中のファイル。(書かれた形のパス, 指す先の一覧) を返す。
        絶対・~/・$HOME/・${HOME}/ の形と、heres（読んだファイルが置かれたディレクトリ。symlink の別名の側も）
        からの相対パス・同じディレクトリのファイル名。持ち主のスクリプトも辿るため（残す側に倒す）"""
        out = {}
        args = re.split(r"[\s'\"`;|&()<>=,]+", text)
        # 引用符の中（空白を含むパス）と、\ で逃がした空白も 1 つの引数として見る
        args += [a or b for a, b in re.findall(r'"([^"\n]*)"|\'([^\'\n]*)\'', text)]
        for line in text.splitlines():
            if len(line) > 4096:           # shlex は 1 文字ずつ組み立てるので、長い行（データ）は上の分け方だけにする
                continue
            try:
                args += shlex.split(line, comments=True)
                # ; | & ( ) < > をパスから切り離す（my\ hook.sh; echo のような形）
                lex = shlex.shlex(line, posix=True, punctuation_chars=True)
                lex.whitespace_split = True
                args += list(lex)
            except ValueError:
                pass
        found = []
        for arg in args:
            for prefix in ("${HOME}/", "$HOME/", "~/"):
                if arg.startswith(prefix):
                    arg = os.path.join(HOME, arg[len(prefix):])
            if arg.startswith(os.sep):
                found.append(arg)
            elif "/" in arg:
                found.extend(os.path.join(here, arg) for here in heres)
        for here in heres:
            if os.path.isdir(here):
                found.extend(os.path.join(here, name) for name in sorted(os.listdir(here)) if name in text)
        for path in found:
            # .. を先に畳まない（link/../bin は link の指す先の親の bin）。中かどうかは実体で見る（canonical）
            if os.path.isabs(path) and canonical(path):
                out.setdefault(path, canonical(path))
        for path in candidates:
            if any(f in text for f in forms(path)):
                out.setdefault(path, canonical(path) or [path])
        return sorted(out.items())

    # 起点：残る command に書かれた ~/.claude の中のファイル（kit のものも持ち主のスクリプトも）。
    # そこから、読んだファイルに書かれたファイルを何段でも辿る（session-end-brain.sh → "$HOOK_DIR/brain-digest.js"、
    # 持ち主のフック → 持ち主の補助スクリプト → kit のファイル）。相対パスと同じディレクトリのファイル名は、
    # 書かれた形（symlink の別名）のディレクトリと実体のディレクトリの両方から探す。
    # 同じ実体を同じディレクトリから見たら飛ばす。先頭 1 MiB だけ読む
    queue = []

    def traversed_dirs(path):
        """path を 1 段ずつたどるときに通るディレクトリ（実体）。symlink は指す先を展開してから続け、.. の前に通る
        ディレクトリも数える（link → dashboard/../bin なら dashboard も）。最後のファイルそのものは入れない"""
        out, cur, hops = set(), os.sep, 0
        stack = list(reversed(path.split(os.sep)))
        while stack:
            part = stack.pop()
            if part in ("", "."):
                continue
            if part == "..":
                cur = os.path.dirname(cur) or os.sep
                continue
            nxt = os.path.join(cur, part)
            if os.path.islink(nxt) and hops < 40:
                hops += 1
                target = os.readlink(nxt)
                if os.path.isabs(target):
                    cur = os.sep
                stack.extend(reversed(target.split(os.sep)))
                continue
            if stack and os.path.isdir(nxt):
                out.add(nxt)
            cur = nxt
        return out

    needed_dirs = set()   # 残すものに辿り着くのに要るディレクトリ（symlink の指す先も）。空になっても消さない

    def found(items, why):
        for written, targets in items:
            needed_dirs.update(traversed_dirs(written))
            for target in targets:
                mark(target, why)
                dirs = {os.path.dirname(written), os.path.dirname(os.path.realpath(written)),
                        os.path.dirname(target)}
                queue.append((target, dirs))

    for part, command in commands:
        found(named_files(command), part)
    seen = set()
    limit = 1024 * 1024
    while queue:
        user, dirs = queue.pop(0)
        real = os.path.realpath(user)
        # 同じディレクトリかは実体で比べる（hooks/. と hooks/./. を別にしない）。探すときは書かれた形を使う
        fresh = {}
        for d in sorted(dirs):
            key = (real, os.path.realpath(d))
            if key not in seen and key[1] not in {os.path.realpath(x) for x in fresh}:
                fresh[d] = key
        dirs = set(fresh)
        if not dirs or user.endswith((".log", ".jsonl")):   # 動いているセッションが書き足すログは辿らない
            continue
        seen.update(fresh.values())
        # UTF-8 でなくても ASCII のパスは拾えるように、読めない文字だけ置き換える
        try:
            with open(user, "rb") as f:
                text = f.read(limit).decode("utf-8", "replace")
        except (IOError, OSError) as e:
            die(M("残すフックが使う %s を読めない（%s）。何が要るか調べられないので何も変えない。"
                "読めるようにするか、そのフックを外してから --uninstall を実行する") % (tilde(user), e.strerror or e), 1)
        # 自分自身を別名で呼ぶものも積む（別名のディレクトリから見た相対を探すため。同じ組は seen が飛ばす）
        found(named_files(text, sorted(dirs)), M("%s から") % os.path.basename(user))
    return dict(claude=claude, kit_state=kit_state, claude_manifest=claude_manifest, brain=brain, cfg=cfg,
                settings_path=settings_path, conflicts=conflicts, safe=safe, remove=remove, keep=keep,
                unsafe=unsafe, other=other, directories=directories, expected=expected, used=used, cur=cur,
                needed_dirs=needed_dirs,
                settings_raw=settings_raw, settings_writable=settings_writable,
                settings_remove=settings_remove, settings_keep=settings_keep)


def plan_signature(p):
    """確認の前と後で比べるもの。消すもの（と中身の sha）・残すもの・settings の元のバイトと外す項目"""
    return (sorted(p["remove"]), sorted(p["expected"].items()), sorted(p["keep"]), sorted(p["used"]),
            sorted(p["unsafe"]), sorted(p["other"]), p["settings_raw"], p["settings_writable"],
            p["settings_remove"], p["settings_keep"], sorted(p["needed_dirs"]))


def cmd_uninstall(args):
    P = plan_uninstall(args)
    claude, kit_state, claude_manifest = P["claude"], P["kit_state"], P["claude_manifest"]
    brain, cfg, settings_path, conflicts, safe = P["brain"], P["cfg"], P["settings_path"], P["conflicts"], P["safe"]
    remove, keep, unsafe, other, directories = P["remove"], P["keep"], P["unsafe"], P["other"], P["directories"]
    expected, used, cur, settings_raw = P["expected"], P["used"], P["cur"], P["settings_raw"]
    settings_writable, settings_remove, settings_keep = P["settings_writable"], P["settings_remove"], P["settings_keep"]
    untouched = [tilde(brain) + M("（.brain-kit・kit のファイルも含む全部）")]
    if cfg:
        untouched.extend(tilde(worktree_of(cfg, r)) for r in WORKTREE_ROLES if r in cfg["personas"])
    untouched.extend([M("GitHub のラベル"), "Codex CLI", M("~/.claude/backup-brain-kit-*（既存の退避）")])
    if os.path.lexists(conflicts):
        untouched.append(tilde(conflicts) + M("（持ち主のマージ結果を含むことがある）"))
    untouched.extend(tilde(p) for p in sorted(other))

    def show(title, rows):
        say(M("%s: %d 件") % (title, len(rows)))
        for row in rows:
            print("  " + row)

    show(M("消すもの"), [tilde(p) for p in sorted(remove)])
    show(M("残すもの（持ち主が変えた）"), [tilde(p) for p in sorted(keep)])
    show(M("残すもの（残すフックが使うため）"), [M("%s（%s）") % (tilde(p), used[p]) for p in sorted(used)])
    print(M("  持ち主が変えた kit のファイル（残す）。.new も今の kit と一致しなければ残す。"))
    show(M("settings.json から外す項目") + (M("（手動）") if not settings_writable else ""), settings_remove)
    if not settings_writable:
        print(M("  settings.json は symlink などのため書かない。上の項目は手で外す。"))
    show(M("settings.json に残す項目"), settings_keep)
    print(M("  permissions と記録にない項目は持ち主のものとして残す。"))
    show(M("触らないもの"), untouched)
    print(M("  その他の kit 状態: %d 件（残す）") % len(other))
    show(M("触らない（記録が ~/.claude の外・symlink など）"), [tilde(p) for p in sorted(unsafe)])
    if args.dry_run:
        print(M("--dry-run なので何も変えていない。退避も作らない。"))
        return
    if not args.yes:
        if not interactive(args):
            die(M("実行には --yes が要る。先に --dry-run で確認できる"), 2)
        if ask(M("実行する？ [y/N]"), args=args).lower() not in ("y", "yes"):
            print(M("中止した。何も変えていない。"))
            return
    # 確認のあとで計画を作り直し、見せた計画と同じかを比べる。settings.json・残すフックが使うスクリプト
    # （新しく作られたものも）・消すものの中身が、確認の間に変わっていたら古い計画で消さない（何も変えずに止める）
    again = plan_uninstall(args)
    if plan_signature(again) != plan_signature(P):
        if again["settings_raw"] != settings_raw or again["settings_writable"] != settings_writable:
            die(M("確認の間に settings.json が変わった。何も変えていない。もう一度 --uninstall を実行する"), 1)
        die(M("確認の間に、消すもの・残すフックが使うものが変わった。何も変えていない。もう一度 --uninstall を実行する"), 1)

    def unchanged(path):
        # 消す直前にもう一度、~/.claude の中（親の symlink をたどった先も）・symlink でない・中身が計画のときと同じ、を確かめる
        return (safe(path) and os.path.isfile(path) and not os.path.islink(path) and
                sha(open_bytes(path)) == expected.get(path))

    backup = Backup("uninstall", {"brain": brain, "from": VERSION, "to": None})
    backup.meta.update(removed=[], written={})

    def drop(path):
        if not unchanged(path):
            remove.discard(path)
            keep.add(path)
            print(M("  残す（確認の間に変わった）: %s") % tilde(path))
            return
        backup.save(path)
        backup.meta["removed"].append(path)
        backup._journal()
        os.remove(path)
        directories.add(os.path.dirname(path))

    if settings_remove and settings_writable:
        # settings.json を先に書く。退避してから書く直前にもう一度確かめ、隣の一時ファイルから置き換える
        # （途中で落ちても元のバイトか書き終えた版のどちらかが残る。権限は元のまま）
        text = json.dumps(cur, ensure_ascii=False, indent=2) + "\n"
        backup.save(settings_path)
        if open_bytes(settings_path) != settings_raw or not safe(settings_path):
            # 何も変えていない退避なので、--rollback の対象にしない（持ち主の新しい settings.json を古い版で戻さない）
            backup.meta.update(rolled_back=True, aborted=True)
            backup._journal()
            die(M("書く直前に settings.json が変わった。何も変えていない（--rollback は要らない）"), 1)
        backup.meta["written"][settings_path] = sha(text)
        backup._journal()
        fd, tmp = tempfile.mkstemp(prefix=".settings.json.", dir=claude)
        try:
            with io.open(fd, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, os.stat(settings_path).st_mode & 0o7777)
            os.replace(tmp, settings_path)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    for path in sorted(remove - {claude_manifest}):
        drop(path)
    if claude_manifest in remove:
        drop(claude_manifest)
        directories.add(kit_state)
    stops = {claude} | {os.path.join(claude, p) for p in ("skills", "hooks", "agents")}
    for directory in sorted(directories, key=len, reverse=True):
        # 残すフックがたどるディレクトリ（symlink の指す先も）は、空になっても消さない
        while directory not in stops and safe(directory) and os.path.realpath(directory) not in P["needed_dirs"]:
            try:
                os.rmdir(directory)
            except OSError:
                break
            directory = os.path.dirname(directory)
    bdir = backup.close()
    print(M("消したファイル: %d 件、残したファイル: %d 件。settings: 外した %d 件、残した %d 件。") % (
        len(remove), len(keep | other | unsafe | set(used)), len(settings_remove) if settings_writable else 0,
        len(settings_keep) + (len(settings_remove) if not settings_writable else 0)))
    if bdir:
        print(M("退避: %s（--rollback で戻せる。要らなくなったら手で消す）") % tilde(bdir))
    print(M("brain/.brain-kit/config.json は残っている。./install.sh --update で ~/.claude 側を入れ直せる。"))


# ------------------------------------------------------------------ rollback
def restore_atomic(src, path):
    """退避から戻す。隣の一時ファイルに写して fsync してから置き換える（途中で落ちても戻す前の中身が残り、もう一度戻せる）。
    symlink は今までどおり指す先に戻す。"""
    dst = os.path.realpath(path) if os.path.islink(path) else path
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(dst) + ".", dir=os.path.dirname(dst))
    os.close(fd)
    try:
        shutil.copy2(src, tmp)
        with open(tmp, "rb") as f:            # 読み取り専用（0444 など）の退避でも開ける形で fsync する
            os.fsync(f.fileno())
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def backup_order(meta, directory):
    """新しいほど大きい。通し番号のある退避は番号の無い退避より新しい扱い（cmd_rollback が legacy_before で確かめる）。"""
    stamp = meta.get("stamp", "")
    created = meta.get("created")
    if not isinstance(stamp, str) or not (created is None or isinstance(created, str)):
        raise TypeError("stamp / created")
    suffix = directory[len("backup-brain-kit-" + stamp):].lstrip("-")
    suffix = int(suffix) if suffix.isdigit() else 1
    if not created:
        created = datetime.datetime.strptime(stamp, "%Y%m%d-%H%M%S").isoformat(timespec="microseconds")
    seq = backup_seq(meta)
    if seq:
        return 1, seq, created, suffix
    return 0, 0, created, suffix


def cmd_rollback(args):
    cands = []
    if os.path.isdir(CLAUDE):
        for d in sorted(os.listdir(CLAUDE)):
            if d.startswith("backup-brain-kit-"):
                path = os.path.join(CLAUDE, d, "meta.json")
                m, why = read_backup_meta(d)
                if m is None and why is None:
                    continue   # meta は書き換えの前に書くので、meta の無い退避は何も書き換えていない
                if why:
                    pass
                elif not isinstance(m.get("rolled_back", False), bool):
                    why = M("rolled_back が true / false でない")
                elif m.get("rolled_back"):
                    continue
                elif "seq" in m and not (backup_seq(m) and isinstance(m.get("legacy_before"), dict)):
                    why = M("seq か legacy_before が不正")
                else:
                    try:
                        order = backup_order(m, d)
                    except (TypeError, ValueError):
                        why = M("stamp か created が不正")
                if why:
                    die(M("退避の記録が壊れている（%s）: %s。どれから戻すか決められないので何も変えない。"
                          "各退避の files/ と meta.json を見て、どれが新しいかを確かめてから手で戻す") % (why, tilde(path)), 1)
                cands.append((order, d, m))
    if not cands:
        die(M("戻せる更新が無い（~/.claude/backup-brain-kit-*/meta.json が無いか、戻し済み）"), 1)
    seqs = [backup_seq(c[2]) for c in cands if backup_seq(c[2])]
    if len(seqs) != len(set(seqs)):
        die(M("退避の記録が壊れている（戻していない退避に同じ seq がある）。どれから戻すか決められないので何も変えない"), 1)
    cands.sort()
    stamp, d, meta = cands[-1]
    if backup_seq(meta):
        # 番号の無い退避が、この退避を作ったときに無かったか、そのあとに書き足されている
        # ＝古い版の kit があとで・同時に動いた。どちらが新しいか決められない
        later = [c[1] for c in cands if "seq" not in c[2] and
                 meta["legacy_before"].get(c[1]) != meta_sha(os.path.join(CLAUDE, c[1]))]
        if later:
            die(M("番号の無い退避 %s が %s のあとに作られたか書き足されている（古い版の kit で更新した？）。"
                  "どれから戻すか決められないので何も変えない。時計に頼る順（古い版の kit の --rollback も）は誤りうるので、"
                  "各退避の files/ と meta.json を見て、どれが新しいかを確かめてから手で戻す") % (", ".join(later), d), 1)
    bdir = os.path.join(CLAUDE, d)
    target = "uninstall" if meta.get("kind") == "uninstall" else "v%s" % meta.get("to")
    say(M("戻す: %s（%s、v%s → %s）%s") % (tilde(bdir), meta.get("kind"), meta.get("from"), target,
                                        M("（--dry-run: 何も変えない）") if args.dry_run else ""))
    restored, removed, left = [], [], []
    gone = set(meta.get("removed", []))
    written = meta.get("written", {})
    for path in meta.get("overwritten", []):
        # uninstall で外したものは、今も無いときだけ戻す。書いた settings.json は書いたときのままのときだけ戻す。
        # 外したあとに持ち主が作り直したもの・書き換えたもの・symlink に差し替えたものは上書きしない
        if path in gone:
            parent = os.path.realpath(os.path.dirname(path))
            if os.path.lexists(path) or not (parent == os.path.realpath(CLAUDE) or
                                             parent.startswith(os.path.realpath(CLAUDE) + os.sep)):
                left.append(path)
                continue
        elif path in written:
            if os.path.islink(path) or not os.path.isfile(path) or sha(open_bytes(path)) != written[path]:
                left.append(path)
                continue
        elif meta.get("kind") == "uninstall":
            # 退避したあと、消す・書く前に止まったもの（記録が書けなかったなど）。今の中身が持ち主のものなので戻さない
            left.append(path)
            continue
        restored.append(path)
    for path, h in meta.get("added", {}).items():
        cur = None
        if os.path.exists(path):
            with open(path, "rb") as f:
                cur = sha(f.read())
        if cur is None:
            continue
        (removed if cur == h else left).append(path)
    for p in restored:
        print(M("  戻す: %s") % tilde(p))
    for p in removed:
        print(M("  消す（更新で足したもの）: %s") % tilde(p))
    for p in left:
        print(M("  残す（%sあとに書き換えられている・作られている）: %s") % (M("外した") if gone or written else M("足した"), tilde(p)))
    for w in meta.get("worktrees", []):
        print(M("  worktree を外す: %s（中身に変更があれば残す）") % tilde(w["path"]))
    if args.dry_run:
        return
    for path in restored:
        src = os.path.join(bdir, "files", path.lstrip(os.sep))
        if not os.path.isdir(os.path.dirname(path)):
            os.makedirs(os.path.dirname(path))
        restore_atomic(src, path)
    for path in removed:
        os.remove(path)
        d = os.path.dirname(path)
        while d not in (HOME, meta.get("brain")) and os.path.isdir(d) and not os.listdir(d):
            os.rmdir(d)
            d = os.path.dirname(d)
    brain = meta.get("brain")
    for w in reversed(meta.get("worktrees", [])):
        rc, _, err = run(["git", "-C", brain, "worktree", "remove", w["path"]])
        if rc != 0:
            print(M("  warn: worktree %s は外さなかった: %s") % (tilde(w["path"]), err.strip()))
            continue
        if w.get("new_branch"):
            if run(["git", "-C", brain, "branch", "-d", w["branch"]])[0] != 0:
                print(M("  warn: ブランチ %s は main に入っていない変更があるので残した") % w["branch"])
    if meta.get("kind") != "uninstall" and brain and os.path.isdir(brain):
        commit_brain({"brain": brain}, restored + removed, M("brain-kit: 更新を戻した（%s）") % d)
    meta["rolled_back"] = True
    meta["rolled_back_at"] = datetime.datetime.now().isoformat(timespec="seconds")
    write_atomic(os.path.join(bdir, "meta.json"), dump_json(meta))
    print(M("戻した: %d 件、消した: %d 件、残した: %d 件。ラベルは消さない（GitHub 側はそのまま）。") % (len(restored), len(removed), len(left)))


# ------------------------------------------------------------------ doctor
def w(s):
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s, n):
    return s + " " * max(0, n - w(s))


def is_empty_note(p):
    t = read_text(p)
    if t is None:
        return True
    t = re.sub(r"^---.*?---", "", t, count=1, flags=re.S)
    t = re.sub(r"<!--.*?-->", "", t, flags=re.S)
    return not any(l.strip() and not l.lstrip().startswith("#") and not l.startswith(("持ち主:", "Owner:")) for l in t.splitlines())


def stalled_line(stalled):
    """collect.py の 1 行の要約を表示の言語で。日本語は collect.py の行をそのまま使う（同じバイト）。"""
    if _LANG == "ja":
        return stalled["line"]
    groups = []
    for kind, label in (("issue", M("作業中の issue")), ("pr", M("レビュー済みで未リリースの PR")),
                        ("session", M("止まったセッション"))):
        refs = []
        for it in stalled["items"]:
            if it["kind"] != kind:
                continue
            if kind == "session":
                refs.append(M("%s（%s、%s）") % (it["name"], M(ROLE_JA[it["role"]]),
                            M("記録なし") if it["idle_hours"] is None else M("%d 時間") % it["idle_hours"]))
            else:
                refs.append("%s#%s" % (it["repo"].split("/")[-1], it["number"]))
        if refs:
            groups.append(label + " " + M("・").join(refs[:5]) + (M("…ほか %d 件") % (len(refs) - 5) if len(refs) > 5 else ""))
    return M("止まっている（%s 時間以上動きなし）: %s") % (format(stalled["hours"], "g"), M("／").join(groups)) if groups else ""


def cmd_doctor(args):
    rows, todo = [], []

    def row(item, ok, detail="", status=None):
        rows.append((item, status or ("OK" if ok else M("無い")), detail))

    def first(cmd, timeout=8):
        rc, out, err = run(cmd, timeout=timeout)
        s = (out or err).strip().splitlines()
        return rc, s[0] if s else ""

    cman = load_json(CLAUDE_MANIFEST, {}) or {}
    cfg, v_from, desc, legacy = resolve_config(args, cman)
    brain = os.path.abspath(os.path.expanduser(args.brain))

    # 表示の言語（--lang）ではなく、記録された持ち主の言語を出す
    owner_lang = record_lang(cfg, cman)
    recorded = []
    for path, record in ((config_path(brain), load_json(config_path(brain))), (CLAUDE_MANIFEST, cman)):
        if isinstance(record, dict) and record.get("lang") in tuple(LANG_NAMES):
            recorded.append(tilde(path))
    row(M("  言語"), True, M("%s（%s）; 記録: %s") % (
        language_name(owner_lang), owner_lang, ", ".join(recorded) or M("未記録（既定 ja）")))
    rows.append((M("[版]"), "", ""))
    row(M("  kit（この手元）"), True, "v%d" % VERSION)
    if cfg is None:
        row("  brain", False, M("brain-kit が入っていない（%s）") % tilde(brain), M("要対応"))
        todo.append(M("./install.sh（新しく入れる）"))
    else:
        old = v_from != VERSION
        row("  brain", not old, desc, M("古い") if old else "OK")
        cv = cman.get("version")
        row("  ~/.claude", cv == VERSION, "v%s" % cv if cv else M("版の記録なし"), "OK" if cv == VERSION else M("古い"))
        if old or cv != VERSION:
            todo.append(M("./install.sh --update --dry-run で中身を見て、./install.sh --update"))

    if cfg:
        row("  start-all", os.path.isfile(os.path.join(KIT_STATE, "bin", "start-all")),
            "~/.claude/brain-kit/bin/start-all")
        rows.append((M("[人格]"), "", ""))
        for r in ROLES:
            if r not in cfg["personas"]:
                row("  %s" % M(ROLE_JA[r]), False, M("まだ居ない（--update で足す）"), M("無い"))
                continue
            p = persona(cfg, r)
            sk = os.path.isfile(os.path.join(CLAUDE, "skills", p["id"], "SKILL.md"))
            ar = os.path.isdir(os.path.join(brain, area_of(cfg, r)))
            wt = worktree_of(cfg, r)
            wt_ok = r == "partner" or os.path.isdir(wt)
            detail = M("skill /%s %s・領域 %s/ %s%s") % (p["id"], "○" if sk else "×", area_of(cfg, r), "○" if ar else "×",
                                                    "" if r == "partner" else M("・worktree %s %s") % (tilde(wt), "○" if wt_ok else "×"))
            row("  %s %s" % (M(ROLE_JA[r]), p["name"]), sk and ar and wt_ok, detail, None if sk and ar and wt_ok else M("要対応"))
        pcore = os.path.join(brain, persona(cfg, "partner")["name"], "00_核.md")
        if os.path.exists(pcore) and is_empty_note(pcore):
            row(M("  相棒の憲法"), False, M("00_核.md が空。/setup で埋める"), M("要対応"))
            todo.append("cd %s && claude → /setup" % tilde(brain))

        rows.append((M("[kit のファイル]"), "", ""))
        manifests = load_manifests(brain)
        items = build_plan(cfg, manifests, legacy, load_fingerprints() if legacy else {})
        kits = [i for i in items if i.kind == "kit"]
        cnt = {}
        for i in kits:
            cnt.setdefault(i.state, []).append(i)
        row(M("  最新"), True, M("%d 件") % len(cnt.get("same", [])))
        if cnt.get("upgrade"):
            row(M("  kit だけの更新待ち"), False, M("%d 件") % len(cnt["upgrade"]), M("更新待ち"))
        if cnt.get("add"):
            row(M("  足りない"), False, M("%d 件: %s") % (len(cnt["add"]), ", ".join(tilde(i.dst) for i in cnt["add"][:4])
                                                  + (" …" if len(cnt["add"]) > 4 else "")), M("要対応"))
        for i in cnt.get("owner", []):
            row(M("  持ち主だけが変更"), True, tilde(i.dst), M("持ち主の変更"))
        for i in cnt.get("conflict", []):
            row(M("  衝突"), False, tilde(i.dst), M("衝突"))
        for i in kits:
            if os.path.exists(i.dst + ".new"):
                row(M("  .new が残っている"), False, tilde(i.dst + ".new"), M("要確認"))
        if cnt.get("upgrade") or cnt.get("add"):
            if M("./install.sh --update --dry-run で中身を見て、./install.sh --update") not in todo:
                todo.append(M("./install.sh --update --dry-run で中身を見て、./install.sh --update"))
        own_missing = [i for i in items if i.kind == "owner" and i.state == "add"]
        if own_missing:
            row(M("  持ち主の領域の骨格"), False, M("無いもの %d 件（--update で足す）") % len(own_missing), M("要対応"))

    rows.append(("[brain]", "", tilde(brain)))
    if os.path.isdir(brain):
        rc, n = first(["git", "-C", brain, "rev-list", "--count", "HEAD"])
        if rc == 0:
            rc2, rem = first(["git", "-C", brain, "remote"])
            row("  git", True, M("コミット %s、remote %s") % (n, M("あり") if rem else M("無し")), "OK" if rem else M("要対応"))
            if not rem:
                todo.append(M("git -C %s remote add origin <private リポジトリ>") % tilde(brain))
            rc3, dirty = first(["git", "-C", brain, "status", "--porcelain"])
            if dirty:
                row(M("  未コミット"), False, M("brain に未コミットの変更がある"), M("要対応"))
        else:
            row("  git", False, M("リポジトリではない"), M("要対応"))
            todo.append("git -C %s init" % tilde(brain))
    else:
        row(M("  骨格"), False, M("brain が無い"), M("要対応"))

    rows.append(("[~/.claude]", "", tilde(CLAUDE)))
    for h in ["session-end-brain.sh", "brain-digest.js"]:
        p = os.path.join(CLAUDE, "hooks", h)
        row("  hooks/%s" % h, os.path.isfile(p), "" if not os.path.isfile(p) or os.access(p, os.X_OK) else M("実行権限なし"))
    sp = os.path.join(CLAUDE, "settings.json")
    st = load_json(sp)
    if st is None:
        row("  settings.json", False, M("無いか JSON として読めない"), M("要対応"))
    else:
        se = any("session-end-brain.sh" in (h.get("command") or "") for g in st.get("hooks", {}).get("SessionEnd", []) for h in g.get("hooks", []))
        row(M("  settings: SessionEnd フック"), se, M("daily/ への自動追記"))
        ep = st.get("enabledPlugins", {})
        row("  settings: plugin pr-review-toolkit", any(k.startswith("pr-review-toolkit") for k in ep))
        row("  settings: plugin codex", any(k.startswith("codex") for k in ep), M("任意（--codex）"), None if any(k.startswith("codex") for k in ep) else M("無い"))

    notice = "brain-kit-update-check.py"
    notice_hook = os.path.isfile(os.path.join(CLAUDE, "hooks", notice)) and any(
        notice in (h.get("command") or "")
        for g in (st or {}).get("hooks", {}).get("SessionStart", []) for h in g.get("hooks", []))
    notice_off = os.path.exists(os.path.join(KIT_STATE, "no-update-check"))
    cached = load_json(os.path.join(KIT_STATE, "update-check.json"))
    latest = cached.get("latest") if isinstance(cached, dict) else None
    row(M("  更新のお知らせ"), True, M("npm 公開版: %s（前回の確認）") % latest if latest else "",
        M("止めてある") if notice_off else M("有効") if notice_hook else M("フック無し"))

    reread = "brain-kit-core-reread.py"
    reread_hook = os.path.isfile(os.path.join(CLAUDE, "hooks", reread)) and any(
        reread in (h.get("command") or "")
        for g in (st or {}).get("hooks", {}).get("SessionStart", []) if g.get("matcher") == "compact"
        for h in g.get("hooks", []))
    reread_off = (os.environ.get("BRAIN_KIT_NO_CORE_REREAD") == "1" or
                  os.path.exists(os.path.join(KIT_STATE, "no-core-reread")))
    row("  要約のあとの核の読み直し", True, "",
        "止めてある" if reread_off else "有効" if reread_hook else "フック無し")

    rows.append(("[CLI]", "", ""))

    def cli(name, vercmd=None, optional=False):
        if not have(name):
            row("  " + name, False, M("任意") if optional else "", M("無い") if optional else M("要対応"))
            return False
        rc, v = first(vercmd) if vercmd else (0, "")
        row("  " + name, True, v[:40])
        return True
    if not have("claude"):
        row("  claude", False, status=M("要対応"))
        todo.append(M("Claude Code CLI を入れる"))
    else:
        result = run(["claude", "--version"], timeout=15)
        lines = (result[1] or result[2]).strip().splitlines()
        row("  claude", True, lines[0][:40] if lines else "")
        warning = claude_version_warning(result=result)
        status = M("要確認") if warning and M("版を読めない") in warning else M("古い") if warning else "OK"
        row(M("  Claude Code の版"), warning is None,
            warning[len("warn: "):] if warning else M("動作を確かめた版 %s 以上") % VERIFIED_CLAUDE_CODE, status)
        if status == M("古い"):
            todo.append(M("claude update（動作を確かめた版 %s より古い）") % VERIFIED_CLAUDE_CODE)
    cli("node", ["node", "--version"])
    cli("python3", ["python3", "--version"])
    gh_ok = False
    if cli("gh", ["gh", "--version"]):
        ok = run(["gh", "auth", "status"], timeout=15)[0] == 0
        gh_ok = ok
        row("  gh auth", ok, M("認証済み") if ok else M("未認証"), "OK" if ok else M("要対応"))
        if not ok:
            todo.append(M("gh auth login（ラベル・PR・工程表の集計に要る）"))
        elif cfg and cfg.get("repos"):
            for r in cfg["repos"]:
                rc, out, _ = run(["gh", "label", "list", "-R", r, "--limit", "200", "--json", "name", "--jq", ".[].name"], timeout=20)
                if rc != 0:
                    row(M("  ラベル %s") % r, False, M("読めない"), M("要対応"))
                    continue
                miss = [l for l in wanted_labels(cfg) if l not in set(out.splitlines())]
                row(M("  ラベル %s") % r, not miss, M("足りない: ") + " ".join(miss) if miss else M("揃っている"), None if not miss else M("要対応"))
    if cli("codex", ["codex", "--version"], optional=True):
        ok = run(["codex", "login", "status"], timeout=15)[0] == 0
        row("  codex login", ok, "" if ok else M("未ログインか確認不可"), "OK" if ok else M("要対応"))
    cli("tailscale", ["tailscale", "version"], optional=True)
    orca = shutil.which("orca-ide") or ("/opt/Orca/orca-ide" if os.access("/opt/Orca/orca-ide", os.X_OK) else None)
    row("  orca-ide", bool(orca), orca or M("任意（base のみ。setup-base.sh）"), None if orca else M("無い"))
    if have("orca"):
        rc, v = first(["orca", "automations", "list"], timeout=15)
        row("  orca automations", rc == 0, v[:40] if rc == 0 else M("一覧を取れない（serve が止まっているか、--environment が要る）"), None if rc == 0 else M("要対応"))

    if cfg:
        # 読み込みでも .pyc を作らない。診断はローカルにも書かない。
        before_bytecode = sys.dont_write_bytecode
        try:
            sys.dont_write_bytecode = True
            spec = importlib.util.spec_from_file_location("brain_kit_collect", os.path.join(KIT, "claude", "brain-kit", "dashboard", "collect.py"))
            collect = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(collect)
        except Exception:  # noqa: BLE001  集計が無い古い kit でも診断を続ける
            rows.append((M("[止まっている仕事]"), "", ""))
            row(M("  集計"), False, status=M("確かめられない"))
        else:
            hours = collect.stall_hours(cfg, args.stall_hours)
            rows.append((M("[止まっている仕事]"), "", M("%s 時間以上動きなし") % format(hours, "g")))
            repo_data = {}
            if not cfg.get("repos"):
                row("  GitHub", False, M("repos が無い"), M("飛ばした"))
            elif not have("gh"):
                row("  GitHub", False, M("gh が無い（issue・PR は見ない）"), M("飛ばした"))
            elif not gh_ok:
                row("  GitHub", False, M("gh が未認証"), M("飛ばした"))
            else:
                for repo in cfg["repos"]:
                    try:
                        repo_data[repo] = collect.fetch(repo, timeout=20)
                    except Exception:  # noqa: BLE001  通信できないときもローカルは見る
                        row("  GitHub " + repo, False, M("読めない（ネットワークか権限）"), M("飛ばした"))
            stalled = collect.find_stalled(cfg, brain, repo_data, hours)
            work_items = [it for it in stalled["items"] if it["kind"] != "session"]
            for it in work_items:
                row(M("  作業中の issue") if it["kind"] == "issue" else M("  レビュー済みで未リリースの PR"), False,
                    M("%s#%s %s（%d 時間）") % (it["repo"], it["number"], it["title"][:30], it["idle_hours"]), M("止まっている"))
            if repo_data and not work_items:
                row(M("  issue・PR"), True, M("なし"))
            sessions = {it["role"]: it for it in stalled["items"] if it["kind"] == "session"}
            for role in ROLES:
                if role not in cfg.get("personas", {}):
                    continue
                p = persona(cfg, role)
                at = collect.last_session(brain, p["id"], role)
                detail = M("最後 ") + at.astimezone().strftime("%Y-%m-%d %H:%M") if at else M("記録なし")
                status = M("参考")
                if role != "partner" and repo_data:
                    work = collect.waiting_work(cfg, repo_data, role)
                    status = M("止まっている") if role in sessions else "OK"
                    if role in sessions:
                        it = sessions[role]
                        if at:
                            detail += M("（%d 時間前）") % it["idle_hours"]
                        detail += M("・仕事 %d 件") % work
                    elif not work:
                        detail = M("仕事なし")
                row(M("  セッション ") + p["name"], status == "OK", detail, status)
            if stalled["line"]:
                todo.append(M("止まっている仕事を確かめる（%s）") % stalled_line(stalled))
        finally:
            sys.dont_write_bytecode = before_bytecode

    table = [(M("項目"), M("状態"), M("補足"))] + rows
    c0 = max(w(r[0]) for r in table)
    c1 = max(w(r[1]) for r in table)
    for item, status, detail in table:
        print((pad(item, c0) + "  " + pad(status, c1) + "  " + detail).rstrip())
    print()
    if todo:
        print(M("次にやること（未実施のものだけ）"))
        for i, t in enumerate(todo, 1):
            print("  %d. %s" % (i, t))
    else:
        print(M("次にやること: なし"))


# ------------------------------------------------------------------ 入口
def lock_home():
    """書き換える処理（install・update・resolve・uninstall・rollback）を、同じ HOME で 1 つずつにする。
    重なると退避の通し番号と退避する中身が食い違い、--rollback が持ち主のファイルを途中の状態で残しうる。
    ファイルは作らない（HOME のディレクトリそのものに flock する）。fd は開いたままにし、終了でロックが外れる。
    確かめられないときは書き換えずに止まる。"""
    try:
        import fcntl
    except ImportError:
        die(M("この環境では同時実行を防げない（fcntl が無い）。何も変えずに止める"), 1)
    try:
        fd = os.open(HOME, os.O_RDONLY)
    except OSError as e:
        die(M("同時実行を防ぐロックが取れない（%s を開けない: %s）。何も変えずに止める") % (HOME, e), 1)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
            die(M("別の brain-kit（install・--update・--resolve・--uninstall・--rollback）がこの HOME で動いている。終わってからもう一度"), 1)
        die(M("同時実行を防ぐロックが取れない（%s）。何も変えずに止める") % e, 1)
    return fd


def main(argv):
    ap = argparse.ArgumentParser(prog="kit.py")
    ap.add_argument("cmd", choices=["install", "update", "resolve", "uninstall", "rollback", "doctor", "detect"])
    ap.add_argument("--stall-hours", type=float, default=None)
    ap.add_argument("--lang", choices=["ja", "en"])
    ap.add_argument("--target")
    ap.add_argument("--from", dest="from_file")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--brain", default=os.environ.get("BRAIN_DIR") or os.path.join(HOME, "brain"))
    for r in ROLES:
        ap.add_argument("--" + r, default=None)
        ap.add_argument("--%s-id" % r, dest=r + "_id", default=None)
    ap.add_argument("--user", default=None)
    ap.add_argument("--projects", default=None)
    ap.add_argument("--repos", default=None)
    ap.add_argument("--brain-merge", action="store_true")
    ap.add_argument("--codex", action="store_true")
    ap.add_argument("--no-worktrees", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--edited", choices=["new", "keep"], default=None)
    ap.add_argument("--yes", "-y", action="store_true")
    args = ap.parse_args(argv)
    set_lang(args.lang or record_lang(load_json(config_path(os.path.abspath(os.path.expanduser(args.brain)))),
                                      load_json(CLAUDE_MANIFEST)))
    if args.cmd in ("install", "update", "resolve", "uninstall", "rollback"):
        lock_home()   # fd はプロセスが終わるまで開いたまま（終了でロックが外れる）
    if args.cmd == "install":
        cmd_install(args)
    elif args.cmd == "update":
        cmd_update(args)
    elif args.cmd == "resolve":
        cmd_resolve(args)
    elif args.cmd == "uninstall":
        cmd_uninstall(args)
    elif args.cmd == "rollback":
        cmd_rollback(args)
    elif args.cmd == "doctor":
        cmd_doctor(args)
    else:
        cfg, v, desc, legacy = resolve_config(args, load_json(CLAUDE_MANIFEST, {}) or {})
        print(desc)
        print(dump_json(cfg) if cfg else "")


if __name__ == "__main__":
    main(sys.argv[1:])
