---
description: Show usage-guard's current usage readings, thresholds and alerts for this session
allowed-tools: Bash
---

Run:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" status "${CLAUDE_SESSION_ID}"
```

Show the user the output as-is, then add at most two sentences on anything that needs their attention.
