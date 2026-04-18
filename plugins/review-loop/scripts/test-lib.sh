#!/usr/bin/env bash
# Smoke tests for review-lib.sh
#
# Run from the repo root: bash plugins/review-loop/scripts/test-lib.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/review-lib.sh"

PASS=0
FAIL=0
TESTS=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TESTS=$((TESTS + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (expected='$expected', got='$actual')"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TESTS=$((TESTS + 1))
  if echo "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (expected to contain '$needle')"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  TESTS=$((TESTS + 1))
  if echo "$haystack" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (should NOT contain '$needle')"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  TESTS=$((TESTS + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (file not found: $path)"
  fi
}

# ── Test setup: create a temp dir to work in ──
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"

echo "=== detect_nextjs ==="

assert_eq "no next project" "1" "$(detect_nextjs && echo 0 || echo 1)"

touch next.config.js
assert_eq "next.config.js exists" "0" "$(detect_nextjs && echo 0 || echo 1)"
rm next.config.js

echo '{"dependencies":{"next":"14.0.0"}}' > package.json
assert_eq "next in package.json" "0" "$(detect_nextjs && echo 0 || echo 1)"
rm package.json

echo ""
echo "=== detect_browser_ui ==="

assert_eq "no UI dirs" "1" "$(detect_browser_ui && echo 0 || echo 1)"

mkdir app
assert_eq "app/ exists" "0" "$(detect_browser_ui && echo 0 || echo 1)"
rmdir app

touch index.html
assert_eq "index.html exists" "0" "$(detect_browser_ui && echo 0 || echo 1)"
rm index.html

mkdir public
assert_eq "public/ exists" "0" "$(detect_browser_ui && echo 0 || echo 1)"
rmdir public

echo ""
echo "=== ensure_codex_ready ==="

OUTPUT=$(PATH=/nonexistent ensure_codex_ready 2>&1) || true
assert_contains "codex not installed message" "not installed" "$OUTPUT"

echo ""
echo "=== ensure_multi_agent_configured ==="

export HOME="$TMPDIR/fakehome"
mkdir -p "$HOME"

# Test 1: auto-creation of config
OUTPUT=$(ensure_multi_agent_configured 2>&1)
assert_file_exists "config.toml created" "$HOME/.codex/config.toml"
assert_contains "config has multi_agent" "multi_agent = true" "$(cat "$HOME/.codex/config.toml")"

# Test 2: idempotent — running again should produce no output
OUTPUT=$(ensure_multi_agent_configured 2>&1)
assert_eq "idempotent (no output on second run)" "" "$OUTPUT"

# Test 3: rewrite multi_agent = false → true (fix for review finding #1)
rm -rf "$HOME/.codex"
mkdir -p "$HOME/.codex"
printf '[features]\nmulti_agent = false\n' > "$HOME/.codex/config.toml"
OUTPUT=$(ensure_multi_agent_configured 2>&1)
assert_contains "rewrote false to true" "multi_agent = true" "$(cat "$HOME/.codex/config.toml")"
# Verify no duplicate keys
MULTI_COUNT=$(grep -c 'multi_agent' "$HOME/.codex/config.toml")
assert_eq "no duplicate multi_agent keys" "1" "$MULTI_COUNT"

# Test 4: adding to existing config without [features]
rm -rf "$HOME/.codex"
mkdir -p "$HOME/.codex"
echo '[model]
name = "gpt-4"' > "$HOME/.codex/config.toml"
OUTPUT=$(ensure_multi_agent_configured 2>&1)
assert_contains "appended features section" "multi_agent = true" "$(cat "$HOME/.codex/config.toml")"
assert_contains "preserved existing config" 'name = "gpt-4"' "$(cat "$HOME/.codex/config.toml")"

echo ""
echo "=== build_review_prompt ==="

PROMPT=$(build_review_prompt "reviews/test-review.md")
assert_contains "has review file path" "reviews/test-review.md" "$PROMPT"
assert_contains "has diff agent" "AGENT 1: Diff Review" "$PROMPT"
assert_contains "has holistic agent" "AGENT 2: Holistic Review" "$PROMPT"
assert_contains "has consolidation" "CONSOLIDATION INSTRUCTIONS" "$PROMPT"

# Without next.js/UI, should NOT have those agents
PROMPT_NO_FRAMEWORK=$(build_review_prompt "reviews/test.md")
assert_not_contains "next.js agent excluded" "Next.js & React" "$PROMPT_NO_FRAMEWORK"

echo ""
echo "=== write_runner_script ==="

mkdir -p .review-loop
echo "test prompt" > .review-loop/test-prompt.txt
write_runner_script ".review-loop/test-prompt.txt" ".review-loop/test-runner.sh" "--sandbox" ".review-loop/test.log"
assert_file_exists "runner script created" ".review-loop/test-runner.sh"
assert_contains "runner is executable" "x" "$(stat -c %A .review-loop/test-runner.sh 2>/dev/null || stat -f %Sp .review-loop/test-runner.sh 2>/dev/null)"
assert_contains "uses correct prompt file" ".review-loop/test-prompt.txt" "$(cat .review-loop/test-runner.sh)"
assert_contains "uses correct log file" ".review-loop/test.log" "$(cat .review-loop/test-runner.sh)"
assert_contains "uses correct flags" "--sandbox" "$(cat .review-loop/test-runner.sh)"

echo ""
echo "=== source guard ==="

assert_eq "guard var set" "1" "${_REVIEW_LIB:-0}"

echo ""
echo "=== get_reviewer ==="

unset REVIEW_LOOP_REVIEWER
# Default (no config, no env) → codex
assert_eq "default reviewer" "codex" "$(get_reviewer)"

# Env var override
assert_eq "env var gemini" "gemini" "$(REVIEW_LOOP_REVIEWER=gemini get_reviewer)"

# Unknown value falls back to codex
assert_eq "unknown env falls back" "codex" "$(REVIEW_LOOP_REVIEWER=foo get_reviewer)"

# Project config file
mkdir -p .review-loop
echo 'reviewer = "gemini"' > .review-loop/config.toml
assert_eq "project config gemini" "gemini" "$(get_reviewer)"
echo 'reviewer = "codex"' > .review-loop/config.toml
assert_eq "project config codex" "codex" "$(get_reviewer)"
rm -rf .review-loop

echo ""
echo "=== ensure_gemini_ready ==="
OUTPUT=$(PATH=/nonexistent ensure_gemini_ready 2>&1) || true
assert_contains "gemini not installed message" "not installed" "$OUTPUT"

echo ""
echo "=== default_reviewer_flags ==="
assert_contains "codex default flags" "dangerously-bypass" "$(default_reviewer_flags codex)"
assert_eq "gemini default flags" "--yolo" "$(default_reviewer_flags gemini)"
assert_eq "codex env override" "--custom" "$(REVIEW_LOOP_CODEX_FLAGS=--custom default_reviewer_flags codex)"
assert_eq "gemini env override" "--custom" "$(REVIEW_LOOP_GEMINI_FLAGS=--custom default_reviewer_flags gemini)"

echo ""
echo "=== write_runner_script: gemini variant ==="
mkdir -p .review-loop
echo "prompt" > .review-loop/g-prompt.txt
write_runner_script ".review-loop/g-prompt.txt" ".review-loop/g-runner.sh" "--yolo" ".review-loop/g.log" "gemini"
assert_contains "gemini runner invokes gemini" "gemini " "$(cat .review-loop/g-runner.sh)"
assert_contains "gemini runner has yolo flag" "--yolo" "$(cat .review-loop/g-runner.sh)"
assert_contains "gemini runner records reviewer" 'REVIEWER="gemini"' "$(cat .review-loop/g-runner.sh)"

echo ""
echo "==============================="
echo "Results: $PASS/$TESTS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
