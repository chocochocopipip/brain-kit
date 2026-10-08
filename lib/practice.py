#!/usr/bin/env python3
"""練習専用。ローカルだけで四人格を体験し、本物のプロジェクトには触らない。"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

STAGES = [("filed", "起票"), ("decide", "判断待ち"), ("dev", "開発"),
          ("review", "PR（レビュー中）"), ("release", "リリースの列"), ("prod", "本番")]
ROLES = dict(partner="相棒", dev="開発", review="レビュー", release="リリース")
NOTICE = "練習専用・ローカルのみ。本物のプロジェクト・brain・~/.claude には書かない。"
BUG = '#!/bin/sh\n# 練習専用。本物のプロジェクトには触らない。\nprintf "こんにちは、\\n"\n'
FIX = '#!/bin/sh\n# 練習専用。本物のプロジェクトには触らない。\nprintf "こんにちは、%s\\n" "$1"\n'
TEST = '''#!/bin/sh
# 練習専用。本物のプロジェクトには触らない。
[ "$(./greet.sh 練習)" = "こんにちは、練習" ]
'''


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def say(text):
    print("練習: " + text)


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def inside(path, parent):
    return path == parent or parent in path.parents


def git_env():
    # 呼び出し元のリポジトリ指定・設定・フックを練習に持ち込まない。
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="practice", GIT_COMMITTER_NAME="practice",
               GIT_AUTHOR_EMAIL="practice@example.invalid",
               GIT_COMMITTER_EMAIL="practice@example.invalid",
               GIT_TERMINAL_PROMPT="0", GIT_ALLOW_PROTOCOL="file")
    return env


def git_at(path, *args, check=True):
    result = subprocess.run(["git", "-C", str(path), "-c", "core.hooksPath=" + os.devnull,
                             "-c", "init.templateDir=", "-c", "commit.gpgsign=false",
                             "-c", "protocol.allow=never", "-c", "protocol.file.allow=always"] + list(args),
                            env=git_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True)
    if check and result.returncode:
        raise RuntimeError("git %s が止まった: %s" % (args[0], result.stderr.strip()))
    return result


def marker_ok(root):
    marker = root / ".brain-kit-practice"
    try:
        return not marker.is_symlink() and read(marker).get("kind") == "brain-kit-practice"
    except (OSError, ValueError, AttributeError):
        return False


def protect(root, brain):
    home = Path(os.path.expanduser("~")).resolve()
    # --brain で別の brain を指しても、既定の ~/brain は常に守る。
    owned = (brain, (home / "brain").resolve(), (home / ".claude").resolve())
    if inside(home, root) or any(inside(p, root) or inside(root, p) for p in owned):
        raise RuntimeError("この場所は練習に使えない（HOME・brain・~/.claude を保護）")


def validate_start(root, brain):
    if root.resolve() != root or root.is_symlink():
        raise RuntimeError("練習の場所がリンクに変わったので止める")
    protect(root, brain)
    if root.exists() and not marker_ok(root):
        raise RuntimeError("練習の印が無いディレクトリには書けない")
    parent = root
    while not parent.exists():
        parent = parent.parent
    result = git_at(parent, "rev-parse", "--show-toplevel", check=False)
    if result.returncode == 0 and not inside(Path(result.stdout.strip()).resolve(), root):
        raise RuntimeError("本物の git 作業ツリーの中には練習を作れない")
    # 再開時も、ファイルや git の管理領域を外へ差し替えられていないか確認する。
    if root.exists():
        for entry in root.rglob("*"):
            if entry.is_symlink() and not inside(entry.resolve(), root):
                raise RuntimeError("練習の外を指すリンクがあるので止める")
        for name in ("work", "dev-wt", "review-wt", "remote.git"):
            repo = root / name
            if repo.exists():
                for flag in ("--absolute-git-dir", "--git-common-dir"):
                    result = git_at(repo, "rev-parse", flag, check=False)
                    if result.returncode == 0:
                        target = (repo / result.stdout.strip()).resolve()
                        if not inside(target, root):
                            raise RuntimeError("git の管理領域が練習の外なので止める")
                if name != "remote.git":
                    # core.worktree などで作業ツリーが外へ向いていないか（merge が外のファイルを書かない）
                    top = git_at(repo, "rev-parse", "--show-toplevel", check=False)
                    if top.returncode != 0 or Path(top.stdout.strip()).resolve() != repo.resolve():
                        raise RuntimeError("git の作業ツリーが練習の外なので止める")


def personas(brain):
    try:
        cfg = read(brain / ".brain-kit/config.json")["personas"]
    except (OSError, ValueError, KeyError, TypeError):
        cfg = {}
    result = {}
    for role, name in ROLES.items():
        entry = cfg.get(role, {}) if isinstance(cfg, dict) else {}
        entry = entry if isinstance(entry, dict) else {}
        ident = entry.get("id") or role
        if not isinstance(ident, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", ident):
            ident = role
        result[role] = {"id": ident, "name": entry.get("name") or name,
                        "label": entry.get("label") or ident}
    return result


class Practice:
    def __init__(self, root, brain):
        self.root, self.brain = root, brain
        self.p = personas(brain)
        self.work = root / "work"
        self.remote = root / "remote.git"
        self.dev = root / "dev-wt"
        self.review = root / "review-wt"
        self.branch = self.p["dev"]["id"] + "/1-greet"

    def git(self, path, *args):
        if not inside(path.resolve(), self.root):
            raise RuntimeError("git の実行先が練習の外")
        if args and args[0] in ("clone", "fetch", "push"):
            # 練習の bare 以外へ向け直す設定（url.*.insteadOf / pushInsteadOf）があれば通信しない。
            rewrites = git_at(path, "config", "--get-regexp", r"^url\.", check=False).stdout.strip()
            if rewrites:
                raise RuntimeError("git の URL の書き換え設定があるので止める（練習の外へ送らない）")
        return git_at(path, *args).stdout.strip()

    def item(self, kind):
        return read(self.root / kind / "1.json")

    def save(self, kind, item):
        item["updatedAt"] = now()
        write(self.root / kind / "1.json", item)

    def comment(self, item, role, body):
        if not any(c["body"] == body for c in item["comments"]):
            item["comments"].append({"by": self.p[role]["name"], "body": body, "at": now()})

    def labels(self, item, role, add=(), remove=()):
        item["labels"] = list(dict.fromkeys([x for x in item["labels"] if x not in remove] + list(add)))
        self.comment(item, role, "練習のラベル: 追加 %s／解除 %s。本物のプロジェクトには触らない。" %
                     (", ".join(add) or "なし", ", ".join(remove) or "なし"))

    def record(self, role, body):
        path = self.root / "records" / (role + ".md")
        text = path.read_text(encoding="utf-8") if path.exists() else "# 練習の記録\n\n" + NOTICE + "\n"
        if body not in text:
            path.write_text(text + "\n" + now() + "\n" + body + "\n", encoding="utf-8")

    def board(self, save=True):
        items, owner = [], []
        for kind in ("issues", "prs"):
            if not (self.root / kind / "1.json").exists():
                continue
            it = self.item(kind)
            ls = it["labels"]
            if kind == "issues":
                if it["state"] != "open":
                    continue
                if self.p["release"]["label"] in ls:
                    stage = "release"
                elif "question" in ls or "needs-triage" in ls:
                    stage = "decide"
                elif self.p["dev"]["label"] in ls or "agent-ready" in ls or "agent-working" in ls:
                    stage = "dev"
                else:
                    stage = "filed"
            elif it["state"] == "merged":
                stage = "prod"
            elif it["state"] == "open":
                stage = "release" if self.p["release"]["label"] in ls else "review"
            else:
                continue
            item = dict(stage=stage, repo="practice", kind="issue" if kind == "issues" else "pr",
                        number=1, title=it["title"], url=(self.root / kind / "1.json").as_uri(),
                        labels=ls, at=it.get("mergedAt") or it["updatedAt"])
            if kind == "prs" and it["state"] == "open":
                item["draft"] = False
            items.append(item)
            if stage == "decide":
                owner.append(dict(text=it["title"], ref="practice#1", url=item["url"]))
        items.sort(key=lambda x: x["at"], reverse=True)
        board = dict(collected_at=now(), repos=["practice"],
                     stages=[dict(key=k, label=l, count=sum(i["stage"] == k for i in items)) for k, l in STAGES],
                     items=items, owner_auto=owner,
                     prod_since=(datetime.date.today() - datetime.timedelta(days=1)).isoformat(), errors=[])
        if save:
            write(self.root / "board.json", board)
        say(" | ".join("%s %d" % (s["label"], s["count"]) for s in board["stages"]))
        for item in items:
            say("%s #1 %s [%s]" % (item["kind"], item["title"], ", ".join(item["labels"])))

    def test(self, path, expected=True):
        # 練習のファイルは決まった中身だけを実行する。書き換えられていたら走らせない。
        greet = (path / "greet.sh").read_text(encoding="utf-8")
        if (path / "test.sh").read_text(encoding="utf-8") != TEST or greet not in (BUG, FIX):
            raise RuntimeError("練習のスクリプトが書き換えられているので実行しない")
        result = subprocess.run(["sh", "./test.sh"], cwd=str(path), env=git_env(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        say("%s test.sh: %s" % (path.name, "PASS" if result.returncode == 0 else "FAIL"))
        if (result.returncode == 0) != expected:
            raise RuntimeError("練習のテスト結果が期待と違う")

    def explain(self, step):
        role = ["partner", "partner", "dev", "review", "partner", "release", "partner"][step]
        p = self.p[role]
        say("[%d/6] %s 【%s: %s（/%s）】" %
            (step, ["準備", "相棒", "開発", "レビュー", "相棒と持ち主の確認", "リリース", "まとめ"][step],
             ROLES[role], p["name"], p["id"]))
        explanations = [
            "from-chat は出所、needs-triage は判断待ち。ローカルの bare が GitHub の代わり。",
            "相棒が決定コメントと %s を付ける。agent-ready は持ち主だけの関門で、エージェントは付けない。練習では持ち主に代わりスクリプトが付ける。" % self.p["dev"]["label"],
            "agent-working で着手し、修正・テスト・PR を作る。開発が PR に %s を付けレビューへ。" % self.p["review"]["label"],
            "壊すと落ちる（fails-before, passes-after）を実測し、判定: OK と head を記録。%s を外す。" % self.p["review"]["label"],
            "相棒が %s と「%sへ：入れてよい」の指示コメントを付ける。両方が合図。伝言だけでは動かない。" % (self.p["release"]["label"], self.p["release"]["name"]),
            "指示コメント・ラベル %s・OK の head を照合。名前つき check の SUCCESS を test.sh で代用し、main の前後 SHA と bare 側を確かめる。" % self.p["release"]["label"],
            "ラベルの付け手と工程表、リリースのラベル＋指示コメント＋main の前後 SHA を見た。",
        ]
        say(explanations[step])
        say("実運用の記録は %s の dev/報告/・review/記録/・release/記録/。練習では %s/records/ にだけ書く。" %
            (self.brain, self.root))

    def summary(self):
        say("完了。agent-ready は持ち主、開発ラベルは相棒、レビューラベルは開発、リリースラベル＋指示は相棒（型 A だけレビュー）。")
        say("実際のセッションでは --repos に本物のリポジトリを登録し、各人格の skill で進める。この練習は登録しない。")
        say("実運用の記録: %s/{dev/報告,review/記録,release/記録}/。練習の記録: %s/records/" % (self.brain, self.root))
        suffix = " --practice-dir " + shlex.quote(str(self.root))
        say("削除: ./install.sh --practice-cleanup" + suffix)
        say("npm から: npx brainkit-agents --practice-cleanup" + suffix)

    def step(self, n):
        if n == 0:
            for name in ("records", "issues", "prs", "remote.git"):
                (self.root / name).mkdir(exist_ok=True)
            (self.root / "README.md").write_text("# 初日の練習\n\n" + NOTICE +
                "\nGitHub の代わりは remote.git、issue・PR・ラベル・コメントはファイル。安全に消してよい。\n" +
                "削除: `./install.sh --practice-cleanup --practice-dir " + shlex.quote(str(self.root)) +
                "`（非対話なら --yes）。--uninstall では消えない。\n", encoding="utf-8")
            self.git(self.remote, "init", "--bare")
            self.git(self.remote, "symbolic-ref", "HEAD", "refs/heads/main")
            if not self.work.exists():
                self.git(self.root, "clone", str(self.remote), str(self.work))
            for name, content in (("greet.sh", BUG), ("test.sh", TEST)):
                if not (self.work / name).exists():
                    (self.work / name).write_text(content, encoding="utf-8")
                    (self.work / name).chmod(0o755)
            self.git(self.work, "add", "greet.sh", "test.sh")
            if self.git(self.work, "diff", "--cached", "--name-only"):
                self.git(self.work, "commit", "-m", "練習: 名前が出ないあいさつと落ちるテスト")
            self.git(self.work, "push", str(self.remote), "main")
            self.save("issues", dict(title="練習: あいさつに名前が出ない", body=NOTICE,
                      labels=["from-chat", "needs-triage"], comments=[], state="open", head=None, base="main"))
        elif n == 1:
            issue = self.item("issues")
            self.comment(issue, "partner", "決定：練習のあいさつに引数の名前を出す。本物のプロジェクトには触らない。")
            self.labels(issue, "partner", ["agent-ready", self.p["dev"]["label"]], ["needs-triage"])
            self.save("issues", issue)
        elif n == 2:
            issue = self.item("issues")
            self.labels(issue, "dev", ["agent-working"])
            self.save("issues", issue)
            if not self.dev.exists():
                self.git(self.work, "worktree", "add", "-b", self.branch, str(self.dev), "main")
            (self.dev / "greet.sh").write_text(FIX, encoding="utf-8")
            self.test(self.dev)
            self.git(self.dev, "add", "greet.sh")
            if self.git(self.dev, "diff", "--cached", "--name-only"):
                self.git(self.dev, "commit", "-m", "練習: あいさつに名前を出す")
            self.git(self.dev, "push", str(self.remote), self.branch)
            pr = dict(title="練習: あいさつに名前を出す", body=NOTICE +
                      "\n確かめたこと／確かめていないこと\n- test.sh PASS\n- 配信と本番データは対象外\ncloses #1",
                      labels=[], comments=[], state="open", head=self.git(self.dev, "rev-parse", "HEAD"),
                      base="main", branch=self.branch)
            self.labels(pr, "dev", [self.p["review"]["label"]])
            self.save("prs", pr)
            self.labels(issue, "dev", remove=["agent-working"])
            self.save("issues", issue)
            self.record("dev", "練習 PR #1: test.sh PASS、レビューへ。head " + pr["head"])
        elif n == 3:
            pr = self.item("prs")
            self.git(self.work, "fetch", str(self.remote), pr["branch"])
            head = self.git(self.work, "rev-parse", "FETCH_HEAD")
            if not self.review.exists():
                self.git(self.work, "worktree", "add", "--detach", str(self.review), head)
            else:
                self.git(self.review, "checkout", "--detach", head)
            self.test(self.work, expected=False)
            self.test(self.review)
            pr["head"] = head
            self.comment(pr, "review", "判定: OK\nhead " + head + "\n1. 指摘なし。練習で main FAIL / head PASS を実測。本物には触らない。")
            self.labels(pr, "review", remove=[self.p["review"]["label"]])
            self.save("prs", pr)
            say("型 A は migration・本番 SQL・見た目変更・お金・ログインや権限の変更がなく、許可されたリポジトリだけ。練習は型 A を許可していないので相棒と持ち主へ。")
            self.record("review", "練習: 判定 OK、指摘なし。main FAIL / head PASS。head " + head)
        elif n == 4:
            pr = self.item("prs")
            self.comment(pr, "partner", self.p["release"]["name"] + "へ：入れてよい（head " + pr["head"][:7] + "）\n練習だけ。本物のプロジェクトには触らない。")
            self.labels(pr, "partner", [self.p["release"]["label"]])
            self.save("prs", pr)
        elif n == 5:
            self.release()

    def release(self):
        pr = self.item("prs")
        if pr["state"] == "merged":
            # 前回は PR をマージ済みと書いたところで止まった。main を確かめて、残りの後始末だけ続ける。
            after = pr.get("main_after")
            if not after or self.git(self.work, "rev-parse", "main") != after or \
                    self.git(self.remote, "rev-parse", "main") != after:
                raise RuntimeError("マージ済みの記録と main が合わないので止める")
            self.finish_release(pr)
            return
        # 最新の指示と最新の判定だけを見る（あとから取り消し・NG が付いたら止める）。
        to_release = self.p["release"]["name"] + "へ："
        instructions = [c for c in pr["comments"] if c["body"].startswith(to_release)]
        if not instructions or not instructions[-1]["body"].startswith(to_release + "入れてよい"):
            raise RuntimeError("指示コメントが無いのでリリースを止める")
        say("最新の指示: " + (instructions[-1]["body"] if instructions else "なし"))
        if self.p["release"]["label"] not in pr["labels"]:
            raise RuntimeError("リリースラベルが無いので止める")
        self.git(self.work, "fetch", str(self.remote), pr["branch"])
        head = self.git(self.work, "rev-parse", "FETCH_HEAD")
        verdicts = [c for c in pr["comments"] if c["body"].startswith("判定:")]
        last = verdicts[-1]["body"] if verdicts else ""
        ok_head = last.splitlines()[1][5:] if last.startswith("判定: OK\nhead ") else None
        if ok_head != head:
            raise RuntimeError("OK の head と現在の PR head が違うので止める")
        self.git(self.review, "checkout", "--detach", head)
        self.test(self.review)
        # 前後 SHA は再開にも使えるよう、マージより先に保存する。
        before = pr.get("main_before") or self.git(self.work, "rev-parse", "main")
        pr["main_before"] = before
        self.save("prs", pr)
        if self.git(self.work, "rev-parse", "main") == before:
            self.git(self.work, "merge", "--squash", head)
            self.git(self.work, "commit", "-m", "練習: あいさつに名前を出す (#1)")
        after = self.git(self.work, "rev-parse", "main")
        if after == before or self.git(self.work, "rev-parse", "main^") != before or \
                self.git(self.work, "rev-parse", "main^{tree}") != self.git(self.work, "rev-parse", head + "^{tree}"):
            raise RuntimeError("main の前進が OK の head の squash ではないので止める")
        self.git(self.work, "push", str(self.remote), "main")
        if self.git(self.remote, "rev-parse", "main") != after:
            raise RuntimeError("main の前進・bare との一致を確かめられない")
        say("実運用では配信 READY と必要な SELECT も待つ。練習には配信・本番データが無い。")
        self.labels(pr, "release", remove=[self.p["release"]["label"]])
        pr.update(state="merged", mergedAt=now(), head=head, main_after=after)
        self.save("prs", pr)
        self.finish_release(pr)

    def finish_release(self, pr):
        issue = self.item("issues")
        issue["state"] = "closed"
        self.save("issues", issue)
        report = "入った practice#1 main %s→%s" % (pr["main_before"][:7], pr["main_after"][:7])
        self.record("release", "練習: " + report + "\n配信 READY・SELECT は対象外。本物のプロジェクトには触らない。")
        say(report)


def main():
    ap = argparse.ArgumentParser(description=NOTICE)
    ap.add_argument("action", choices=["start", "status", "cleanup"])
    ap.add_argument("--dir", default=os.path.join(os.path.expanduser("~"), "brain-kit-practice"))
    ap.add_argument("--brain", default=os.environ.get("BRAIN_DIR") or os.path.expanduser("~/brain"))
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--auto", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="何も作らず消さず、場所と予定だけを出す")
    ap.add_argument("--until", type=int, choices=range(7), default=6, help="練習のテスト専用: 指定した段まで実行")
    args = ap.parse_args()
    raw = Path(os.path.abspath(os.path.expanduser(args.dir)))
    if raw.is_symlink():
        raise RuntimeError("練習先自体がリンクなので止める")
    root = raw.resolve()
    brain = Path(args.brain).expanduser().resolve()
    say(NOTICE)
    if args.action != "start" and not root.exists():
        say("練習用プロジェクトは無い")
        return
    if args.action == "cleanup":
        protect(root, brain)
        if not marker_ok(root):
            raise RuntimeError("有効な練習の印が無いので消せない")
        if args.dry_run:
            say("dry-run: 消す予定 %s（何も消していない）" % root)
            return
        if not args.yes:
            if not sys.stdin.isatty():
                raise RuntimeError("非対話の練習削除には --yes が要る")
            if input("練習だけを消す？ %s [y/N] " % root).lower() != "y":
                say("削除を中断した")
                return
        if root.resolve() != root or root.is_symlink() or not marker_ok(root):
            raise RuntimeError("確認中に練習の印や場所が変わったので消せない")
        shutil.rmtree(root)
        say("練習用プロジェクトを消した")
        return
    validate_start(root, brain)
    if args.dry_run and args.action == "start":
        say("dry-run: 練習を %s に作る予定（何も作っていない）" % root)
        return
    practice = Practice(root, brain)
    state = read(root / "state.json") if (root / "state.json").exists() else {"step": -1, "notice": NOTICE}
    if args.action == "status":
        say("完了した段: %d/6、場所: %s" % (state["step"], root))
        practice.board(save=False)
        return
    # 練習先の親を新設すると範囲外への書き込みになるので、既存の親だけ使う。
    if not root.parent.is_dir():
        raise RuntimeError("練習先の親ディレクトリが無い。既存の場所の直下を指定する")
    root.mkdir(exist_ok=True)
    if not marker_ok(root):
        write(root / ".brain-kit-practice", dict(kind="brain-kit-practice", created=now()))
    for n in range(state["step"] + 1, args.until + 1):
        practice.explain(n)
        if sys.stdin.isatty() and not args.auto:
            try:
                answer = input("練習: Enter で次へ／q で中断: ")
            except EOFError:
                answer = "q"
            if answer.lower() == "q":
                write(root / "state.json", state)
                say("中断した。--practice で続きから再開できる")
                return
        validate_start(root, brain)
        practice.step(n)
        practice.board()
        state = {"step": n, "notice": NOTICE}
        write(root / "state.json", state)
    if state["step"] == 6:
        practice.summary()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as exc:
        say("止まった。本物のプロジェクトには触らない。" + str(exc))
        sys.exit(1)
    except KeyboardInterrupt:
        say("中断した。練習は --practice で再開できる")
        sys.exit(1)
