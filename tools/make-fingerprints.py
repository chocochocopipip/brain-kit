#!/usr/bin/env python3
"""版の記録が無い古い入れ方（v1〜v9）を見分けるための指紋を作る（kit の開発者用。利用者は走らせない）。

  python3 tools/make-fingerprints.py > migrations/fingerprints.json

git の履歴から各版の「kit のファイル」を取り出し、1 行ずつの sha256（先頭 16 桁）だけを残す。
本文は残さない（古い版の言い回しを配布物に持ち込まないため）。
更新のとき lib/kit.py が、入っているファイルの各行を名前→<置き換えの印> に戻しながら指紋と突き合わせ、
全行が一致すれば「その版のまま＝手で直していない」とみなす。
"""
import hashlib, json, re, subprocess, sys

# 版 → コミット（このリポジトリの履歴。タグは無い）
VERSIONS = [
    (1, "a5cb3bd"), (2, "38fdc30"), (3, "ea9fba4"), (4, "3f2cd08"), (5, "917bc1e"),
    (6, "4be64ed"), (7, "6bfb444"), (8, "ed99c56"), (9, "bc98adc"),
]
# v1〜v9 が ~/.claude と brain に置いた「kit のファイル」
FILES = [
    "claude/CLAUDE.md",
    "claude/skills/partner/SKILL.md",
    "claude/skills/dev/SKILL.md",
    "claude/skills/setup/SKILL.md",
    "claude/skills/grilling/SKILL.md",
    "claude/hooks/session-end-brain.sh",
    "claude/hooks/brain-digest.js",
    "brain-template/CLAUDE.md",
    "brain-template/README.md",
    "brain-template/dev/README.md",
    "brain-template/dev/状況/_テンプレート.md",
]
MARKS = ["<相棒名>", "<開発担当名>", "<持ち主名>"]


def h(line):
    return hashlib.sha256(line.encode("utf-8")).hexdigest()[:16]


def norm(src, line):
    # skill の name: 行は install が書き換える。どの名前でも一致させる
    if src.startswith("claude/skills/") and re.match(r"^name: ", line):
        return "name: *"
    return line


def main():
    out = {}
    for src in FILES:
        seen = {}
        for ver, sha in VERSIONS:
            r = subprocess.run(["git", "show", "%s:%s" % (sha, src)], capture_output=True)
            if r.returncode != 0:
                continue
            text = r.stdout.decode("utf-8")
            lines = [h(norm(src, l)) for l in text.split("\n")]
            key = ",".join(lines)
            if key not in seen:
                seen[key] = {"versions": [], "marks": [t for t in MARKS if t in text], "lines": lines}
            seen[key]["versions"].append(ver)
        out[src] = list(seen.values())
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
