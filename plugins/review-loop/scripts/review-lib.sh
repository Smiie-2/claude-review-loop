#!/usr/bin/env bash
# review-lib.sh — Shared functions for multi-agent code review
#
# Supports pluggable reviewers: Codex (default) and Gemini.
# Sourced by stop-hook.sh and the /codex-review command.
# Contains only function definitions — no side effects on source.

[[ -n "${_REVIEW_LIB:-}" ]] && return 0
_REVIEW_LIB=1

# Resolve library + prompts directory at source time so paths work regardless
# of the caller's cwd.
_REVIEW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REVIEW_PROMPTS_DIR="${_REVIEW_LIB_DIR}/../prompts"

# ── Project type detection ────────────────────────────────────────────────
detect_nextjs() {
  [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ] || \
    ([ -f "package.json" ] && grep -q '"next"' package.json 2>/dev/null)
}

detect_browser_ui() {
  [ -d "app" ] || [ -d "pages" ] || [ -d "src/app" ] || [ -d "src/pages" ] || \
    [ -d "public" ] || [ -f "index.html" ]
}

# ── Reviewer selection ────────────────────────────────────────────────────
# Resolution order:
#   1. REVIEW_LOOP_REVIEWER env var
#   2. .review-loop/config.toml          (per-project override)
#   3. ~/.config/review-loop/config.toml (global)
#   4. Default: codex
# Unknown values fall back to codex.
get_reviewer() {
  local reviewer="" src=""
  if [ -n "${REVIEW_LOOP_REVIEWER:-}" ]; then
    reviewer="$REVIEW_LOOP_REVIEWER"
  elif [ -f ".review-loop/config.toml" ]; then
    src=".review-loop/config.toml"
  elif [ -f "${HOME}/.config/review-loop/config.toml" ]; then
    src="${HOME}/.config/review-loop/config.toml"
  fi

  if [ -n "$src" ]; then
    # Tolerant TOML parse: skip blank/comment lines; strip trailing '# comment';
    # accept reviewer = "x", 'x', or bare x; ignore surrounding whitespace.
    reviewer=$(awk '
      /^[[:space:]]*#/    { next }
      /^[[:space:]]*$/    { next }
      /^[[:space:]]*reviewer[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        sub(/[[:space:]]*#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/^["\x27]|["\x27]$/, "")
        print
        exit
      }
    ' "$src")
  fi

  # Unknown values fall back to codex rather than fallthrough to the next
  # resolution source — a typo in the project config should be obvious
  # (everything falls back to codex) rather than silently promoted by
  # whichever global config happens to exist.
  case "$reviewer" in
    codex|gemini) echo "$reviewer" ;;
    *) echo "codex" ;;
  esac
}

# ── CLI availability checks ───────────────────────────────────────────────
# Each writes an install hint to stdout on failure. Return 0 on success.
ensure_codex_ready() {
  if ! command -v codex &> /dev/null; then
    echo "Codex CLI is not installed. Install it: npm install -g @openai/codex"
    return 1
  fi
  return 0
}

ensure_gemini_ready() {
  if ! command -v gemini &> /dev/null; then
    echo "Gemini CLI is not installed. Install it: npm install -g @google/gemini-cli"
    return 1
  fi
  return 0
}

# Dispatcher: validates the currently-selected reviewer.
# Args: $1 = reviewer name (codex|gemini)
ensure_reviewer_ready() {
  local reviewer="$1"
  case "$reviewer" in
    codex)  ensure_codex_ready  ;;
    gemini) ensure_gemini_ready ;;
    *) echo "Unknown reviewer: $reviewer (expected: codex|gemini)"; return 1 ;;
  esac
}

# ── Ensure multi-agent is configured in ~/.codex/config.toml ─────────────
# Codex-only — Gemini CLI has no equivalent multi-agent config flag.
# Auto-configures if missing or set to false. Returns 0 on success.
# Handles macOS/Linux sed -i differences.
ensure_multi_agent_configured() {
  local CODEX_CONFIG="${HOME}/.codex/config.toml"

  if [ ! -f "$CODEX_CONFIG" ]; then
    mkdir -p "${HOME}/.codex"
    printf '[features]\nmulti_agent = true\n' > "$CODEX_CONFIG"
    echo "Created ~/.codex/config.toml with multi_agent enabled"
  elif grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
    :
  elif grep -qE '^\s*multi_agent\s*=' "$CODEX_CONFIG"; then
    if [ "$(uname)" = "Darwin" ]; then
      sed -i '' 's/^\([[:space:]]*\)multi_agent[[:space:]]*=.*/\1multi_agent = true/' "$CODEX_CONFIG"
    else
      sed -i 's/^\(\s*\)multi_agent\s*=.*/\1multi_agent = true/' "$CODEX_CONFIG"
    fi
    echo "Updated multi_agent to true in ~/.codex/config.toml"
  elif grep -qE '^\[features\]' "$CODEX_CONFIG"; then
    if [ "$(uname)" = "Darwin" ]; then
      sed -i '' '/^\[features\]/a\'$'\n''multi_agent = true' "$CODEX_CONFIG"
    else
      sed -i '/^\[features\]/a multi_agent = true' "$CODEX_CONFIG"
    fi
    echo "Enabled multi_agent in ~/.codex/config.toml"
  else
    printf '\n[features]\nmulti_agent = true\n' >> "$CODEX_CONFIG"
    echo "Enabled multi_agent in ~/.codex/config.toml"
  fi
  return 0
}

