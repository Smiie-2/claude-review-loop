# review-loop Plugin — Agent Guidelines

## What this is

A Claude Code plugin with two modes of multi-agent code review. The reviewer is pluggable — choose **Codex** (default) or **Gemini** via config / env var.

**`/codex-review`** — On-demand review. Runs a multi-agent review of current changes and presents findings. No workflow lock, no forced fixes. Use anytime.

**`/review-loop "<task>"`** — Full locked workflow. Claude implements a task, gets reviewed, then addresses feedback before exiting.

Both modes share the same review prompt and reviewer dispatch via `scripts/review-lib.sh`.

## Reviewer selection

Resolution order (first match wins):

1. `REVIEW_LOOP_REVIEWER` env var
2. `.review-loop/config.toml` (per-project)
3. `~/.config/review-loop/config.toml` (global)
4. Default: `codex`

Valid values: `codex`, `gemini`. Unknown values fall back to `codex`.

Config file format:
```toml
reviewer = "gemini"
```

**Codex** uses the `multi_agent = true` feature in `~/.codex/config.toml` (auto-configured on first run). **Gemini** uses its built-in subagent runtime (v0.38+) with `@agent` dispatch — no config flag needed. By default no `-m` flag is passed, so Gemini CLI uses its own default model (currently Gemini 3.1 Pro for authenticated users). Override via `REVIEW_LOOP_GEMINI_MODEL` (e.g. `gemini-3.1-pro-preview`).

## Architecture

- `scripts/review-lib.sh` — Shared library (sourced, not executed). Contains reviewer dispatch (`get_reviewer`, `ensure_reviewer_ready`, `ensure_reviewer_configured`, `default_reviewer_flags`), project detection (`detect_nextjs`, `detect_browser_ui`), prompt builder (`build_review_prompt`, `_render_prompt`), runner generator (`write_runner_script`), and reviewer-specific helpers (`ensure_codex_ready`, `ensure_gemini_ready`, `ensure_multi_agent_configured`).
- `prompts/` — Multi-agent review prompt templates (`preamble.md`, `agent-diff.md`, `agent-holistic.md`, `agent-nextjs.md`, `agent-ux.md`, `consolidation.md`). Placeholder `{{REVIEW_FILE}}` is substituted at render time. Edit these instead of touching the lib to tune review prompts.
- `hooks/stop-hook.sh` — Stop hook for `/review-loop` phase management. Sources the shared library.
- `commands/codex-review.md` — On-demand review command. Sources the shared library via cross-platform `find`. (Command name kept as `/codex-review` for stability; it runs whichever reviewer is configured.)
- `commands/review-loop.md` — Locked workflow command.
- `commands/cancel-review.md` — Cancels either mode.

## Conventions

- Shell scripts must work on both macOS and Linux (handle `sed -i` differences)
- The stop hook MUST always produce valid JSON to stdout — never let non-JSON text leak
- Fail-open: on any error, approve exit rather than trapping the user
- State lives in `.review-loop/state.md` — always clean up on exit
- Review ID format: `YYYYMMDD-HHMMSS-hexhex` — validate before using in paths
- `/review-loop` temp files use `review-loop-` prefix (`review-loop-runner.sh`, `review-loop-prompt.txt`); `/codex-review` uses `codex-review-` prefix — no collisions
- All temp/state files go in `.review-loop/` at the project root (NOT `.claude/` — that triggers sensitive file detection)
- The review prompt is saved to a prompt file for the runner script to read
- Telemetry goes to `.review-loop/review-loop.log` or `.review-loop/codex-review.log` — structured, timestamped lines
- Phase transitions use `transition_phase()` (awk rewrite + verify), NOT fragile sed regex
- All `jq` calls that produce block decisions MUST have a `|| printf '...'` fallback
- The `addressing` phase verifies the review file exists before allowing exit — Claude cannot skip the review
- Plugin path resolution uses `$HOME` (not `~`) for cross-platform compatibility (macOS/Linux/Windows)

## Security constraints

- Review IDs are validated against `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$` to prevent path traversal
- Codex flags configurable via `REVIEW_LOOP_CODEX_FLAGS`; Gemini flags via `REVIEW_LOOP_GEMINI_FLAGS`
- No secrets or credentials are stored in state files

## Testing

- Run `bash scripts/test-lib.sh` to test shared library functions (includes reviewer-selection + gemini runner coverage)
- Run `bash scripts/test-stop-hook.sh` to test stop-hook state machine
- After modifying stop-hook.sh, test all paths: no-state, task→block, addressing-without-review→block, addressing-with-review→approve
- Verify JSON output with `jq .` for each path
- Test with the selected reviewer unavailable (should block with install instructions)
- Test with malformed state files (should fail-open)
