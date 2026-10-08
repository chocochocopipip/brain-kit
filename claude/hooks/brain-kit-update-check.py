#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SessionStart: npm の公開版を 1 日 1 回確かめる。新しい版があれば 1 行だけ文脈に出す（更新はしない）。"""
import json
import os
import re
import sys
import tempfile
import threading
import time
import urllib.request


def semver(value):
    if isinstance(value, str) and re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
        return tuple(map(int, value.split(".")))
    return None


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def write_cache(path, value):
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=".update-check-", dir=os.path.dirname(path))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f)
        os.replace(tmp, path)
    except Exception:
        pass
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def fetch_latest():
    result = [None]

    def fetch():
        try:
            url = os.environ.get("BRAIN_KIT_UPDATE_URL", "https://registry.npmjs.org/brainkit-agents/latest")
            with urllib.request.urlopen(url, timeout=3) as response:
                value = json.loads(response.read(1024 * 1024).decode("utf-8"))["version"]
            result[0] = value if semver(value) else None
        except BaseException:
            pass

    # DNS や少しずつ届く本文も含め、取得全体を 3 秒だけ待つ。
    # 時間切れの worker は daemon として残し、フック終了時に一緒に終了する。
    worker = threading.Thread(target=fetch, daemon=True)
    worker.start()
    worker.join(3)
    return None if worker.is_alive() else result[0]


def main():
    state = os.path.expanduser("~/.claude/brain-kit")
    if os.environ.get("BRAIN_KIT_NO_UPDATE_CHECK") == "1" or os.path.exists(os.path.join(state, "no-update-check")):
        return
    # 入力を待たない。書き手が pipe を開いたままでも、今届いている分だけ読み捨てる。
    try:
        if not sys.stdin.isatty():
            fd = sys.stdin.fileno()
            blocking = os.get_blocking(fd)
            try:
                os.set_blocking(fd, False)
                os.read(fd, 65536)
            finally:
                os.set_blocking(fd, blocking)
    except Exception:
        pass
    manifest = read_json(os.path.join(state, "manifest.json"))
    if not isinstance(manifest, dict):
        return
    installed = manifest.get("package_version") if "package_version" in manifest else "%d.0.0" % manifest["version"]
    current = semver(installed)
    if current is None:
        return
    path = os.path.join(state, "update-check.json")
    cache = read_json(path)
    now = time.time()
    checked = cache.get("checked_at") if isinstance(cache, dict) else None
    if isinstance(checked, (int, float)) and 0 <= now - checked < 24 * 60 * 60:
        latest = cache.get("latest")
    else:
        latest = fetch_latest()
        write_cache(path, {"checked_at": now, "latest": latest})
    if semver(latest) is not None and semver(latest) > current:
        # SessionStart の stdout は Claude の文脈に入る（持ち主の画面には直接出ない。systemMessage は
        # SessionStart では捨てられる）。相棒が最初の返事で 1 行だけ伝える
        print("brain-kit の更新のお知らせ: brain-kit %s が出ている（今は %s）。自動では更新しない。"
              "中身を見る: npx brainkit-agents@latest --update --dry-run"
              "（持ち主への最初の返事の冒頭で、この 1 行だけをそのまま伝える。更新はしない）" % (latest, installed))


if __name__ == "__main__":
    try:
        main()
        sys.stdout.flush()
    except BaseException:
        pass
    # stdout の切断時も終了時の再 flush による stderr・非 0 終了を防ぐ。
    os._exit(0)
