# claude-review-loop — Agent Guidelines

## Repository layout

```
claude-review-loop/
├── plugins/review-loop/     # Plugin source — all commands, hooks, scripts
│   ├── commands/            # Slash command definitions (.md)
│   ├── hooks/               # Stop hook for /review-loop lifecycle
│   ├── scripts/             # Shared library and test suites
│   └── AGENTS.md            # Plugin-specific agent guidelines
├── docs/                    # Generated review reports (gitignored via reviews/)
├── reviews/                 # Codex review output (generated, gitignored)
├── .review-loop/            # Ephemeral state/temp files (generated, gitignored)
└── .claude-plugin/          # Marketplace manifest
```

## Source vs generated

- **Source:** `plugins/`, `.claude-plugin/`, `README.md`, `AGENTS.md`, `.gitignore`
- **Generated (gitignored):** `reviews/`, `.review-loop/`, `docs/pr-reviews/`

Do not commit generated review files or temp state. The `reviews/` directory is created at runtime.

## Conventions

- All shell scripts must be portable across macOS and Linux
- Use `$HOME` (not `~`) in scripts for cross-platform path resolution
- Plugin-specific conventions are documented in `plugins/review-loop/AGENTS.md`
