#!/usr/bin/env bash
# Review Loop — Stop Hook
#
# Two-phase lifecycle:
#   Phase 1 (task):       Claude finishes work → hook prepares reviewer runner script → blocks exit
#   Phase 2 (addressing): Claude runs reviewer, addresses review → hook verifies review exists → allows exit
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Environment variables:
#   REVIEW_LOOP_REVIEWER       Select reviewer: "codex" (default) or "gemini"
#   REVIEW_LOOP_CODEX_FLAGS    Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)
#   REVIEW_LOOP_GEMINI_FLAGS   Override gemini flags (default: --yolo)
#   REVIEW_LOOP_GEMINI_MODEL   Override gemini model (default: CLI default)

LOG_FILE=".review-loop/review-loop.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; rm -f .review-loop/lock .review-loop/review-loop-runner.sh .review-loop/review-loop-prompt.txt .review-loop/review-loop-run-codex.sh .review-loop/review-loop-codex-prompt.txt .review-loop/retries; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Source shared library (prompt building, project detection, reviewer dispatch)
source "$(dirname "$0")/../scripts/review-lib.sh"

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

STATE_FILE=".review-loop/state.md"

# No active loop → allow exit
if [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Parse a field from the YAML frontmatter
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
REVIEW_ID=$(parse_field "review_id")

# Not active → clean up and exit
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid review_id format: $REVIEW_ID"
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# ── Rewrite state file to update phase (atomic, no fragile sed regex) ──────
transition_phase() {
  local new_phase="$1"
  local TEMP_FILE="${STATE_FILE}.tmp.$$"

  awk -v np="$new_phase" '{
    if ($0 ~ /^phase:/) { print "phase: " np }
    else { print }
  }' "$STATE_FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$STATE_FILE"

  local CHECK
  CHECK=$(parse_field "phase")
  if [ "$CHECK" != "$new_phase" ]; then
    log "ERROR: phase transition failed (expected=$new_phase, got=$CHECK)"
    return 1
  fi
  log "Phase transitioned to: $new_phase"
  return 0
}

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Prepare reviewer runner for Claude to run directly ────
    REVIEW_FILE="reviews/review-${REVIEW_ID}.md"
    mkdir -p reviews

    # Clear stale retries from any previous run
    rm -f .review-loop/retries

    REVIEWER=$(get_reviewer)
    REVIEW_PROMPT=$(build_review_prompt "$REVIEW_FILE")
    REVIEWER_FLAGS=$(default_reviewer_flags "$REVIEWER")

    # Validate reviewer CLI is installed
    REVIEWER_ERROR=$(ensure_reviewer_ready "$REVIEWER" 2>&1) || {
      log "ERROR: $REVIEWER_ERROR"
      rm -f "$STATE_FILE"
      REASON="ERROR: ${REVIEWER_ERROR}

Then run /review-loop again."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
        || printf '{"decision":"block","reason":"%s"}\n' "$REVIEWER_ERROR"
      exit 0
    }

    # Reviewer-specific setup (codex: multi_agent config; gemini: no-op)
    if [ "$REVIEWER" = "codex" ]; then
      CODEX_CONFIG="${HOME}/.codex/config.toml"
      if [ ! -f "$CODEX_CONFIG" ] || ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
        log "ERROR: multi_agent not enabled in $CODEX_CONFIG"
        rm -f "$STATE_FILE"
        REASON="ERROR: Codex multi-agent is not enabled in ~/.codex/config.toml. This should have been configured by /review-loop but may have been changed.

