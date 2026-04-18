# Review: local branch diff — Add Gemini reviewer support with pluggable reviewer dispatch

**Date:** 2026-04-18
**Reviewer:** Claude (Sonnet, independent subagent)
**Commit:** 2498318
**Branch:** worktree-gemini-reviewer-support → main

---

## Summary

This change introduces a pluggable reviewer dispatch layer into the claude-review-loop plugin, allowing users to select between Codex (default) and Gemini CLI as the review backend via env var or TOML config files. The implementation is clean and well-structured: the shared library is renamed to `review-lib.sh`, dispatcher functions are layered over the existing Codex helpers, and both the on-demand command and the stop hook are updated consistently. Test coverage is good and the backward-compatibility story (keeping the `/codex-review` command name) is correctly documented.

---

## Files Changed

| File | Changes | Description |
|------|---------|-------------|
| `plugins/review-loop/scripts/review-lib.sh` (renamed from `codex-review-lib.sh`) | +131 / -0 (net additions) | Core library: adds `get_reviewer`, `ensure_reviewer_ready`, `ensure_reviewer_configured`, `default_reviewer_flags`, extends `write_runner_script` with reviewer param |
| `plugins/review-loop/hooks/stop-hook.sh` | +93 / -87 | Updated to use dispatcher; renames temp files to reviewer-agnostic names; inlines Codex multi-agent check |
| `plugins/review-loop/commands/codex-review.md` | +33 / -33 | Updated to call dispatcher functions; adds `.review-loop/codex-review.log` to cleanup |
| `plugins/review-loop/commands/review-loop.md` | +12 / -12 | Switches to `get_reviewer`/`ensure_reviewer_ready`/`ensure_reviewer_configured`; renames runner script reference |
| `plugins/review-loop/commands/cancel-review.md` | +2 / -1 | Adds new reviewer-agnostic temp file names to cleanup list, keeps old names for backward compat |
| `plugins/review-loop/scripts/test-lib.sh` | +48 / -8 | Tests for `get_reviewer`, `ensure_gemini_ready`, `default_reviewer_flags`, Gemini runner script |
| `plugins/review-loop/scripts/test-stop-hook.sh` | +8 / -0 | Minor updates for renamed files |
| `plugins/review-loop/AGENTS.md` | +40 / -22 | Documents reviewer selection, updated architecture section |
| `README.md` | +55 / -28 | Documents new feature end-to-end |
| `.gitignore` | +2 / -0 | Un-ignores `.review-loop/config.toml` so project-level reviewer config can be committed |

---

## Strengths

- **Clean dispatcher pattern** (`review-lib.sh` lines ~50–100): `get_reviewer`, `ensure_reviewer_ready`, `ensure_reviewer_configured`, and `default_reviewer_flags` are small, composable functions that isolate all branching in one place. Adding a third reviewer later requires changes only in these dispatchers.

- **Tolerant TOML parser** (`review-lib.sh` `get_reviewer` awk block): handles bare values, single- and double-quoted values, trailing comments, blank lines, and comment-only lines. This is notably more robust than a naive `grep`-based parse.

- **Source guard** (`[[ -n "${_REVIEW_LIB:-}" ]] && return 0`): prevents double-sourcing, an easy bug to overlook in bash.

- **Backward compatibility**: old temp file names (`review-loop-run-codex.sh`, `review-loop-codex-prompt.txt`) are included in the `cancel-review.md` cleanup command alongside the new names, so existing in-flight sessions are cleanly handled.

- **Fail-open philosophy maintained**: ERR trap and all error branches in the stop hook continue to emit `{"decision":"approve"}` rather than trapping the user.

- **Test breadth**: the `get_reviewer` test matrix covers env var, project config, global config precedence, unknown values, tolerant TOML variants, and commented-out keys — all meaningful edge cases.

- **Cleanup fix** (`codex-review.md`): the previously-missing `codex-review.log` removal is now included in the cleanup block, closing the gap flagged in the commit message.

---

## Issues

### Critical (Must Fix)

No critical issues found.

---

### Important (Should Fix)

**1. Shell word-splitting vulnerability in `write_runner_script` — Gemini model flag**

`review-lib.sh`, `write_runner_script` function, Gemini branch:

```bash
[ -n "$GEMINI_MODEL" ] && MODEL_FLAG="-m ${GEMINI_MODEL}"
INVOKE_LINE="gemini ${MODEL_FLAG} ${REVIEWER_FLAGS} -p \"$(cat \"$PROMPT_FILE\")\""
```

`MODEL_FLAG` is constructed from `REVIEW_LOOP_GEMINI_MODEL` without quoting. If the env var contains spaces (e.g. a model name with a space, or a typo with a leading space), the runner script will be generated with a split token and the invocation will fail silently or pass a wrong argument. The value should be quoted:

```bash
[ -n "$GEMINI_MODEL" ] && MODEL_FLAG="-m \"${GEMINI_MODEL}\""
```

Severity: **Important** — not a security issue (this is a developer-controlled env var), but it will silently produce a broken runner script that is hard to diagnose.

---

**2. `write_runner_script` reads `REVIEW_LOOP_GEMINI_MODEL` from the outer shell at script-generation time, not at run time**

`review-lib.sh`, `write_runner_script` Gemini branch:

```bash
local GEMINI_MODEL="${REVIEW_LOOP_GEMINI_MODEL:-}"
```

