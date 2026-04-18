#!/usr/bin/env bash
# Integration tests for stop-hook.sh
#
# Run from the repo root: bash plugins/review-loop/scripts/test-stop-hook.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/stop-hook.sh"

PASS=0
FAIL=0
TESTS=0

# ── Test setup: create a temp dir to work in ──
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

run_hook() {
  # Run the stop hook in the temp dir, piping empty JSON as hook input
  cd "$TMPDIR"
  echo '{}' | bash "$HOOK_SCRIPT" 2>/dev/null
}

assert_decision() {
  local label="$1" expected="$2" json="$3"
  TESTS=$((TESTS + 1))
  local actual
  actual=$(echo "$json" | jq -r '.decision' 2>/dev/null || echo "INVALID_JSON")
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (expected decision='$expected', got='$actual', json='$json')"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  TESTS=$((TESTS + 1))
  if [ -f "$TMPDIR/$path" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (file not found: $path)"
  fi
}

assert_file_missing() {
  local label="$1" path="$2"
  TESTS=$((TESTS + 1))
  if [ ! -f "$TMPDIR/$path" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (file should not exist: $path)"
  fi
}

reset_tmpdir() {
  rm -rf "$TMPDIR"
  TMPDIR="$(mktemp -d)"
}

write_state() {
  local phase="$1" review_id="$2"
  mkdir -p "$TMPDIR/.review-loop"
  jq -n \
    --arg phase "$phase" \
    --arg rid "$review_id" \
    '{active:true, phase:$phase, review_id:$rid, started_at:"2026-03-31T12:00:00Z", task:"test task"}' \
    > "$TMPDIR/.review-loop/state.json"
}

VALID_ID="20260331-120000-abc123"

echo "=== No state file → approve ==="
reset_tmpdir
RESULT=$(run_hook)
assert_decision "no state → approve" "approve" "$RESULT"

echo ""
echo "=== Inactive state → approve + cleanup ==="
reset_tmpdir
mkdir -p "$TMPDIR/.review-loop"
jq -n '{active:false, phase:"task", review_id:"20260331-120000-abc123", started_at:"2026-03-31T12:00:00Z", task:"test"}' > "$TMPDIR/.review-loop/state.json"
RESULT=$(run_hook)
assert_decision "inactive → approve" "approve" "$RESULT"
assert_file_missing "state cleaned up" ".review-loop/state.json"

echo ""
echo "=== Invalid review_id → approve (fail-open) ==="
reset_tmpdir
mkdir -p "$TMPDIR/.review-loop"
jq -n '{active:true, phase:"task", review_id:"../../etc/passwd", started_at:"2026-03-31T12:00:00Z", task:"test"}' > "$TMPDIR/.review-loop/state.json"
RESULT=$(run_hook)
assert_decision "invalid id → approve" "approve" "$RESULT"
assert_file_missing "state cleaned up" ".review-loop/state.json"

echo ""
echo "=== Task phase → block + runner script created ==="
reset_tmpdir
write_state "task" "$VALID_ID"
RESULT=$(run_hook)
assert_decision "task → block" "block" "$RESULT"
assert_file_exists "runner script created" ".review-loop/review-loop-runner.sh"
assert_file_exists "prompt file created" ".review-loop/review-loop-prompt.txt"

echo ""
echo "=== Task phase clears stale retries ==="
reset_tmpdir
write_state "task" "$VALID_ID"
mkdir -p "$TMPDIR/.review-loop"
echo "1" > "$TMPDIR/.review-loop/retries"
run_hook > /dev/null
assert_file_missing "stale retries cleared" ".review-loop/retries"

echo ""
echo "=== Addressing with review → approve + cleanup ==="
reset_tmpdir
write_state "addressing" "$VALID_ID"
mkdir -p "$TMPDIR/reviews"
echo "review content" > "$TMPDIR/reviews/review-${VALID_ID}.md"
RESULT=$(run_hook)
assert_decision "addressing with review → approve" "approve" "$RESULT"
assert_file_missing "state cleaned up" ".review-loop/state.json"

echo ""
echo "=== Addressing without review, first attempt → block ==="
reset_tmpdir
write_state "addressing" "$VALID_ID"
mkdir -p "$TMPDIR/.review-loop"
touch "$TMPDIR/.review-loop/review-loop-runner.sh"
RESULT=$(run_hook)
assert_decision "addressing no review, try 1 → block" "block" "$RESULT"
assert_file_exists "retry file created" ".review-loop/retries"

echo ""
echo "=== Addressing without review, second attempt → approve (fail-open) ==="
reset_tmpdir
write_state "addressing" "$VALID_ID"
mkdir -p "$TMPDIR/.review-loop"
touch "$TMPDIR/.review-loop/review-loop-runner.sh"
echo "1" > "$TMPDIR/.review-loop/retries"
RESULT=$(run_hook)
assert_decision "addressing no review, try 2 → approve" "approve" "$RESULT"
assert_file_missing "state cleaned up after fail-open" ".review-loop/state.json"
assert_file_missing "retries cleaned up" ".review-loop/retries"

echo ""
echo "=== Unknown phase → approve (fail-open) ==="
reset_tmpdir
write_state "unknown_phase" "$VALID_ID"
RESULT=$(run_hook)
assert_decision "unknown phase → approve" "approve" "$RESULT"
assert_file_missing "state cleaned up" ".review-loop/state.json"

echo ""
echo "=== Addressing, no runner and no review → approve (orphan cleanup) ==="
reset_tmpdir
write_state "addressing" "$VALID_ID"
RESULT=$(run_hook)
assert_decision "orphan addressing → approve" "approve" "$RESULT"
assert_file_missing "state cleaned up" ".review-loop/state.json"

echo ""
echo "==============================="
echo "Results: $PASS/$TESTS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
