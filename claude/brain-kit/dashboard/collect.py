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

止まっている（既定 24 時間、--stall-hours で変更）:
  作業中の issue: agent-working か開発ラベルがあり、更新が古い
  レビュー済みで未リリースの PR: 下書きでなく、リリースラベルか APPROVED があり、更新が古い
  セッション: 待っている仕事があり、最後の記録が古いか無い（読めたリポジトリだけで判定）
"""
from __future__ import print_function

import argparse
import datetime
import io
import json
import math
import os
import re
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


def gh(args, timeout=60):
    r = subprocess.run(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("gh %s: %s" % (" ".join(args[:3]), r.stderr.strip()[:200]))
    return json.loads(r.stdout or "[]")


def label_of(cfg, role):
    p = (cfg.get("personas") or {}).get(role) or {}
    return p.get("label") or p.get("id")


def stall_hours(cfg, cli=None, env=os.environ):
    for value in (cli, env.get("BRAIN_KIT_STALL_HOURS"), cfg.get("stall_hours"), 24):
        try:
            hours = float(value)
            if math.isfinite(hours) and hours > 0:
                return hours
        except (TypeError, ValueError, OverflowError):
            pass


def fetch(repo, since=None, timeout=60):
    data = {}
    for kind, fields in (("issue", "number,title,url,labels,updatedAt"),
                         ("pr", "number,title,url,labels,updatedAt,isDraft,reviewDecision")):
        data["issues" if kind == "issue" else "prs"] = gh(
            [kind, "list", "-R", repo, "--state", "open", "--limit", "300", "--json", fields], timeout=timeout)
    if since is not None:
        data["merged"] = gh(["pr", "list", "-R", repo, "--state", "merged", "--limit", "100",
                             "--search", "merged:>=%s" % since, "--json", "number,title,url,labels,mergedAt"], timeout=timeout)
    return data


def parse_time(value):
    try:
        at = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return at if at.tzinfo is not None else None
    except (AttributeError, TypeError, ValueError):
        return None


def last_session(brain, pid, role, claude_dir=None):
    brain = os.path.abspath(os.path.expanduser(brain))
    worktree = brain if role == "partner" else brain + "-" + pid
    enc = re.sub(r"[^A-Za-z0-9]", "-", worktree)
    directory = os.path.join(claude_dir or os.path.join(os.path.expanduser("~"), ".claude"), "projects", enc)
    latest = None
    try:
        with os.scandir(directory) as entries:
            for entry in entries:
                try:
                    if entry.name.endswith(".jsonl") and entry.is_file():
                        mtime = entry.stat().st_mtime
                        latest = mtime if latest is None else max(latest, mtime)
                except OSError:
                    continue
        return datetime.datetime.fromtimestamp(latest, datetime.timezone.utc) if latest is not None else None
    except (OSError, ValueError, OverflowError):
        return None


def waiting_work(cfg, repo_data, role):
    count = 0
    label = label_of(cfg, role)
    for data in repo_data.values():
        work = data.get("issues", []) if role == "dev" else data.get("prs", [])
        if role == "release":
            work = work + data.get("issues", [])
        for it in work:
            labels = [l["name"] for l in it.get("labels") or []]
            if label in labels or (role == "dev" and any(l in labels for l in ("agent-ready", "agent-working"))):
                count += 1
    return count


def find_stalled(cfg, brain, repo_data, hours, now=None, claude_dir=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    items = []
    for repo, data in repo_data.items():
        for kind, work in (("issue", data.get("issues", [])), ("pr", data.get("prs", []))):
            for it in work:
                labels = [l["name"] for l in it.get("labels") or []]
                eligible = ("agent-working" in labels or label_of(cfg, "dev") in labels) if kind == "issue" else (
                    not it.get("isDraft") and (label_of(cfg, "release") in labels or it.get("reviewDecision") == "APPROVED"))
                at = parse_time(it.get("updatedAt"))
                idle = (now - at).total_seconds() / 3600 if at else None
                if eligible and idle is not None and idle > hours:
                    items.append(dict(kind=kind, repo=repo, number=it["number"], title=it["title"],
                                      url=it["url"], at=it["updatedAt"], idle_hours=int(idle)))
    for role in ("dev", "review", "release"):
        p = (cfg.get("personas") or {}).get(role)
        if not p or not repo_data:
            continue
        work = waiting_work(cfg, repo_data, role)
        at = last_session(brain, p["id"], role, claude_dir)
        idle = (now - at).total_seconds() / 3600 if at else None
        if work and (idle is None or idle > hours):
            items.append(dict(kind="session", role=role, name=p["name"], id=p["id"],
                              at=at.isoformat() if at else None, idle_hours=int(idle) if idle is not None else None, work=work))
    groups = []
    roles = {"dev": "開発", "review": "レビュー", "release": "リリース"}
    for kind, label in (("issue", "作業中の issue"), ("pr", "レビュー済みで未リリースの PR"), ("session", "止まったセッション")):
        refs = []
        for it in items:
            if it["kind"] != kind:
                continue
            if kind == "session":
                refs.append("%s（%s、%s）" % (it["name"], roles[it["role"]],
                            "記録なし" if it["idle_hours"] is None else "%d 時間" % it["idle_hours"]))
            else:
                refs.append("%s#%s" % (it["repo"].split("/")[-1], it["number"]))
        if refs:
            groups.append(label + " " + "・".join(refs[:5]) + ("…ほか %d 件" % (len(refs) - 5) if len(refs) > 5 else ""))
    line = "止まっている（%s 時間以上動きなし）: %s" % (format(hours, "g"), "／".join(groups)) if groups else ""
    return {"hours": hours, "items": items, "line": line}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--brain", default=os.environ.get("BRAIN_DIR") or os.path.expanduser("~/brain"))
    ap.add_argument("--days", type=int, default=1, help="本番の列に何日前までのマージを出すか")
    ap.add_argument("--stall-hours", default=None, help="動きがないとみなす時間")
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
    repo_data = {}
    for repo in repos:
        try:
            data = fetch(repo, since)
            issues, prs, merged = data["issues"], data["prs"], data["merged"]
            repo_data[repo] = data
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
        "stalled": find_stalled(cfg, a.brain, repo_data, stall_hours(cfg, a.stall_hours)),
    }
    text = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    if a.out == "-":
        sys.stdout.write(text)
    else:
        io.open(a.out, "w", encoding="utf-8").write(text)
        print("書いた: %s（%s）%s" % (a.out, "、".join("%s %d" % (l, counts[k]) for k, l in STAGES),
                                   "、読めなかった: " + "; ".join(errors) if errors else ""))

    if doc["stalled"]["line"]:
        print(doc["stalled"]["line"], file=sys.stderr if a.out == "-" else sys.stdout)


if __name__ == "__main__":
    main()
