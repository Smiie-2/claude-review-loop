---
description: "Start a review loop: implement task, get independent Codex review, address feedback"
argument-hint: "<task description>"
allowed-tools:
  - "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-review-loop.sh:*)"
hide-from-slash-command-tool: "true"
---

Run the setup script with the user's arguments:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-review-loop.sh" $ARGUMENTS
```

After setup completes successfully, proceed to implement the task described in the arguments. Work thoroughly and completely — write clean, well-structured, well-tested code.

When you believe the task is fully done, stop. The review loop stop hook will automatically:
1. Run Codex for an independent code review
2. Present the review for you to address

RULES:
- Complete the task to the best of your ability before stopping
- Do not stop prematurely or skip parts of the task
- The review loop handles the rest automatically
