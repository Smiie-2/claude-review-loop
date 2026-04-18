---
description: "Start a review loop: implement task, get independent multi-agent review (Codex or Gemini), address feedback"
argument-hint: "<task description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, set up the review loop by running this setup command:

```bash
set -e && REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')" && mkdir -p .review-loop reviews && if [ -f .review-loop/state.md ]; then echo "Error: A review loop is already active. Use /cancel-review first." && exit 1; fi && LIB_PATH="$(find "$HOME/.claude/plugins" -path '*/review-loop/scripts/review-lib.sh' 2>/dev/null | head -1)" && if [ -z "$LIB_PATH" ]; then LIB_PATH="$(find "$HOME/.claude" -path '*/review-loop/scripts/review-lib.sh' 2>/dev/null | head -1)"; fi && if [ -z "$LIB_PATH" ] || [ ! -r "$LIB_PATH" ]; then echo "Error: Could not find review-lib.sh. Is the review-loop plugin installed?"; exit 1; fi && source "$LIB_PATH" && REVIEWER=$(get_reviewer) && REVIEWER_ERROR=$(ensure_reviewer_ready "$REVIEWER" 2>&1) || { echo "Error: $REVIEWER_ERROR"; exit 1; } && ensure_reviewer_configured "$REVIEWER" && rm -f .review-loop/lock .review-loop/retries && cat > .review-loop/state.md << STATE_EOF
---
active: true
phase: task
review_id: ${REVIEW_ID}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

$ARGUMENTS
STATE_EOF
echo "Review Loop activated (reviewer=${REVIEWER}, ID: ${REVIEW_ID})"
```

After setup completes successfully, proceed to implement the task described in the arguments. Work thoroughly and completely — write clean, well-structured, well-tested code.

When you believe the task is fully done, stop. The review loop stop hook will automatically:
1. Prepare a reviewer runner script and prompt file
2. Block your exit with instructions to run the review

You will then run `bash .review-loop/review-loop-runner.sh` to execute the review (output streams to the user for visibility). After the reviewer finishes, read the review file and address the findings.

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- When blocked by the hook, run the runner script as instructed and address the review
