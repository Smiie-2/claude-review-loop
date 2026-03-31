# review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin with two modes of Codex-powered code review:

**`/codex-review`** — On-demand review. Runs a Codex multi-agent review of current changes and presents findings. No workflow lock, no forced fixes. Use anytime.

**`/review-loop "<task>"`** — Full locked workflow. Claude implements a task, gets reviewed by Codex, then addresses feedback before exiting.

Both modes share the same review prompt and Codex integration via `scripts/codex-review-lib.sh`.

## Architecture

- `scripts/codex-review-lib.sh` — Shared library (sourced, not executed). Contains: `detect_nextjs()`, `detect_browser_ui()`, `build_review_prompt()`, `ensure_codex_ready()`, `ensure_multi_agent_configured()`, `write_runner_script()`
- `hooks/stop-hook.sh` — Stop hook for `/review-loop` phase management. Sources the shared library.
- `commands/codex-review.md` — On-demand review command. Sources the shared library via cross-platform `find`.
- `commands/review-loop.md` — Locked workflow command.
- `commands/cancel-review.md` — Cancels either mode.

## Conventions

- Shell scripts must work on both macOS and Linux (handle `sed -i` differences)
- The stop hook MUST always produce valid JSON to stdout — never let non-JSON text leak
- Fail-open: on any error, approve exit rather than trapping the user
- State lives in `.review-loop/state.md` — always clean up on exit
- Review ID format: `YYYYMMDD-HHMMSS-hexhex` — validate before using in paths
- `/review-loop` temp files use `review-loop-` prefix; `/codex-review` uses `codex-review-` prefix — no collisions
- All temp/state files go in `.review-loop/` at the project root (NOT `.claude/` — that triggers sensitive file detection)
- Codex prompt is saved to a prompt file for the runner script to read
- Telemetry goes to `.review-loop/review-loop.log` or `.review-loop/codex-review.log` — structured, timestamped lines
- Phase transitions use `transition_phase()` (awk rewrite + verify), NOT fragile sed regex
- All `jq` calls that produce block decisions MUST have a `|| printf '...'` fallback
- The `addressing` phase verifies the review file exists before allowing exit — Claude cannot skip the review
- Plugin path resolution uses `$HOME` (not `~`) for cross-platform compatibility (macOS/Linux/Windows)

## Security constraints

- Review IDs are validated against `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$` to prevent path traversal
- Codex flags are configurable via `REVIEW_LOOP_CODEX_FLAGS` env var
- No secrets or credentials are stored in state files

## Testing

- Run `bash scripts/test-lib.sh` to test shared library functions
- Run `bash scripts/test-stop-hook.sh` to test stop-hook state machine
- After modifying stop-hook.sh, test all paths: no-state, task→block, addressing-without-review→block, addressing-with-review→approve
- Verify JSON output with `jq .` for each path
- Test with codex unavailable (should block with install instructions)
- Test with malformed state files (should fail-open)
