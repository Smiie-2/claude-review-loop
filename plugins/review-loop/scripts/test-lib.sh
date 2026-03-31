#!/usr/bin/env bash
# Smoke tests for codex-review-lib.sh
#
# Run from the repo root: bash plugins/review-loop/scripts/test-lib.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/codex-review-lib.sh"

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

# No next.config → should fail
assert_eq "no next project" "1" "$(detect_nextjs && echo 0 || echo 1)"

# With next.config.js → should pass
touch next.config.js
assert_eq "next.config.js exists" "0" "$(detect_nextjs && echo 0 || echo 1)"
rm next.config.js

# With next in package.json → should pass
echo '{"dependencies":{"next":"14.0.0"}}' > package.json
assert_eq "next in package.json" "0" "$(detect_nextjs && echo 0 || echo 1)"
rm package.json

echo ""
echo "=== detect_browser_ui ==="

# No UI dirs → should fail
assert_eq "no UI dirs" "1" "$(detect_browser_ui && echo 0 || echo 1)"

# With app/ → should pass
mkdir app
assert_eq "app/ exists" "0" "$(detect_browser_ui && echo 0 || echo 1)"
rmdir app

# With index.html → should pass
touch index.html
assert_eq "index.html exists" "0" "$(detect_browser_ui && echo 0 || echo 1)"
rm index.html

# With public/ → should pass
mkdir public
assert_eq "public/ exists" "0" "$(detect_browser_ui && echo 0 || echo 1)"
rmdir public

echo ""
echo "=== ensure_codex_ready ==="

# Test with codex not on PATH (fake PATH to ensure codex isn't found)
OUTPUT=$(PATH=/nonexistent ensure_codex_ready 2>&1) || true
assert_contains "codex not installed message" "not installed" "$OUTPUT"

echo ""
echo "=== ensure_multi_agent_configured ==="

# Test auto-creation of config
export HOME="$TMPDIR/fakehome"
mkdir -p "$HOME"
OUTPUT=$(ensure_multi_agent_configured 2>&1)
assert_file_exists "config.toml created" "$HOME/.codex/config.toml"
assert_contains "config has multi_agent" "multi_agent = true" "$(cat "$HOME/.codex/config.toml")"

# Test idempotent — running again should not error
OUTPUT=$(ensure_multi_agent_configured 2>&1)
assert_eq "idempotent (no output on second run)" "" "$OUTPUT"

# Test adding to existing config without [features]
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
if echo "$PROMPT_NO_FRAMEWORK" | grep -q "Next.js & React"; then
  TESTS=$((TESTS + 1)); FAIL=$((FAIL + 1))
  echo "  FAIL: next.js agent included without next project"
else
  TESTS=$((TESTS + 1)); PASS=$((PASS + 1))
  echo "  PASS: next.js agent excluded without next project"
fi

echo ""
echo "=== write_runner_script ==="

mkdir -p .claude
echo "test prompt" > .claude/test-prompt.txt
write_runner_script ".claude/test-prompt.txt" ".claude/test-runner.sh" "--sandbox" ".claude/test.log"
assert_file_exists "runner script created" ".claude/test-runner.sh"
assert_contains "runner is executable" "x" "$(stat -c %A .claude/test-runner.sh 2>/dev/null || stat -f %Sp .claude/test-runner.sh 2>/dev/null)"
assert_contains "uses correct prompt file" ".claude/test-prompt.txt" "$(cat .claude/test-runner.sh)"
assert_contains "uses correct log file" ".claude/test.log" "$(cat .claude/test-runner.sh)"
assert_contains "uses correct flags" "--sandbox" "$(cat .claude/test-runner.sh)"

echo ""
echo "=== source guard ==="

# Sourcing again should be a no-op (guard prevents re-definition)
assert_eq "guard var set" "1" "${_CODEX_REVIEW_LIB:-0}"

echo ""
echo "==============================="
echo "Results: $PASS/$TESTS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
