# Security Policy / セキュリティの方針

## Reporting a vulnerability / 脆弱性の報告

Please **do not open a public issue** for security problems. Report them privately through GitHub:
**Security → Report a vulnerability** on this repository
(<https://github.com/chocochocopipip/brain-kit/security/advisories/new>).

Include what is affected (file, option, hook), how to reproduce it, and the impact. Leave out your own personal data.
You should get a first reply within 7 days. Fixes are released as a new version and noted in the changelog.

セキュリティの問題は**公開の issue にしない**。このリポジトリの **Security → Report a vulnerability** から非公開で報告する。
何が（ファイル・オプション・フック）、どう再現し、何が起きうるかを書く。自分の個人情報は入れない。
7 日以内に最初の返事をする。直したものは新しい版として出し、変更履歴に書く。

## Scope / 対象

In scope / 対象:

- `install.sh`, `setup-base.sh`, `bin/brain-kit.js` and anything they write under `~/.claude` or the brain
- Hooks under `claude/hooks/` (they run automatically at session end)
- Permission settings shipped in `claude/settings*.json`
- Anything in the repository that leaks personal data or credentials

Out of scope / 対象外:

- Claude Code, Orca, Tailscale, gh and other tools the kit calls — report those to their own projects
- Content you wrote into your own brain

## Supported versions / 対象の版

Only the latest version on `main` gets fixes. Update with the installer before reporting if you can.
直すのは `main` の最新の版だけ。できれば更新してから報告する。
