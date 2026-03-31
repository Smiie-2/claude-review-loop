# claude-review-loop (fork)

A Claude Code plugin that integrates [Codex](https://github.com/openai/codex) multi-agent reviews into your workflow — either on-demand or as a full implement-review-fix loop.

This is a fork of [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) that adds a standalone `/codex-review` command for on-demand reviews without the locked workflow.

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

Both commands share the same review prompt and Codex integration under the hood (`scripts/codex-review-lib.sh`).

## Review coverage

The plugin spawns up to 4 parallel Codex sub-agents, depending on project type:

| Agent | Always runs? | Focus |
|-------|-------------|-------|
| **Diff Review** | Yes | `git diff` — code quality, test coverage, security (OWASP top 10) |
| **Holistic Review** | Yes | Project structure, documentation, AGENTS.md, agent harness, architecture |
| **Next.js Review** | If `next.config.*` or `"next"` in `package.json` | App Router, Server Components, caching, Server Actions, React performance |
| **UX Review** | If `app/`, `pages/`, `public/`, or `index.html` exists | Browser E2E via [agent-browser](https://agent-browser.dev/), accessibility, responsive design |

After all agents finish, Codex deduplicates findings and writes a single consolidated review to `reviews/review-<id>.md`.

## Requirements

- [Claude Code](https://claude.ai/code) (CLI)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- [Codex CLI](https://github.com/openai/codex) — `npm install -g @openai/codex`

### Codex multi-agent

This plugin uses Codex [multi-agent](https://developers.openai.com/codex/multi-agent/) to run parallel review agents. Both `/codex-review` and `/review-loop` automatically enable it in `~/.codex/config.toml` on first use.

To set it up manually instead:

```toml
# ~/.codex/config.toml
[features]
multi_agent = true
```

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
```

Runs a Codex multi-agent review of your current changes (staged, unstaged, and recent commits). Presents findings organized by severity. You decide what to address — nothing is forced.

### Full review loop

```
/review-loop Add user authentication with JWT tokens and test coverage
```

Claude implements the task. When it finishes, the stop hook blocks exit, runs the Codex review, and Claude must address the findings before it can stop.

### Cancel

```
/cancel-review
```

Cancels either an active review loop or an in-progress on-demand review. Cleans up all temp files.

## How it works

### `/codex-review`

1. Generates a review ID and validates Codex is installed
2. Builds a context-aware review prompt (detects Next.js, UI projects)
3. Runs `codex exec` with multi-agent — output streams to your terminal
4. Codex writes findings to `reviews/review-<id>.md`
5. Claude reads and presents the review to you
6. Temp files are cleaned up

No state files, no hooks, no exit blocking.

### `/review-loop`

Uses a **Stop hook** to enforce a two-phase lifecycle:

1. **Task phase**: Claude implements the task you described
2. **Review phase**: On exit, the hook prepares a Codex runner script, blocks Claude's exit, and instructs it to run the review and address findings

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
│   └── codex-review-lib.sh      # Shared library (prompt building, Codex validation)
├── AGENTS.md                    # Agent operating guidelines
└── CLAUDE.md                    # Symlink to AGENTS.md
```

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex`. Set to `--sandbox workspace-write` for safer sandboxed reviews. |

### Telemetry

Execution logs are written to `.review-loop/review-loop.log` (for `/review-loop`) or `.review-loop/codex-review.log` (for `/codex-review`). These are gitignored.

## Credits

Original plugin by [Hamel Husain](https://github.com/hamelsmu/claude-review-loop). Inspired by the [Ralph Wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) and [Ryan Carson's compound engineering loop](https://x.com/ryancarson/article/2016520542723924279).
