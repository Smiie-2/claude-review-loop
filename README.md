# claude-review-loop (fork)

A Claude Code plugin that integrates multi-agent code reviews into your workflow — either on-demand or as a full implement-review-fix loop. The reviewer is pluggable: choose **[Codex](https://github.com/openai/codex)** (default) or **[Gemini CLI](https://github.com/google-gemini/gemini-cli)** via config.

This is a fork of [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) that adds a standalone `/codex-review` command for on-demand reviews without the locked workflow, plus Gemini reviewer support.

## What changed in this fork

The original plugin only offers `/review-loop`, which locks you into a rigid cycle: describe task → Claude implements → Codex reviews → Claude fixes → exit. That's useful for fully automated workflows, but too restrictive if you prefer to stay in control.

This fork adds **`/codex-review`** — a standalone command that triggers the same Codex multi-agent review at any point, without locking you into anything. You get the review, you decide what to do with it.

| | `/codex-review` (new) | `/review-loop` (original) |
|---|---|---|
| **Trigger** | Run anytime | Starts a full task lifecycle |
| **Workflow** | None — presents findings, you decide | Locked: implement → review → fix → exit |
| **Exit blocking** | No | Yes (stop hook blocks until review is addressed) |
| **State files** | None | `.review-loop/state.md` tracks phase |
| **Fixes** | Your choice | Claude must address findings before exiting |

Both commands share the same review prompt and reviewer dispatch under the hood (`scripts/review-lib.sh`).

## Review coverage

The plugin spawns up to 4 parallel review sub-agents (via Codex `multi_agent` or Gemini's subagent runtime), depending on project type:

| Agent | Always runs? | Focus |
|-------|-------------|-------|
| **Diff Review** | Yes | `git diff` — code quality, test coverage, security (OWASP top 10) |
| **Holistic Review** | Yes | Project structure, documentation, AGENTS.md, agent harness, architecture |
| **Next.js Review** | If `next.config.*` or `"next"` in `package.json` | App Router, Server Components, caching, Server Actions, React performance |
| **UX Review** | If `app/`, `pages/`, `public/`, or `index.html` exists | Browser E2E via [agent-browser](https://agent-browser.dev/), accessibility, responsive design |

After all agents finish, the reviewer deduplicates findings and writes a single consolidated review to `reviews/review-<id>.md`.

## Requirements

- [Claude Code](https://claude.ai/code) (CLI)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- **One of:**
  - [Codex CLI](https://github.com/openai/codex) — `npm install -g @openai/codex` (default reviewer)
  - [Gemini CLI](https://github.com/google-gemini/gemini-cli) v0.38+ — `npm install -g @google/gemini-cli`

### Choosing a reviewer

Resolution order (first match wins):

1. `REVIEW_LOOP_REVIEWER` env var (`codex` or `gemini`)
2. `.review-loop/config.toml` (per-project)
3. `~/.config/review-loop/config.toml` (global)
4. Default: `codex`

Config file format:

```toml
# .review-loop/config.toml  or  ~/.config/review-loop/config.toml
reviewer = "gemini"
```

### Codex multi-agent

When using Codex, the plugin uses [multi-agent](https://developers.openai.com/codex/multi-agent/) to run parallel review agents. Both `/codex-review` and `/review-loop` automatically enable it in `~/.codex/config.toml` on first use.

To set it up manually instead:

```toml
# ~/.codex/config.toml
[features]
multi_agent = true
```

### Gemini subagents

Gemini CLI v0.38+ ships with a native subagent runtime — no config flag is needed; the same review prompt is dispatched through Gemini's agentic loop. By default no `-m` flag is passed, so the CLI picks its own default model; override via `REVIEW_LOOP_GEMINI_MODEL` (e.g. `gemini-3.1-pro-preview`).

## Installation

From the CLI:

```bash
claude plugin marketplace add Smiie-2/claude-review-loop
claude plugin install review-loop@smiie-review
```

Or from within a Claude Code session:

```
/plugin marketplace add Smiie-2/claude-review-loop
/plugin install review-loop@smiie-review
```

## Updating

```bash
claude plugin marketplace update smiie-review
claude plugin update review-loop@smiie-review
```

## Usage

### On-demand review (recommended)

```
/codex-review
# or fully qualified: /review-loop:codex-review
```

Runs a multi-agent review of your current changes (staged, unstaged, and recent commits) using the configured reviewer. Presents findings organized by severity. You decide what to address — nothing is forced.

### Full review loop

```
/review-loop Add user authentication with JWT tokens and test coverage
# or fully qualified: /review-loop:review-loop Add user authentication...
```

Claude implements the task. When it finishes, the stop hook blocks exit, runs the multi-agent review, and Claude must address the findings before it can stop.

### Cancel

```
/cancel-review
# or fully qualified: /review-loop:cancel-review
```

Cancels either an active review loop or an in-progress on-demand review. Cleans up all temp files.

## How it works

### `/codex-review`

1. Generates a review ID and validates the configured reviewer (Codex or Gemini) is installed
2. Builds a context-aware review prompt (detects Next.js, UI projects)
3. Runs the reviewer with its parallel-subagent feature — output streams to your terminal
4. The reviewer writes findings to `reviews/review-<id>.md`
5. Claude reads and presents the review to you
6. Temp files are cleaned up

No state files, no hooks, no exit blocking. (Command name is kept as `/codex-review` for backward compatibility; it runs whichever reviewer you configured.)

### `/review-loop`

Uses a **Stop hook** to enforce a two-phase lifecycle:

1. **Task phase**: Claude implements the task you described
2. **Review phase**: On exit, the hook prepares a runner script for the configured reviewer, blocks Claude's exit, and instructs it to run the review and address findings

State is tracked in `.review-loop/state.md` (gitignored). Reviews are written to `reviews/review-<id>.md`.

## File structure

```
plugins/review-loop/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest (v2.0.0)
├── commands/
│   ├── codex-review.md          # /codex-review — on-demand review
│   ├── review-loop.md           # /review-loop — full locked workflow
│   └── cancel-review.md         # /cancel-review — cancel either mode
├── hooks/
│   ├── hooks.json               # Stop hook registration (30s timeout)
│   └── stop-hook.sh             # Review loop lifecycle engine
├── scripts/
│   └── review-lib.sh            # Shared library (prompt building, reviewer dispatch)
├── AGENTS.md                    # Agent operating guidelines
└── CLAUDE.md                    # Symlink to AGENTS.md
```

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_REVIEWER` | _(config file, else `codex`)_ | Select reviewer: `codex` or `gemini`. Overrides both config files. |
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex`. Set to `--sandbox workspace-write` for safer sandboxed reviews. |
| `REVIEW_LOOP_GEMINI_FLAGS` | `--yolo` | Flags passed to `gemini`. Use `--approval-mode auto_edit` for edit-only auto-approval. |
| `REVIEW_LOOP_GEMINI_MODEL` | _(unset — CLI default)_ | Model passed to `gemini -m`. Leave unset to let Gemini CLI pick its default. |

### Telemetry

Execution logs are written to `.review-loop/review-loop.log` (for `/review-loop`) or `.review-loop/codex-review.log` (for `/codex-review`). These are gitignored.

## Troubleshooting

If a review looks stuck, fails silently, or produces no output, check the logs first:

| Command | Log file |
|---------|----------|
| `/review-loop` | `.review-loop/review-loop.log` |
| `/codex-review` | `.review-loop/codex-review.log` |

Each log line is timestamped (UTC, ISO 8601) and records start/finish/exit-code/elapsed-seconds for every reviewer invocation. The reviewer's own stderr (Codex/Gemini API errors, auth failures, rate limits) streams to the terminal during execution — rerun the runner script manually if you need to re-capture it:

```bash
bash .review-loop/review-loop-runner.sh   # /review-loop
bash .review-loop/codex-review-run.sh     # /codex-review
```

Active loop state lives in `.review-loop/state.json` (inspect with `jq . .review-loop/state.json`). Use `/cancel-review` to clear a stuck loop.

## Credits

Original plugin by [Hamel Husain](https://github.com/hamelsmu/claude-review-loop). Inspired by the [Ralph Wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) and [Ryan Carson's compound engineering loop](https://x.com/ryancarson/article/2016520542723924279).