The model is baked into the generated runner script at the time the hook runs (or the command is set up). If the user changes `REVIEW_LOOP_GEMINI_MODEL` between generation and execution, the already-written script will use the stale value. For Codex, flags are similarly baked in, so this is consistent behaviour — but it is a subtle gotcha worth documenting in AGENTS.md since the reviewer selection itself (`REVIEWER`) is also evaluated at generation time, not at execution time.

Severity: **Important** (documentation/clarity, not a correctness bug per se, but it can cause confusing behaviour in workflows where env vars are set after the loop starts).

---

**3. `review-loop.md` one-liner still calls `ensure_multi_agent_configured` indirectly but `ensure_reviewer_configured` is now the correct dispatcher**

Looking at the diff for `review-loop.md`:

```bash
# Before (deleted):
ensure_multi_agent_configured

# After (added):
ensure_reviewer_configured "$REVIEWER"
```

This is correct. However the one-liner is a single-line bash command that is hard to audit for correctness and will silently fail if a new dispatch case is ever added. This is a pre-existing pattern, but the PR made this line longer — it is now very hard to read and verify. Not a bug in this PR, but the PR made it harder to audit.

---

### Minor (Consider)

**4. `get_reviewer` does not read from global config when project config exists but contains an unknown value**

`review-lib.sh`, `get_reviewer`:

```bash
elif [ -f ".review-loop/config.toml" ]; then
  src=".review-loop/config.toml"
elif [ -f "${HOME}/.config/review-loop/config.toml" ]; then
  src="${HOME}/.config/review-loop/config.toml"
fi
```

If `.review-loop/config.toml` exists but contains `reviewer = "unknown-tool"`, the function falls back to `codex` (via the `case` default) rather than consulting the global config. This is intentional per the documented resolution order, but it means a typo in a project config silently overrides a valid global config. Worth adding a comment in the code and/or noting in AGENTS.md.

---

**5. Gemini `--yolo` flag as default is undocumented in terms of what it does**

`review-lib.sh`, `default_reviewer_flags`:

```bash
gemini)  echo "${REVIEW_LOOP_GEMINI_FLAGS:---yolo}" ;;
```

README.md documents the env var but not what `--yolo` means (full auto-approval, equivalent to `--dangerously-bypass-approvals-and-sandbox` for Codex). A brief note in the README's env-var table — or at minimum a comment in `review-lib.sh` — would help users understand the risk and know when to override it.

---

**6. `codex-review.md` command still uses `codex-review-` prefix for its temp files when Gemini is selected**

`commands/codex-review.md`:

```bash
PROMPT_FILE=".review-loop/codex-review-prompt.txt"
RUNNER_SCRIPT=".review-loop/codex-review-run.sh"
```

When Gemini is the configured reviewer, the temp files are still named `codex-review-prompt.txt` and `codex-review-run.sh`. This is functional (AGENTS.md documents the `/codex-review` prefix convention deliberately), but it is confusing to a user running `ls .review-loop/` while Gemini is selected and seeing `codex-review-*` files. At minimum, a comment in the command file explaining the prefix convention would reduce confusion.

---

**7. Test for `get_reviewer` with global config file not covered**

`test-lib.sh`: the test suite exercises env var, project config, and default — but there is no test case that verifies the global config (`~/.config/review-loop/config.toml`) is correctly picked up when no project config exists. Given that `$HOME` is redirected to `$TMPDIR/fakehome` in the test setup, this case is easy to add.

---

**8. Stop-hook ERR trap cleans up new file names but not old ones**

`stop-hook.sh`, ERR trap:

```bash
trap '... rm -f .review-loop/lock .review-loop/review-loop-runner.sh .review-loop/review-loop-prompt.txt .review-loop/retries; ...' ERR
```

The ERR trap now references the new file names (`review-loop-runner.sh`, `review-loop-prompt.txt`) but not the old ones. For a session that started with the old names (before this branch), the ERR trap would leave stale files behind. This is a minor concern since state files from different plugin versions are unlikely to mix in practice.

---

## Recommendations

1. Quote `${GEMINI_MODEL}` in the `MODEL_FLAG` construction in `write_runner_script` (Issue 1).
2. Add a comment in `write_runner_script` or the README clarifying that model/flags are baked at generation time (Issue 2).
3. Add a code comment next to `--yolo` explaining what it enables, and add a sentence to the README's env-var description (Issue 5).
4. Add a test case for the global config resolution path in `test-lib.sh` (Issue 7).
5. Add a comment in `codex-review.md` explaining why the `codex-review-` prefix is kept even when Gemini is selected (Issue 6).

---

## Assessment

**Ready to merge:** With fixes
**Confidence:** High
**Reasoning:** The implementation is architecturally sound, consistently applied across all entry points, and well-tested for the primary new code paths. The only issue worth fixing before merge is the word-splitting risk in the Gemini model flag (Issue 1). Issues 2–8 are documentation, clarity, and test-coverage gaps that reduce maintainability but do not affect correctness in the common case. The fail-open safety property of the stop hook is preserved throughout.

---


## Review Metadata

| Metric | Value |
|--------|-------|
| Review type | tiered (Sonnet only — no escalation) |
| Sonnet tokens | 41,982 |
| Opus tokens | — |
| Total tokens | 41,982 |
| Escalated | No — Sonnet reported no Low-confidence dimensions |
| Wall-clock time | ~2m 15s |
| Report generated | 2026-04-18T14:41:14Z |
