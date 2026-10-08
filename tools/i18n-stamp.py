#!/usr/bin/env python3
"""Check translation coverage, source hashes, and owner-facing message literals."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
EN = ROOT / 'i18n' / 'en'
JAPANESE = re.compile(r'[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]')


OTHER_SOURCES = {'lib/start-all.sh'}


def translatable():
    paths = {p.relative_to(ROOT).as_posix() for p in (ROOT / 'brain-template').rglob('*.md')}
    for line in (ROOT / 'kitfiles.tsv').read_text(encoding='utf-8').splitlines():
        if line and not line.startswith('#'):
            src = line.split('\t')[0]
            if src.endswith('.md'):
                paths.add(src)
    # 持ち主に見える出力を持つ生成元（.md 以外）
    paths.update(OTHER_SOURCES)
    return paths


def digest(src):
    return hashlib.sha256((ROOT / src).read_bytes()).hexdigest()


def sources(write=False):
    translated = {p.relative_to(EN).as_posix() for p in EN.rglob('*.md')}
    translated.update(src for src in OTHER_SOURCES if (EN / src).is_file())
    stamp = EN / 'sources.tsv'
    if write:
        # Hash the source bytes, never read or rewrite the translated Markdown.
        rows = []
        for src in sorted(translated):
            if not (ROOT / src).is_file():
                print('English file has no Japanese source: ' + src)
                return 1
            rows.append(src + '\t' + digest(src) + '\n')
        stamp.write_text(''.join(rows), encoding='utf-8')
        return 0
    errors = []
    recorded = {}
    if stamp.exists():
        for line in stamp.read_text(encoding='utf-8').splitlines():
            parts = line.split('\t')
            if len(parts) != 2 or not re.fullmatch(r'[0-9a-f]{64}', parts[1]):
                errors.append('Invalid sources.tsv row: ' + line)
                continue
            src, value = parts
            if src in recorded:
                errors.append('Duplicate sources.tsv row: ' + src)
            recorded[src] = value
    expected = translatable()
    for src in sorted(expected - translated):
        errors.append('Missing English file: ' + src)
    for src in sorted(expected & translated):
        if recorded.get(src) != digest(src):
            errors.append(src + ': 日本語版が変わった。英語版を直して --write')
    for src in sorted((set(recorded) - (expected & translated)) | (translated - expected)):
        errors.append('Stale source row or English file: ' + src)
    if list(recorded) != sorted(recorded):
        errors.append('sources.tsv must be sorted')
    for error in errors:
        print(error)
    return bool(errors)


def catalog():
    tree = ast.parse((ROOT / 'lib' / 'kit.py').read_text(encoding='utf-8'))
    messages = json.loads((EN / 'messages.json').read_text(encoding='utf-8'))
    literals = {n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
    errors = []

    def message_call(node):
        return isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'M'

    # 表示文は M() を通す。M() の外に置いてよい日本語は、道具が探す名前・置き換えの印・
    # 古い入れ方（v1〜v9）を見分ける文字列・翻訳表のキーとして使う表示名だけ（ここに列挙する）。
    internal = {
        '日本語', '相棒', '開発', 'レビュー', 'リリース', '持ち主', '持ち主:', '状況', '状況カード',
        '_テンプレート.md', '00_核.md', '^持ち主: *(.+)$', '^リポジトリ: `([^`/]+/[^`]+)`',
        '憲法は `~/brain/',
    }
    inside = set()
    docstrings = set()
    for node in ast.walk(tree):
        if message_call(node):
            inside.update(id(child) for child in ast.walk(node))
        # kit.py の argparse の help（使い方は install.sh が持ち主の言語で出す）
        if isinstance(node, ast.keyword) and node.arg == "help":
            inside.update(id(child) for child in ast.walk(node.value))
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef)) and node.body:
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docstrings.add(id(first.value))
    for node in ast.walk(tree):
        if message_call(node) and node.args and isinstance(node.args[0], ast.Constant):
            key = node.args[0].value
            if isinstance(key, str) and key not in messages:
                errors.append('Missing message: ' + repr(key))
        if (isinstance(node, ast.Constant) and isinstance(node.value, str) and JAPANESE.search(node.value)
                and id(node) not in inside and id(node) not in docstrings and node.value not in internal
                and not re.fullmatch(r'<[^<>]+>', node.value)):
            errors.append('lib/kit.py:%d: Japanese literal outside M(): %r' % (node.lineno, node.value))
    for key, value in messages.items():
        if key not in literals:
            errors.append('Unused message: ' + repr(key))
        if not isinstance(value, str) or JAPANESE.search(value):
            errors.append('Japanese or invalid English value: ' + repr(key))
        # Preserve printf argument types and order, including width specifiers.
        placeholders = r'%(?:\([^)]+\))?[-+#0 ]*\d*(?:\.\d+)?[diouxXeEfFgGcrsa%]'
        if isinstance(value, str) and re.findall(placeholders, key) != re.findall(placeholders, value):
            errors.append('Changed placeholders: ' + repr(key))
    if list(messages) != sorted(messages):
        errors.append('messages.json must have sorted keys')
    for error in errors:
        print(error)
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--write', action='store_true')
    group.add_argument('--catalog', action='store_true')
    args = parser.parse_args()
    return catalog() if args.catalog else sources(args.write)


if __name__ == '__main__':
    sys.exit(main())
