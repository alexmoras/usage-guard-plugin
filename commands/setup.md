---
description: Install (or with "uninstall", remove) the usage-guard status line relay
argument-hint: "[uninstall]"
allowed-tools: Bash
---

Arguments: $ARGUMENTS

If the arguments are `uninstall`, run:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" uninstall
```

Otherwise run:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" install
```

Show the user the script's output. If it exited with status 2, explain that an organization or user setting is blocking the status line, and that the printed snippet is what an administrator needs. Don't edit any settings files yourself.
