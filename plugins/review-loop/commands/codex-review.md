---
description: "Run an on-demand multi-agent code review of current changes (Codex or Gemini)"
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

Run the following setup command to prepare and execute the review:

```bash
set -e

REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p .review-loop reviews

# Find the shared library from the installed plugin (cross-platform: $HOME not ~)
LIB_PATH="$(find "$HOME/.claude/plugins" -path '*/review-loop/scripts/review-lib.sh' 2>/dev/null | head -1)"
if [ -z "$LIB_PATH" ]; then
  LIB_PATH="$(find "$HOME/.claude" -path '*/review-loop/scripts/review-lib.sh' 2>/dev/null | head -1)"
fi
if [ -z "$LIB_PATH" ] || [ ! -r "$LIB_PATH" ]; then
  echo "ERROR: Could not find review-lib.sh. Is the review-loop plugin installed?"
  exit 1
fi
source "$LIB_PATH"

# Resolve reviewer (env var → project config → global config → codex default)
REVIEWER=$(get_reviewer)

# Validate reviewer CLI is installed
REVIEWER_ERROR=$(ensure_reviewer_ready "$REVIEWER" 2>&1) || { echo "ERROR: $REVIEWER_ERROR"; exit 1; }

# Reviewer-specific setup (codex: ensure multi_agent; gemini: no-op)
ensure_reviewer_configured "$REVIEWER"

REVIEW_FILE="reviews/review-${REVIEW_ID}.md"
REVIEWER_FLAGS=$(default_reviewer_flags "$REVIEWER")
# Temp file names are prefixed by the *command* (`codex-review-`), not the
# reviewer — this keeps them distinct from /review-loop's `review-loop-*`
# files regardless of which reviewer is active.
PROMPT_FILE=".review-loop/codex-review-prompt.txt"
RUNNER_SCRIPT=".review-loop/codex-review-run.sh"

# Build prompt and runner script
build_review_prompt "$REVIEW_FILE" > "$PROMPT_FILE"
write_runner_script "$PROMPT_FILE" "$RUNNER_SCRIPT" "$REVIEWER_FLAGS" ".review-loop/codex-review.log" "$REVIEWER"

echo "Review prepared (reviewer=${REVIEWER}, ID: ${REVIEW_ID})"
echo "REVIEW_FILE=${REVIEW_FILE}"
echo "RUNNER_SCRIPT=${RUNNER_SCRIPT}"
```

After setup completes, run the review (use a 600000ms timeout since reviews can take several minutes):

```bash
bash .review-loop/codex-review-run.sh
```

After the review finishes, read the review file (the path was printed as REVIEW_FILE in the setup output) and present the findings to the user, organized by severity.

Then clean up the temporary files:

```bash
rm -f .review-loop/codex-review-run.sh .review-loop/codex-review-prompt.txt .review-loop/codex-review.log
```

RULES:
- This is an informational review — present findings clearly but do NOT automatically fix anything
- Organize findings by severity: critical first, then high, medium, low
- For each finding, include the file path, severity, and description
- Let the user decide which findings to address
- If the review fails or produces no output, report the failure and clean up
