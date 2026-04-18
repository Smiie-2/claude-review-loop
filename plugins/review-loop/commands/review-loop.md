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
set -e

# Fail early if a review loop is already in progress.
if [ -f .review-loop/state.json ]; then
  echo "Error: A review loop is already active. Use /cancel-review first."
  exit 1
fi

# Locate the plugin's shared library (cross-platform: $HOME not ~).
LIB_PATH="$(find "$HOME/.claude/plugins" -path '*/review-loop/scripts/review-lib.sh' 2>/dev/null | head -1)"
if [ -z "$LIB_PATH" ]; then
  LIB_PATH="$(find "$HOME/.claude" -path '*/review-loop/scripts/review-lib.sh' 2>/dev/null | head -1)"
fi
if [ -z "$LIB_PATH" ] || [ ! -r "$LIB_PATH" ]; then
  echo "Error: Could not find review-lib.sh. Is the review-loop plugin installed?"
  exit 1
fi
# shellcheck source=/dev/null
source "$LIB_PATH"

# Resolve and validate the reviewer (codex|gemini).
REVIEWER=$(get_reviewer)
if ! REVIEWER_ERROR=$(ensure_reviewer_ready "$REVIEWER" 2>&1); then
  echo "Error: $REVIEWER_ERROR"
  exit 1
fi
ensure_reviewer_configured "$REVIEWER"

# Generate a unique review ID and prepare state directory.
REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p .review-loop reviews
rm -f .review-loop/lock .review-loop/retries

jq -n \
  --arg rid "$REVIEW_ID" \
  --arg t   "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg task "$ARGUMENTS" \
  '{active: true, phase: "task", review_id: $rid, started_at: $t, task: $task}' \
  > .review-loop/state.json

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
