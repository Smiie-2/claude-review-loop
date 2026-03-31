---
description: "Cancel an active review loop or on-demand Codex review"
allowed-tools:
  - Bash(test -f .claude/review-loop.local.md *)
  - Bash(rm -f .claude/review-loop.local.md .claude/review-loop.lock .claude/review-loop-run-codex.sh .claude/review-loop-codex-prompt.txt .claude/codex-review-run.sh .claude/codex-review-prompt.txt)
  - Read
---

Check if a review loop is active:

```bash
test -f .claude/review-loop.local.md && echo "REVIEW_LOOP_ACTIVE" || echo "REVIEW_LOOP_NONE"
test -f .claude/codex-review-run.sh && echo "CODEX_REVIEW_ACTIVE" || echo "CODEX_REVIEW_NONE"
```

If a review loop is active, read `.claude/review-loop.local.md` to get the current phase and review ID.

Then remove all state files, lock files, and generated Codex files:

```bash
rm -f .claude/review-loop.local.md .claude/review-loop.lock .claude/review-loop-run-codex.sh .claude/review-loop-codex-prompt.txt .claude/codex-review-run.sh .claude/codex-review-prompt.txt
```

Report what was cleaned up:
- If a review loop was active: "Review loop cancelled (was at phase: X, review ID: Y)"
- If an on-demand codex review was active: "On-demand Codex review cancelled"
- If nothing was active: "No active review found."
