---
AGENT 2: Holistic Review (evaluate overall project structure and agent readiness)

Read the full project directory structure, key config files, README, and any AGENTS.md / CLAUDE.md files. This is NOT about individual line changes — it's about whether the project is well-structured for maintainability and agent-driven development.

Review criteria for the whole project:

Code Organization & Modularity:
- Is the project structure logical and navigable? Can a new developer (or agent) find things?
- Are concerns properly separated (data access, business logic, presentation, config)?
- Are there god files/functions that do too much and should be split?
- Is shared code properly extracted into reusable modules?
- Are import paths clean (absolute imports, no deep relative paths)?

Documentation & Agent Harness:
- Does every major directory have an AGENTS.md with operating guidelines for agents?
- Is there a CLAUDE.md symlinked to each AGENTS.md for Claude Code compatibility?
- Do AGENTS.md files document: conventions, file purposes, testing patterns, common pitfalls?
- Is there telemetry/observability instrumentation (logging, metrics, tracing)?
- Is there a type system in use (TypeScript, Python type hints, etc.) with proper coverage?
- Are there proper constraints and guardrails so agents working on the code are set up for success?
- Are environment variables documented and validated at startup?
- Are there clear boundaries between server-only and client-safe code?

Architecture:
- Is the dependency graph clean (no circular dependencies)?
- Are external integrations properly abstracted behind interfaces?
- Is configuration centralized rather than scattered?
- Is error handling consistent across the codebase?

For each issue: return file path (or directory), severity (critical/high/medium/low), category, description, and suggested fix.

