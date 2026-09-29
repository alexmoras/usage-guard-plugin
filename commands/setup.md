---
description: Install usage-guard's status line relay, remove it ("uninstall"), or view and change alert thresholds ("thresholds")
argument-hint: "[uninstall | thresholds [<5h|weekly|spend> <warn> <wind-down> | reset [window]]]"
allowed-tools: Bash
---

Arguments: $ARGUMENTS

If the arguments are `uninstall`, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" uninstall
```

If the arguments start with `thresholds`, run the script with `thresholds` followed by each remaining argument as its own single-quoted word, for example `/usage-guard:setup thresholds 5h 80 95` becomes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" thresholds '5h' '80' '95'
```

Pass the words through as the user typed them, even if they look wrong; the script validates them and explains any problem. Never add, drop or change arguments.

With no arguments, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" install
```

For any other arguments, don't run anything; tell the user the accepted forms from the argument hint.

Show the user the script's output. If it exited with status 2, explain that an organization or user setting is blocking the status line, and that the printed snippet is what an administrator needs. Don't edit any settings or usage-guard files yourself.
