---
date: 2026-01-01
project: none
tags: [release, log]
---

# How to write release/記録/ (log)

Append to `YYYY-MM-DD.md`, one block per PR (or per production operation). **Append-only.** Correct it with a new block.

```
## HH:MM <repo>#<N> (or the name of the operation)
- Instruction: whose comment (time) / <持ち主名>'s signal
- migration: <name>, SELECT <what, how many rows>
- Merge: main <before, 7 chars> → <after, 7 chars>
- Deployment: <how READY was confirmed> (<sha, 7 chars>)
- Confirmed: <key points of the SELECT>
- Stopped: <if any>
```
