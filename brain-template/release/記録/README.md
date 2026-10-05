---
date: 2026-01-01
project: none
tags: [release, 記録]
---

# release/記録/ の書き方

`YYYY-MM-DD.md` に、1 PR（または 1 本番操作）1 ブロックで追記する。**追記専用。**訂正は新しいブロックで。

```
## HH:MM <repo>#<N>（または操作の名前）
- 指示：誰のコメント（時刻）／<持ち主名>の合図
- migration：<名前>、SELECT <何が何件>
- マージ：main <before 7 桁> → <after 7 桁>
- 配信：<READY の確かめ>（<sha 7 桁>）
- 確かめ：<SELECT の要点>
- 止まったこと：<あれば>
```
