# PR Review: #1 — Add /codex-review on-demand command

**Date:** 2026-03-31
**Reviewer:** Claude (claude-sonnet-4-6, independent subagent)
**PR URL:** https://github.com/Smiie-2/claude-review-loop/pull/1
**Branch:** feature/codex-review-command -> main

---

## Summary

This PR adds a `/codex-review` slash command that triggers a Codex multi-agent code review on demand, without locking into the rigid `/review-loop` lifecycle. It achieves this cleanly by extracting the shared prompt-building and Codex-validation logic from `stop-hook.sh` into a new `scripts/codex-review-lib.sh` library that both commands source. The overall quality is good — the refactor is coherent, the fail-open philosophy is preserved, and the documentation is well updated. There are a few correctness bugs worth fixing before merge.

---

## Files Changed

| File | Changes | Description |
|------|---------|-------------|
| `.claude-plugin/marketplace.json` | +7 / -7 | Rebrands from hamelsmu to Smiie-2 fork identity |
| `.gitignore` | +10 / -0 | Adds new temp file patterns and `.cocoindex_code/` |
| `README.md` | +62 / -42 | Rewrites for fork: comparison table, updated file structure, new usage docs |
| `plugins/review-loop/.claude-plugin/plugin.json` | +2 / -2 | Bumps version to 1.9.0, updates description |
| `plugins/review-loop/AGENTS.md` | +17 / -7 | Documents new architecture and conventions |
| `plugins/review-loop/commands/cancel-review.md` | +11 / -9 | Extends cancel to handle both review-loop and codex-review temp files |
| `plugins/review-loop/commands/codex-review.md` | +81 / -0 | New on-demand review command |
| `plugins/review-loop/hooks/stop-hook.sh` | +12 / -251 | Replaces inline logic with calls to shared library |
| `plugins/review-loop/scripts/codex-review-lib.sh` | +257 / -0 | New shared library: detection, prompt building, Codex validation, runner script writing |

---

## Strengths

**Clean extraction into a shared library.** Moving `detect_nextjs()`, `detect_browser_ui()`, `build_review_prompt()`, and the runner script generation out of `stop-hook.sh` into `codex-review-lib.sh` is the right architectural move. The idempotent guard (`[[ -n "${_CODEX_REVIEW_LIB:-}" ]] && return 0`) is a good touch that prevents double-sourcing issues.

**Guard includes with no side effects.** The library file is disciplined about containing only function definitions with no top-level execution, which makes it safe to source from both the hook and the command.

**Fail-open philosophy is preserved.** The ERR trap in `stop-hook.sh` still catches unexpected failures and approves exit rather than trapping the user. This was the original plugin's strongest reliability property and was not broken by this refactor.

**Consistent temp file namespacing.** Using `codex-review-` prefix for the new command's files and `review-loop-` for the existing ones prevents any collision between the two modes — a detail that's easy to get wrong and was handled correctly here.

**Well-written documentation.** The README comparison table is genuinely useful for understanding the two modes at a glance. The AGENTS.md update accurately reflects the new architecture.

**`cancel-review` correctly extended.** The updated command checks for both state files independently and reports what it cleaned up — a small but correct improvement over the original.

---

## Issues

### Critical (Must Fix)

**1. `ensure_codex_ready` called before auto-configure in `/codex-review` — will always fail on first use**

`commands/codex-review.md`, lines 27 vs 29-46:

```bash
# Line 27: validates multi_agent is enabled
CODEX_ERROR=$(ensure_codex_ready 2>&1) || { echo "ERROR: $CODEX_ERROR"; exit 1; }

# Lines 29-46: THEN auto-configures multi_agent if missing
if [ ! -f "$CODEX_CONFIG" ]; then
  ...
  printf '[features]\nmulti_agent = true\n' > "$CODEX_CONFIG"
```

The validation check runs before the auto-configuration block. On any machine that doesn't already have `multi_agent = true` in `~/.codex/config.toml`, `ensure_codex_ready` will return an error and the command will exit with an error message — even though the auto-configure logic below would have fixed it. The user sees "Codex multi-agent is not enabled" and needs to configure it manually, defeating the auto-configure feature entirely.

**Fix:** Move the `ensure_codex_ready` call to after the auto-configuration block, or split the function so only the `codex` binary check happens upfront.

---

**2. `write_runner_script` embeds `PROMPT_FILE` as a literal path at write time, then the generated script treats it as a variable — but the path is hardcoded wrong**

`codex-review-lib.sh`, line 239:

```bash
PROMPT_FILE="${PROMPT_FILE}"
```

This heredoc line is inside a `RUNNER_EOF` block. Because `$PROMPT_FILE` is NOT escaped (no backslash), it expands at write time to the caller's `$PROMPT_FILE` value — which is correct in intent. However, the generated script then assigns that expanded value to `$PROMPT_FILE` as a literal string. This is actually fine when both the setup script and the runner execute in the same working directory.

The subtle bug is in `stop-hook.sh`: the hook runs from the project root, and `write_runner_script` is called with `PROMPT_FILE=".claude/review-loop-codex-prompt.txt"` (a relative path). The generated runner script will hardcode that relative path and execute correctly only if run from the same directory. This is fragile but not a new regression — the original stop-hook.sh had the same pattern. **However**, the `/codex-review` command's runner script is explicitly called as `bash .claude/codex-review-run.sh` from the Claude Code session context, which should also be the project root. Low risk in practice, but worth noting.

This is borderline Important rather than Critical — no behavior regression from the original, but the abstraction leaks directory assumptions.

