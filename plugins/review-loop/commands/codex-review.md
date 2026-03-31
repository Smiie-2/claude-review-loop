---
description: "Run an on-demand Codex multi-agent code review of current changes"
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

Run the following setup command to prepare and execute a Codex review:

```bash
set -e

REVIEW_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p .review-loop reviews

# Find the shared library from the installed plugin (cross-platform: $HOME not ~)
LIB_PATH="$(find "$HOME/.claude/plugins" -path '*/review-loop/scripts/codex-review-lib.sh' 2>/dev/null | head -1)"
if [ -z "$LIB_PATH" ]; then
  LIB_PATH="$(find "$HOME/.claude" -path '*/review-loop/scripts/codex-review-lib.sh' 2>/dev/null | head -1)"
fi
if [ -z "$LIB_PATH" ] || [ ! -r "$LIB_PATH" ]; then
  echo "ERROR: Could not find codex-review-lib.sh. Is the review-loop plugin installed?"
  exit 1
fi
source "$LIB_PATH"

# Validate Codex is installed
CODEX_ERROR=$(ensure_codex_ready 2>&1) || { echo "ERROR: $CODEX_ERROR"; exit 1; }

# Ensure multi-agent is configured (auto-configures if needed)
ensure_multi_agent_configured

REVIEW_FILE="reviews/review-${REVIEW_ID}.md"
CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
PROMPT_FILE=".review-loop/codex-review-prompt.txt"
RUNNER_SCRIPT=".review-loop/codex-review-run.sh"

# Build prompt and runner script
build_review_prompt "$REVIEW_FILE" > "$PROMPT_FILE"
write_runner_script "$PROMPT_FILE" "$RUNNER_SCRIPT" "$CODEX_FLAGS" ".review-loop/codex-review.log"

echo "Codex review prepared (ID: ${REVIEW_ID})"
echo "REVIEW_FILE=${REVIEW_FILE}"
echo "RUNNER_SCRIPT=${RUNNER_SCRIPT}"
```

After setup completes, run the Codex review (use a 600000ms timeout since reviews can take several minutes):

```bash
bash .review-loop/codex-review-run.sh
```

After the review finishes, read the review file (the path was printed as REVIEW_FILE in the setup output) and present the findings to the user, organized by severity.

Then clean up the temporary files:

```bash
rm -f .review-loop/codex-review-run.sh .review-loop/codex-review-prompt.txt
```

RULES:
- This is an informational review — present findings clearly but do NOT automatically fix anything
- Organize findings by severity: critical first, then high, medium, low
- For each finding, include the file path, severity, and description
- Let the user decide which findings to address
- If the Codex review fails or produces no output, report the failure and clean up
