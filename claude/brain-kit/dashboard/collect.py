#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""工程表（brain-kit Dashboard）に載せる中身を GitHub から集める。書き込みは相棒がする（相棒の skill の「工程表」節）。

  python3 ~/.claude/brain-kit/dashboard/collect.py [--brain <dir>] [--days 1] [--out board.json]

リポジトリとラベルは brain の .brain-kit/config.json（install の --repos と 4 人の名前）から読む。
gh（認証済み）で読むだけ。何も書かない。出力は Artifact の db の board/current に置く 1 文書。

段の決め方（ラベルで。1 件は 1 つの段にだけ入る）:
  起票          open の issue で、下のどれにも当たらないもの
  判断待ち      open の issue で `question` か `needs-triage`（持ち主の番にも出る）
  開発          open の issue で、開発のラベル・`agent-ready`・`agent-working`
  PR            open の PR（レビュー中。下書きも含む）
  リリースの列  open の PR か issue で、リリースのラベル
  本番          --days 日以内にマージされた PR
"""
from __future__ import print_function

import argparse
import datetime
import io
import json
import os
import subprocess
import sys

STAGES = [
    ("filed", "起票"),
    ("decide", "判断待ち"),
    ("dev", "開発"),
    ("review", "PR（レビュー中）"),
    ("release", "リリースの列"),
    ("prod", "本番"),
]


def gh(args):
    r = subprocess.run(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError("gh %s: %s" % (" ".join(args[:3]), r.stderr.strip()[:200]))
    return json.loads(r.stdout or "[]")


def label_of(cfg, role):
    p = (cfg.get("personas") or {}).get(role) or {}
    return p.get("label") or p.get("id")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--brain", default=os.environ.get("BRAIN_DIR") or os.path.expanduser("~/brain"))
    ap.add_argument("--days", type=int, default=1, help="本番の列に何日前までのマージを出すか")
    ap.add_argument("--out", default="-")
    ap.add_argument("--repos", default=None, help="カンマ区切り。省略で config.json の repos")
    a = ap.parse_args()

    cfg = json.load(io.open(os.path.join(os.path.expanduser(a.brain), ".brain-kit", "config.json"), encoding="utf-8"))
    repos = [r.strip() for r in (a.repos.split(",") if a.repos else cfg.get("repos") or []) if r.strip()]
    if not repos:
        sys.exit("error: リポジトリが無い（install の --repos か、brain の .brain-kit/config.json の repos に足す）")
    dev_l, rel_l = label_of(cfg, "dev"), label_of(cfg, "release")
    since = (datetime.date.today() - datetime.timedelta(days=max(a.days, 0))).isoformat()

    items, owner, errors = [], [], []
    for repo in repos:
        try:
            issues = gh(["issue", "list", "-R", repo, "--state", "open", "--limit", "300",
                         "--json", "number,title,url,labels,updatedAt"])
            prs = gh(["pr", "list", "-R", repo, "--state", "open", "--limit", "300",
                      "--json", "number,title,url,labels,updatedAt,isDraft"])
            merged = gh(["pr", "list", "-R", repo, "--state", "merged", "--limit", "100",
                         "--search", "merged:>=%s" % since, "--json", "number,title,url,labels,mergedAt"])
        except Exception as e:  # noqa: BLE001  1 つのリポジトリが読めなくても残りは出す
            errors.append("%s: %s" % (repo, e))
            continue
        for it in issues:
            ls = [l["name"] for l in it.get("labels") or []]
            if rel_l in ls:
                st = "release"
            elif "question" in ls or "needs-triage" in ls:
                st = "decide"
            elif dev_l in ls or "agent-ready" in ls or "agent-working" in ls:
                st = "dev"
            else:
                st = "filed"
            items.append({"stage": st, "repo": repo, "kind": "issue", "number": it["number"], "title": it["title"],
                          "url": it["url"], "labels": ls, "at": it.get("updatedAt")})
            if st == "decide":
                owner.append({"text": it["title"], "ref": "%s#%d" % (repo, it["number"]), "url": it["url"]})
        for it in prs:
            ls = [l["name"] for l in it.get("labels") or []]
            items.append({"stage": "release" if rel_l in ls else "review", "repo": repo, "kind": "pr",
                          "number": it["number"], "title": it["title"], "url": it["url"], "labels": ls,
                          "draft": bool(it.get("isDraft")), "at": it.get("updatedAt")})
        for it in merged:
            items.append({"stage": "prod", "repo": repo, "kind": "pr", "number": it["number"], "title": it["title"],
                          "url": it["url"], "labels": [l["name"] for l in it.get("labels") or []], "at": it.get("mergedAt")})

    items.sort(key=lambda x: x.get("at") or "", reverse=True)
    counts = {k: 0 for k, _ in STAGES}
    for it in items:
        counts[it["stage"]] += 1
    doc = {
        "collected_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "repos": repos,
        "stages": [{"key": k, "label": l, "count": counts[k]} for k, l in STAGES],
        "items": items,
        "owner_auto": owner,
        "prod_since": since,
        "errors": errors,
    }
    text = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    if a.out == "-":
        sys.stdout.write(text)
    else:
        io.open(a.out, "w", encoding="utf-8").write(text)
        print("書いた: %s（%s）%s" % (a.out, "、".join("%s %d" % (l, counts[k]) for k, l in STAGES),
                                   "、読めなかった: " + "; ".join(errors) if errors else ""))


if __name__ == "__main__":
    main()
