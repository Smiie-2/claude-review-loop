---
description: "Cancel an active review loop or on-demand Codex review"
allowed-tools:
  - Bash(test -f .review-loop/* *)
  - Bash(rm -f .review-loop/*)
  - Read
---

Check if any review activity is active:

```bash
test -f .review-loop/state.md && echo "REVIEW_LOOP_ACTIVE" || echo "REVIEW_LOOP_NONE"
test -f .review-loop/codex-review-run.sh && echo "CODEX_REVIEW_ACTIVE" || echo "CODEX_REVIEW_NONE"
```

If a review loop is active, read `.review-loop/state.md` to get the current phase and review ID.

Then remove all state files, lock files, and generated Codex files:

```bash
rm -f .review-loop/state.md .review-loop/lock .review-loop/retries .review-loop/review-loop-run-codex.sh .review-loop/review-loop-codex-prompt.txt .review-loop/codex-review-run.sh .review-loop/codex-review-prompt.txt
```

Report what was cleaned up:
- If a review loop was active: "Review loop cancelled (was at phase: X, review ID: Y)"
- If an on-demand codex review was active: "On-demand Codex review cancelled"
- If nothing was active: "No active review found."