Then run /review-loop again."
        jq -n --arg r "$REASON" '{decision:"block", reason:$r}' 2>/dev/null \
          || printf '{"decision":"block","reason":"Codex multi-agent is not enabled in ~/.codex/config.toml"}\n'
        exit 0
      fi
    fi

    # Write prompt to file for the runner script to read
    PROMPT_FILE=".review-loop/review-loop-prompt.txt"
    printf '%s' "$REVIEW_PROMPT" > "$PROMPT_FILE"

    # Generate runner script that Claude will execute via Bash tool
    RUNNER_SCRIPT=".review-loop/review-loop-runner.sh"
    write_runner_script "$PROMPT_FILE" "$RUNNER_SCRIPT" "$REVIEWER_FLAGS" "$LOG_FILE" "$REVIEWER"

    # Transition to addressing phase — fail-open if this breaks
    if ! transition_phase "addressing"; then
      log "ERROR: phase transition failed, cleaning up"
      rm -f "$STATE_FILE" "$RUNNER_SCRIPT" "$PROMPT_FILE"
      printf '{"decision":"approve"}\n'
      exit 0
    fi

    log "Prepared ${REVIEWER} review for Claude to execute (review_id=$REVIEW_ID)"

    REASON="Phase 1 complete. Now run the ${REVIEWER} multi-agent review so you can see its progress.

Execute this command (use a 600000ms timeout since reviews can take several minutes):
\`\`\`
bash .review-loop/review-loop-runner.sh
\`\`\`

After the review completes, read ${REVIEW_FILE} and address the findings:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them
5. Focus on critical and high severity items first
6. When done addressing all relevant items, you may stop

Use your own judgment. Do not blindly accept every suggestion."

    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 2/2: Run ${REVIEWER} review and address feedback"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
      || printf '{"decision":"block","reason":"Phase 1 complete. Run: bash .review-loop/review-loop-runner.sh then address the review.","systemMessage":"%s"}\n' "$SYS_MSG"
    ;;

  addressing)
    # ── Phase 2: verify review was actually produced before allowing exit ──
    REVIEW_FILE="reviews/review-${REVIEW_ID}.md"
    if [ -f "$REVIEW_FILE" ]; then
      # Review exists — success
      log "Review loop complete (review_id=$REVIEW_ID)"
      rm -f "$STATE_FILE" .review-loop/lock .review-loop/review-loop-runner.sh .review-loop/review-loop-prompt.txt .review-loop/retries
      printf '{"decision":"approve"}\n'
    elif [ -f ".review-loop/review-loop-runner.sh" ]; then
      # Runner script exists but review doesn't — check retry limit
      RETRY_FILE=".review-loop/retries"
      RETRY_COUNT=0
      if [ -f "$RETRY_FILE" ]; then
        RETRY_COUNT=$(cat "$RETRY_FILE" 2>/dev/null || echo 0)
      fi
      RETRY_COUNT=$(( RETRY_COUNT + 1 ))

      if [ "$RETRY_COUNT" -ge 2 ]; then
        log "ERROR: reviewer failed to produce review, failing open (review_id=$REVIEW_ID)"
        rm -f "$STATE_FILE" .review-loop/lock .review-loop/review-loop-runner.sh .review-loop/review-loop-prompt.txt "$RETRY_FILE"
        printf '{"decision":"approve"}\n'
      else
        echo "$RETRY_COUNT" > "$RETRY_FILE"
        log "Review file not found ($REVIEW_FILE), prompting Claude to run reviewer"
        REASON="The review has not been completed yet. Please run the review script (use a 600000ms timeout since reviews can take several minutes):

\`\`\`
bash .review-loop/review-loop-runner.sh
\`\`\`

Then read ${REVIEW_FILE} and address the findings."
        SYS_MSG="Review Loop [${REVIEW_ID}] — review not yet complete"
        jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
          '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
          || printf '{"decision":"block","reason":"Review not yet complete. Run: bash .review-loop/review-loop-runner.sh","systemMessage":"%s"}\n' "$SYS_MSG"
      fi
    else
      # Neither review nor runner script — orphaned state, fail-open
      log "ERROR: review file and runner script both missing, cleaning up (review_id=$REVIEW_ID)"
      rm -f "$STATE_FILE" .review-loop/lock .review-loop/review-loop-prompt.txt .review-loop/retries
      printf '{"decision":"approve"}\n'
    fi
    ;;

  *)
    # Unknown phase — clean up and allow exit
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE" .review-loop/lock .review-loop/review-loop-runner.sh .review-loop/review-loop-prompt.txt
    printf '{"decision":"approve"}\n'
    ;;
esac