# Dispatcher: configures the selected reviewer if it needs setup.
# Args: $1 = reviewer name
ensure_reviewer_configured() {
  local reviewer="$1"
  case "$reviewer" in
    codex)  ensure_multi_agent_configured ;;
    gemini) : ;;  # no equivalent config step
    *) echo "Unknown reviewer: $reviewer"; return 1 ;;
  esac
}

# ── Load a prompt template and substitute {{REVIEW_FILE}} ─────────────────
# Args: $1 = template filename (under prompts/), $2 = REVIEW_FILE value
_render_prompt() {
  local name="$1" review_file="$2" path="${_REVIEW_PROMPTS_DIR}/$1"
  if [ ! -r "$path" ]; then
    echo "ERROR: prompt template missing: $path" >&2
    return 1
  fi
  local content
  content="$(cat "$path")"
  printf '%s' "${content//\{\{REVIEW_FILE\}\}/${review_file}}"
}

# ── Build the multi-agent review prompt ───────────────────────────────────
# Args: $1 = REVIEW_FILE path (where the reviewer should write the consolidated review)
#
# The prompt is reviewer-agnostic. Both Codex (via the `multi_agent` config
# feature) and Gemini CLI v0.38+ (via its subagent runtime / skills + @-syntax)
# support spawning parallel review agents; each runtime maps the prompt to its
# own parallel-execution primitives. The consolidated output is identical.
#
# Templates live in plugins/review-loop/prompts/ and use {{REVIEW_FILE}} as a
# placeholder.
build_review_prompt() {
  local REVIEW_FILE="$1"

  _render_prompt preamble.md       "$REVIEW_FILE"
  _render_prompt agent-diff.md     "$REVIEW_FILE"
  _render_prompt agent-holistic.md "$REVIEW_FILE"
  detect_nextjs     && _render_prompt agent-nextjs.md "$REVIEW_FILE"
  detect_browser_ui && _render_prompt agent-ux.md     "$REVIEW_FILE"
  _render_prompt consolidation.md  "$REVIEW_FILE"
}

# ── Default CLI flags for the selected reviewer ───────────────────────────
# Honors REVIEW_LOOP_CODEX_FLAGS / REVIEW_LOOP_GEMINI_FLAGS overrides.
# `--yolo` (gemini) and `--dangerously-bypass-approvals-and-sandbox` (codex)
# both disable all approval prompts so the reviewer can run unattended. Users
# who want sandboxed/interactive reviews should override via the env vars.
default_reviewer_flags() {
  local reviewer="$1"
  case "$reviewer" in
    gemini)  echo "${REVIEW_LOOP_GEMINI_FLAGS:---yolo}" ;;
    codex|*) echo "${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}" ;;
  esac
}

# ── Write the reviewer runner script ──────────────────────────────────────
# Args:
#   $1 = PROMPT_FILE
#   $2 = RUNNER_SCRIPT
#   $3 = REVIEWER_FLAGS  (CLI flags for the selected reviewer)
#   $4 = LOG_FILE        (optional, default .review-loop/review-loop.log)
#   $5 = REVIEWER        (optional, default "codex")
#
# Note: reviewer, flags, and model are baked into the generated script at
# generation time (not at execution time). Changing REVIEW_LOOP_* env vars
# after setup has no effect on an already-written runner — regenerate to pick
# up new values.
write_runner_script() {
  local PROMPT_FILE="$1"
  local RUNNER_SCRIPT="$2"
  local REVIEWER_FLAGS="$3"
  local LOG_FILE="${4:-.review-loop/review-loop.log}"
  local REVIEWER="${5:-codex}"

  local INVOKE_LINE
  case "$REVIEWER" in
    gemini)
      local GEMINI_MODEL="${REVIEW_LOOP_GEMINI_MODEL:-}"
      local MODEL_FLAG=""
      # Quote the model value so a name containing spaces doesn't split the arg.
      [ -n "$GEMINI_MODEL" ] && MODEL_FLAG="-m \"${GEMINI_MODEL}\""
      INVOKE_LINE="gemini ${MODEL_FLAG} ${REVIEWER_FLAGS} -p \"\$(cat \"\$PROMPT_FILE\")\""
      ;;
    codex|*)
      INVOKE_LINE="codex ${REVIEWER_FLAGS} exec \"\$(cat \"\$PROMPT_FILE\")\""
      ;;
  esac

  cat > "$RUNNER_SCRIPT" << RUNNER_EOF
#!/usr/bin/env bash
LOG_FILE="${LOG_FILE}"
REVIEWER="${REVIEWER}"
log() { echo "[\$(date -u +"%Y-%m-%dT%H:%M:%SZ")] \$*" >> "\$LOG_FILE"; }

PROMPT_FILE="${PROMPT_FILE}"
if [ ! -f "\$PROMPT_FILE" ]; then
  echo "ERROR: prompt file missing: \$PROMPT_FILE" >&2
  exit 1
fi

log "Starting \${REVIEWER} multi-agent review"
START_TIME=\$(date +%s)

# shellcheck disable=SC2086
${INVOKE_LINE} || REVIEWER_EXIT=\$?
REVIEWER_EXIT=\${REVIEWER_EXIT:-0}

ELAPSED=\$(( \$(date +%s) - START_TIME ))
log "\${REVIEWER} finished (exit=\$REVIEWER_EXIT, elapsed=\${ELAPSED}s)"
exit \$REVIEWER_EXIT
RUNNER_EOF
  chmod +x "$RUNNER_SCRIPT"
}
