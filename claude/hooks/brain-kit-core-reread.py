#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SessionStart(compact): 今いる人格の核を main の brain から文脈へ戻す。通信・書き込みはしない。"""
import json
import os
import stat
import sys
import threading
import time


BRAIN = r"""<brain>"""
ROLE_JA = {"partner": "相棒", "dev": "開発", "review": "レビュー", "release": "リリース"}
CORE_FILES = {"partner": ("00_核.md", "02_関係.md"), "dev": ("00_核.md",),
              "review": ("00_核.md", "規準.md"), "release": ("00_核.md", "手順.md")}
FILE_LIMIT = 32 * 1024
TOTAL_LIMIT = 64 * 1024


def input_json():
    # pipe の書き手が閉じなくても待たない。入力の量と読み続ける時間にも上限を置く。
    data = bytearray()
    try:
        if sys.stdin.isatty():
            return {}
        fd = sys.stdin.fileno()
        blocking = os.get_blocking(fd)
        try:
            os.set_blocking(fd, False)
            deadline = time.monotonic() + .02
            while len(data) < 65536 and time.monotonic() < deadline:
                try:
                    chunk = os.read(fd, 65536 - len(data))
                except BlockingIOError:
                    break
                if not chunk:
                    break
                data.extend(chunk)
        finally:
            os.set_blocking(fd, blocking)
        value = json.loads(data)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def read_file(path, limit):
    # FIFO などを核の場所に置いてあっても、open/read で待たない。
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise ValueError("通常のファイルではない")
        return f.read(limit)


def main():
    if (os.environ.get("BRAIN_KIT_NO_CORE_REREAD") == "1" or
            os.path.exists(os.path.expanduser("~/.claude/brain-kit/no-core-reread"))):
        return
    event = input_json()
    if "source" in event and event["source"] != "compact":
        return
    brain = os.path.expanduser(BRAIN)
    cfg = json.loads(read_file(os.path.join(brain, ".brain-kit", "config.json"), 1024 * 1024))
    cwd = os.path.realpath(event.get("cwd") or os.getcwd())
    matches = []
    for role in ROLE_JA:
        person = cfg["personas"].get(role)
        if not person:
            continue
        root = os.path.realpath(brain if role == "partner" else brain + "-" + person["id"])
        if cwd == root or cwd.startswith(root.rstrip(os.sep) + os.sep):
            matches.append((len(root), role, person))
    if not matches:
        return
    _, role, person = max(matches, key=lambda match: match[0])
    area = person["name"] if role == "partner" else role
    parts = []
    remaining = TOTAL_LIMIT
    for name in CORE_FILES[role]:
        path = area + "/" + name
        limit = min(FILE_LIMIT, remaining)
        try:
            data = read_file(os.path.join(brain, path), limit + 1)
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
