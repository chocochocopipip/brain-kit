#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SessionStart(compact): 今いる人格の核を main の brain から文脈へ戻す。通信・書き込みはしない。"""
import json
import os
import re
import select
import stat
import sys
import threading
import time


ROLE_JA = {"partner": "相棒", "dev": "開発", "review": "レビュー", "release": "リリース"}
CORE_FILES = {"partner": ("00_核.md", "02_関係.md"), "dev": ("00_核.md",),
              "review": ("00_核.md", "規準.md"), "release": ("00_核.md", "手順.md")}
FILE_LIMIT = 32 * 1024
TOTAL_LIMIT = 64 * 1024


def input_json():
    # 遅れて届く分割入力も、合計 1 秒・64 KiB まで待つ。
    data = bytearray()
    fd = sys.stdin.fileno()
    deadline = time.monotonic() + 1.0
    while len(data) < 65536:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            break
        chunk = os.read(fd, 65536 - len(data))
        if not chunk:
            break
        data.extend(chunk)
        try:
            value = json.loads(data)
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(value, dict):
            return value
    # 無入力だけはセッション cwd を使う。不正・未完の入力は無視する。
    return {} if not data else None


def read_file(path, limit):
    # FIFO などを核の場所に置いてあっても、open/read で待たない。
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise ValueError("通常のファイルではない")
        return f.read(limit)


def inside(path, root):
    return path.startswith(root.rstrip(os.sep) + os.sep)


def valid_personas(personas):
    for person in personas.values():
        if not isinstance(person, dict) or not isinstance(person.get("id"), str):
            return False
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", person["id"]):
            return False
    name = personas["partner"]["name"]
    return (isinstance(name, str) and bool(name) and not name.startswith(".")
            and not os.path.isabs(name) and not any(c in name for c in ("/", "\\", "\0")))


def role_at(cwd, brain, personas):
    # 最寄りの .git が境界。別リポジトリから親の人格へは戻らない。
    top = cwd
    while not os.path.lexists(os.path.join(top, ".git")):
        parent = os.path.dirname(top)
        if parent == top:
            return None
        top = parent
    git = os.path.join(top, ".git")
    if os.path.isdir(git):
        return "partner" if os.path.realpath(git) == os.path.realpath(os.path.join(brain, ".git")) else None
    link = read_file(git, 65536).decode("utf-8").strip()
    if not link.startswith("gitdir: "):
        return None
    gitdir = os.path.realpath(os.path.join(top, link[len("gitdir: "):]))
    if not inside(gitdir, os.path.realpath(os.path.join(brain, ".git", "worktrees"))):
        return None
    # 登録が生きていて、この場所を指し返しているか（写したディレクトリ・古い .git の指す先では動かない）
    back = read_file(os.path.join(gitdir, "gitdir"), 65536).decode("utf-8").strip()
    if os.path.realpath(os.path.join(gitdir, back)) != os.path.realpath(git):
        return None
    common = read_file(os.path.join(gitdir, "commondir"), 65536).decode("utf-8").strip()
    if os.path.realpath(os.path.join(gitdir, common)) != os.path.realpath(os.path.join(brain, ".git")):
        return None
    for role in ("dev", "review", "release"):
        person = personas.get(role)
        if person and top == os.path.realpath(brain + "-" + person["id"]):
            return role
    head = read_file(os.path.join(gitdir, "HEAD"), 65536).decode("utf-8").strip()
    for role in ("dev", "review", "release"):
        person = personas.get(role)
        if person and head == "ref: refs/heads/" + person["id"]:
            return role
    return None


def main():
    if (os.environ.get("BRAIN_KIT_NO_CORE_REREAD") == "1" or
            os.path.exists(os.path.expanduser("~/.claude/brain-kit/no-core-reread"))):
        return
    event = input_json()
    if event is None or ("source" in event and event["source"] != "compact"):
        return
    brain = read_file(os.path.expanduser("~/.claude/brain-kit/brain-path"), 65536).decode("utf-8")
    if brain.endswith("\n"):
        brain = brain[:-1]
    if not brain:
        return
    brain = os.path.expanduser(brain)
    cfg = json.loads(read_file(os.path.join(brain, ".brain-kit", "config.json"), 1024 * 1024))
    personas = cfg["personas"]
    if not valid_personas(personas):
        return
    cwd = os.path.realpath(event.get("cwd") or os.getcwd())
    role = role_at(cwd, brain, personas)
    if role is None:
        return
    # 起動スクリプトは worktree が無いと brain で始める（--no-worktrees・worktree が消えた）。そのときは
    # 起動スクリプトが渡した役を使い、開発・レビュー・リリースのセッションに相棒の核を出さない。
    # worktree の中では場所で決めた役のまま
    launched = os.environ.get("BRAIN_KIT_PERSONA")
    if role == "partner" and launched in ("dev", "review", "release") and launched in personas:
        role = launched
    person = personas[role]
    area = person["name"] if role == "partner" else role
    parts = []
    remaining = TOTAL_LIMIT
    for name in CORE_FILES[role]:
        path = area + "/" + name
        limit = min(FILE_LIMIT, remaining)
        try:
            # 許す場所は「brain の実体の直下の、その人格の領域の名前」。領域そのものが symlink で
            # 別の人格や外を指していても、実体がその名前の下に無ければ読まない
            core = os.path.realpath(os.path.join(brain, path))
            if not inside(core, os.path.join(os.path.realpath(brain), area)):
                continue
            data = read_file(core, limit + 1)
        except Exception:
            continue
        # UTF-8 の途中で切れても壊れた文字を出さず、本文のバイト数で上限を守る。
        content = data[:limit].decode("utf-8", "ignore")
        remaining -= len(data[:limit])
        part = "--- %s ---\n%s" % (path, content)
        if not part.endswith("\n"):
            part += "\n"
        if len(data) > limit:
            part += "（以下略: %s）\n" % path
        parts.append(part)
    if parts:
        output = "文脈の要約のあと、%s %s の核を読み直す（brain-kit のフック）。\n" % (ROLE_JA[role], person["name"])
        sys.stdout.buffer.write((output + "".join(parts)).encode("utf-8"))


def run():
    try:
        main()
        sys.stdout.flush()
    except BaseException:
        pass


if __name__ == "__main__":
    # 読み出し先や stdout が応答しない場合も、セッションを待たせない。
    try:
        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        worker.join(3)
    except BaseException:
        pass
    # 切断された stdout の終了時の再 flush も避け、常に静かに成功で終える。
    os._exit(0)
