You are orchestrating a thorough, independent code review of recent changes in this repository.

Spawn parallel sub-agents for the review paths below using whatever parallel-agent primitive your runtime provides (Codex: multi_agent; Gemini: subagent runtime / @agent dispatch). If parallel sub-agents are unavailable, run each review pass sequentially in the same session. Each agent/pass should collect its findings as structured text. After ALL agents complete, consolidate their findings into a single deduplicated review file.

IMPORTANT: Run one agent per review path below. Wait for all agents to finish. Then deduplicate overlapping findings and write the consolidated review to: {{REVIEW_FILE}}

