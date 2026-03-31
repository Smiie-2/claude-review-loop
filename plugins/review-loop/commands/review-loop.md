---
description: "Start a review loop: implement task, get independent Codex review, address feedback"
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
set -e && REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')" && mkdir -p .claude reviews && if [ -f .claude/review-loop.local.md ]; then echo "Error: A review loop is already active. Use /cancel-review first." && exit 1; fi && LIB_PATH="$(find ~/.claude -path '*/review-loop/scripts/codex-review-lib.sh' 2>/dev/null | head -1)" && if [ -z "$LIB_PATH" ]; then echo "Error: Could not find codex-review-lib.sh. Is the review-loop plugin installed?"; exit 1; fi && source "$LIB_PATH" && CODEX_ERROR=$(ensure_codex_ready 2>&1) || { echo "Error: $CODEX_ERROR"; exit 1; } && ensure_multi_agent_configured && rm -f .claude/review-loop.lock && cat > .claude/review-loop.local.md << STATE_EOF
---
active: true
phase: task
review_id: ${REVIEW_ID}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

$ARGUMENTS
STATE_EOF
echo "Review Loop activated (ID: ${REVIEW_ID})"
```

After setup completes successfully, proceed to implement the task described in the arguments. Work thoroughly and completely — write clean, well-structured, well-tested code.

When you believe the task is fully done, stop. The review loop stop hook will automatically:
1. Prepare a Codex runner script and prompt file
2. Block your exit with instructions to run the review

You will then run `bash .claude/review-loop-run-codex.sh` to execute the Codex review (output streams to the user for visibility). After Codex finishes, read the review file and address the findings.

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- When blocked by the hook, run the Codex script as instructed and address the review