---

### Important (Should Fix)

**3. `build_review_prompt` logs removed from the library — stop-hook.sh log call now uses detection results awkwardly**

In the original `stop-hook.sh`, the detection result was logged inside `build_review_prompt()`. After the refactor, the log call was moved to `stop-hook.sh` at line 94:

```bash
log "Project detection: nextjs=$(detect_nextjs && echo true || echo false), browser_ui=$(detect_browser_ui && echo true || echo false)"
```

This calls `detect_nextjs()` and `detect_browser_ui()` twice — once here for logging, once again inside `build_review_prompt()`. For `detect_nextjs`, this includes a `grep` on `package.json`. Inefficient, and more importantly, `build_review_prompt()` in the library no longer logs anything, so the `/codex-review` command path gets no detection telemetry in the log. This is an inconsistency rather than a bug, but telemetry coverage is now uneven between the two modes.

**Fix:** Either have `build_review_prompt` accept a log callback, or log the detection result in `codex-review.md`'s setup script before calling `build_review_prompt`.

---

**4. Error capture pattern for `ensure_codex_ready` is incorrect in `codex-review.md`**

`commands/codex-review.md`, line 27:

```bash
CODEX_ERROR=$(ensure_codex_ready 2>&1) || { echo "ERROR: $CODEX_ERROR"; exit 1; }
```

`ensure_codex_ready` writes its error message to stdout (not stderr) and returns 1. The `2>&1` redirect is harmless but misleading. More importantly: because the function writes to stdout, command substitution `$(...)` captures it — so `$CODEX_ERROR` will contain the message. This is actually correct and works. But the redundancy with issue #1 (calling it before auto-configure) means the captured error message will just be "Codex multi-agent is not enabled..." and the user has to configure it manually.

This is the same root issue as Critical #1 — fix the ordering and this resolves naturally.

---

**5. No tests for the new command or shared library**

The PR description's test plan consists of manual steps ("Run `/codex-review`... verify it runs Codex"). There are no automated tests for any of the shell functions: `ensure_codex_ready`, `build_review_prompt`, `write_runner_script`, or the detection functions. This was true of the original plugin too, but the extraction into a library now makes unit testing much more tractable.

This is a pre-existing gap, not a regression introduced by this PR — but the PR creates the ideal opportunity to add at least smoke tests for the library functions. The AGENTS.md documents a clear test protocol (`test all paths: no-state, task→block, addressing-without-review→block, addressing-with-review→approve`) that could be partially automated.

---

### Minor (Consider)

**6. `setup-review-loop.sh` removed from file structure but cleanup not reflected in `.gitignore`**

The README file structure section now shows `scripts/codex-review-lib.sh` instead of `scripts/setup-review-loop.sh`. The old `setup-review-loop.sh` was presumably the script that the review-loop command called — it appears to have been replaced by the inline bash in `review-loop.md`. No gitignore entry exists for a `setup-review-loop.sh` artifact, but no entry was removed either. Low impact, just a cleanliness note.

---

**7. `write_runner_script` uses `review-loop.log` even for `/codex-review` temp files**

`codex-review-lib.sh`, line 236:

```bash
LOG_FILE=".claude/review-loop.log"
```

The generated runner script always logs to `review-loop.log` regardless of whether it was spawned by `/review-loop` or `/codex-review`. This means `/codex-review` activity is silently folded into the `/review-loop` log. Probably harmless, but someone debugging `/codex-review` issues would need to know to look in `review-loop.log`. A `codex-review.log` or a unified log file documented as shared would be cleaner.

---

**8. `sed -i` macOS/Linux divergence is duplicated in both `review-loop.md` and `codex-review.md`**

Both command files contain identical multi-agent auto-configure logic including the macOS/Linux `sed -i` handling. This logic could be extracted into a `ensure_multi_agent_enabled()` function in the shared library. Currently it lives in two places and could drift. The library already has `ensure_codex_ready` for the validation side — the configuration side should live there too.

---

## Recommendations

1. **Fix the validate-before-configure ordering bug (Critical #1) before merge.** The simplest fix is to move the `ensure_codex_ready` call to after the auto-configure block in `codex-review.md`, or to restructure `ensure_codex_ready` to only check for the `codex` binary (since auto-configure is handled inline in both commands).

2. **Extract the auto-configure logic into the shared library.** An `ensure_multi_agent_configured()` function in `codex-review-lib.sh` would eliminate the duplication between `review-loop.md` and `codex-review.md` and keep platform-specific `sed` workarounds in one place.

3. **Add smoke tests for the library.** Even a simple `test-lib.sh` that sources `codex-review-lib.sh` and verifies the detection functions return expected values for a known project structure would significantly increase confidence in future refactors.

---

## Assessment

**Ready to merge:** With fixes

**Confidence:** High

**Reasoning:** The architecture is sound and the refactor is well-executed — extracting shared logic into a library is the right move. However, the validate-before-configure ordering bug in `codex-review.md` will cause the command to fail on first use for any user who hasn't already manually configured Codex multi-agent, which is likely the majority of new users. That's a user-visible breakage in the primary advertised feature and should be fixed before merge. The remaining issues are minor quality and consistency concerns.

---

## Review Metadata

| Metric | Value |
|--------|-------|
| Review type | tiered (Sonnet only) |
| Sonnet tokens | 42,535 |
| Opus tokens | — |
| Total tokens | 42,535 |
| Escalated | No |
| Wall-clock time | 2m 45s |
| Report generated | 2026-03-31T08:52:31Z |
