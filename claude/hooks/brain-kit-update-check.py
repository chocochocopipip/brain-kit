#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SessionStart: キャッシュの新しい版を通知し、公開版の確認は 1 日 1 回バックグラウンドで行う。"""
import fcntl
import json
import os
import re
import subprocess
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
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        return True
    except Exception:
        return False
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
            with urllib.request.urlopen(url, timeout=5) as response:
                value = json.loads(response.read(1024 * 1024).decode("utf-8"))["version"]
            result[0] = value if semver(value) else None
        except BaseException:
            pass

    # DNS や少しずつ届く本文も含め、取得全体を 5 秒だけ待つ。
    # 時間切れの worker も末尾の os._exit で必ず終了する。
    worker = threading.Thread(target=fetch, daemon=True)
    worker.start()
    worker.join(5)
    return None if worker.is_alive() else result[0]


def fresh(cache, now):
    checked = cache.get("checked_at") if isinstance(cache, dict) else None
    return (isinstance(checked, (int, float)) and not isinstance(checked, bool)
            and -60 * 60 <= now - checked < 24 * 60 * 60)


def cached_latest(cache):
    value = cache.get("latest") if isinstance(cache, dict) else None
    return value if semver(value) else None


def refresh(state):
    # 取得から保存まで排他する。失敗時には以前の成功結果を一切書き換えない。
    with open(os.path.join(state, "update-check.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        latest = fetch_latest()
        if latest is not None:
            path = os.path.join(state, "update-check.json")
            cache = read_json(path)
            if isinstance(cache, dict) and "checked_at" in cache:
                write_cache(path, {"checked_at": cache["checked_at"], "latest": latest})


def main():
    state = os.path.expanduser("~/.claude/brain-kit")
    if os.environ.get("BRAIN_KIT_NO_UPDATE_CHECK") == "1" or os.path.exists(os.path.join(state, "no-update-check")):
        return
    if sys.argv[1:] == ["--refresh"]:
        refresh(state)
        return
    # 入力を待たない。書き手が pipe を開いたままでも、今届いている分だけ読み捨てる。
    try:
        if not sys.stdin.isatty():
            fd = sys.stdin.fileno()
            blocking = os.get_blocking(fd)
            try:
                os.set_blocking(fd, False)
                deadline = time.monotonic() + .02
                while time.monotonic() < deadline and os.read(fd, 65536):
                    pass
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
    latest = cached_latest(cache)
    if semver(latest) is not None and semver(latest) > current:
        # SessionStart の stdout は Claude の文脈に入る（持ち主の画面には直接出ない。systemMessage は
        # SessionStart では捨てられる）。相棒が最初の返事で 1 行だけ伝える
        if manifest.get("lang") == "en":
            print("brain-kit update notice: brain-kit %s is available (installed: %s). No automatic update. "
                  "Preview: npx brainkit-agents@latest --update --dry-run "
                  "(Repeat this one line verbatim at the start of your first reply to the owner. Do not update.)"
                  % (latest, installed))
        else:
            print("brain-kit の更新のお知らせ: brain-kit %s が出ている（今は %s）。自動では更新しない。"
                  "中身を見る: npx brainkit-agents@latest --update --dry-run"
                  "（持ち主への最初の返事の冒頭で、この 1 行だけをそのまま伝える。更新はしない）" % (latest, installed))

    if fresh(cache, time.time()):
        return
    with open(os.path.join(state, "update-check.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        cache = read_json(path)
        now = time.time()
        if fresh(cache, now):
            return
        # 通信前に試行時刻を永続化する。保存できなければ通信しない。
        if not write_cache(path, {"checked_at": now, "latest": cached_latest(cache)}):
            return
    # セッション開始は通信を待たず、独立したプロセスに任せる。
    subprocess.Popen([sys.executable, __file__, "--refresh"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True,
                     close_fds=True, env=os.environ)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    try:
        sys.stdout.flush()
    except BaseException:
        pass
    # stdout の切断時も終了時の再 flush による stderr・非 0 終了を防ぐ。
    os._exit(0)
