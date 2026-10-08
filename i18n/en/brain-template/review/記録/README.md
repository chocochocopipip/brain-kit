---
date: 2026-01-01
project: none
tags: [review, log]
---

# Log (append-only)

In `YYYY-MM-DD.md`, one block per review. Never rewrite a verdict afterwards. Correct it with a new block.

```
## <repo>#<PR> <title> (YYYY-MM-DD HH:MM, criteria version N)
- Verdict: OK / NG ("Type A" if Type A)
- Items applied: A1 A2 ... (with results)
- Another model: whether used, findings taken / not taken
- Findings:
  1. <file:line> — <what> — <reproduction / expected> — <condition that makes it OK once fixed>
- Outside the criteria: ...
- Time taken: NN min
```
