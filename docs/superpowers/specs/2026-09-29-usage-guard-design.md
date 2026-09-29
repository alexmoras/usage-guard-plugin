# usage-guard — Design Spec

**Date:** 2026-09-29
**Status:** Draft for review
**Audience:** Public release (Claude Code plugin marketplace)

## 1. Purpose

A Claude Code plugin that watches the account's usage limits and, when a
configurable threshold is crossed, injects instructions into the running
session (and its subagents) so Claude adapts: first by conserving usage, then
by winding down cleanly with a handoff and, where possible, a scheduled resume.

### Success criteria

- Alerts fire reliably from fresh data, without the user hand-wiring hooks or a
  status line beyond one `/usage-guard:setup` command.
- Every active session and subagent is told once per window, per reset
  period, per tier — no spam, no missed sessions.
- The plugin never breaks a session or the user's existing status line.
- No network calls and no credential access.

### Supported (v1)

| Setup | Data | Windows |
|---|---|---|
| claude.ai Pro / Max | `rate_limits` in status line input | `five_hour`, `seven_day` |
| Claude apps gateway with spend limits (Claude Code ≥ v2.1.251) | `rate_limits.spend_limit` | `spend_limit` |
| Either of the above rolled out by an admin via managed settings | same | same |

### Not supported (v1)

- claude.ai Team / Enterprise seats without a gateway. Docs state `rate_limits`
  is only present for Pro/Max or gateway spend limits. The plugin detects the
  absence of data and says so; it does not attempt undocumented data sources.
- API key / Bedrock / Vertex / Foundry direct: no usage data exists.
- Waking idle sessions (would need experimental plugin monitors; deferred).
- Windows is best-effort (Git Bash), documented as untested.

## 2. Platform constraints (from docs)

- `rate_limits` is available **only** to the `statusLine` command's stdin, and
  only after the first API response in a session. Each window may be
  independently absent; Claude Code drops a window once `resets_at` passes.
  `spend_limit.used_percentage` can exceed 100.
- Hooks do not receive `rate_limits`.
- Plugins cannot set `statusLine`; only settings files can.
- Hooks can inject `hookSpecificOutput.additionalContext` on `SessionStart`,
  `UserPromptSubmit`, `PostToolUse`, `SubagentStart` (among others);
  `systemMessage` shows a notice to the user.
- Hook input carries `session_id`, `hook_event_name`, and `agent_id` /
  `agent_type` when running inside a subagent.
- Plugins get `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}` (persistent
  across updates), and `userConfig` values as `CLAUDE_PLUGIN_OPTION_<KEY>`
  env vars in hook processes.
- Managed settings: `allowManagedHooksOnly` means only a managed `statusLine`
  runs; `disableAllHooks` (outside managed) disables the status line unless
  managed sets one; `strictKnownMarketplaces` requires admins to allowlist the
  plugin's marketplace.

## 3. Architecture

Approach: **status-line relay + hook injector**, using documented APIs only.

```
usage-guard/
├── .claude-plugin/plugin.json    manifest + userConfig
├── hooks/hooks.json              SessionStart, UserPromptSubmit, PostToolUse,
│                                 SubagentStart → scripts/guard.sh
├── scripts/
│   ├── relay.sh    status line: persist rate_limits → state.json, then run the
│   │               user's original status line and print its output
│   ├── guard.sh    hook: read state → tier per window → dedupe → emit context
│   ├── setup.sh    install / uninstall / status of the relay
│   └── lib.sh      shared helpers (paths, atomic JSON write, time formatting,
│                   template rendering)
├── commands/
│   ├── setup.md    /usage-guard:setup [uninstall]
│   └── status.md   /usage-guard:status
├── messages/
│   ├── warn.md
│   ├── wind-down.md
│   └── wind-down-subagent.md
├── tests/          bats-core suites + fixtures
└── README.md       user guide, admin rollout guide, privacy note, migration note
```

Runtime: bash + `jq`. No other dependencies.

### Data directory

`DATA = ${CLAUDE_PLUGIN_DATA:-$HOME/.claude/usage-guard}`

```
DATA/
├── state.json               latest usage per window
├── bin/relay.sh, bin/lib.sh installed copy of the relay (stable path)
├── bin/VERSION              plugin version the relay was copied from
├── inner-statusline.json    the user's original statusLine object (or null)
├── backups/settings-<ts>.json
├── sent/<session_id>/<agent|main>/<window>-<resets_at>-<tier>   dedupe markers
└── onboarding.json          notice bookkeeping (sessions without data, etc.)
```

## 4. Components

### 4.1 relay.sh (status line)

Runs on every status line render. Must be fast and must never fail visibly.

1. Read stdin once into a variable.
2. Extract `.rate_limits` windows present among `five_hour`, `seven_day`,
   `spend_limit`.
3. If any present: merge into `state.json` as
   `{ "<window>": { "used_percentage": n, "resets_at": epoch, "updated_at": epoch } }`,
   keeping other windows' existing entries. Write atomically (temp file in
   `DATA` + `mv`). Concurrent sessions: last write wins (limits are
   account-wide).
4. Run the inner status line from `inner-statusline.json` (if a command), piping
   the same stdin, and print its stdout unchanged. If none, print a minimal
   default: `<model> | 5h: N% | 7d: N%` (spend shown if present).
5. All errors are suppressed; the script always exits 0.

### 4.2 guard.sh (hooks)

Registered for `SessionStart`, `UserPromptSubmit`, `PostToolUse` (matcher
`*`), `SubagentStart`.

1. Read hook stdin: `session_id`, `agent_id` (absent → `main`),
   `hook_event_name`.
2. If `enabled` is false or `jq` missing → exit 0. When `jq` is missing, the
   event is detected with a plain `grep` on stdin; on `SessionStart` a
   hand-built JSON `systemMessage` install hint is printed (at most once per
   day, tracked by a marker file).
3. On `SessionStart`: run housekeeping (4.2.1) and onboarding checks (4.4).
4. Load `state.json`; missing or unparsable → exit 0.
5. Drop windows where `resets_at <= now`. No staleness check: usage is
   monotonic within a window, so older readings can only under-report.
6. Compute tier per window:
   - `wind-down` if `used_percentage >= wind_down_threshold[window]`
   - else `warn` if `>= warn_threshold[window]`
   - else none.
7. For each window with a tier, the dedupe key is
   `sent/<session_id>/<agent>/<window>-<resets_at>-<tier>`. Skip if the marker
   exists. Skip `warn` if the `wind-down` marker for the same window/reset
   exists.
8. If nothing new → exit 0 with no output.
9. Otherwise render one combined message: the highest tier's template (for
   subagents, `wind-down-subagent.md` replaces `wind-down.md`), listing every
   newly crossed window. Create markers for all included windows/tiers.
10. Output JSON:
    ```json
    {
      "systemMessage": "⚠️ 5h usage 91%, resets in 1h 12m",
      "hookSpecificOutput": {
        "hookEventName": "<event>",
        "additionalContext": "<rendered message>"
      }
    }
    ```
11. Always exit 0.

`SubagentStart` naturally covers subagents spawned after a threshold was
crossed: their `agent_id` has no markers, so they receive the current tier.

#### 4.2.1 Housekeeping

On `SessionStart`: delete `sent/` markers older than 8 days; if
`bin/VERSION` differs from the plugin version, re-copy `relay.sh` and `lib.sh`
into `DATA/bin/` (file copy only; settings untouched).

### 4.3 setup.sh

Invoked by `/usage-guard:setup` (install) and `/usage-guard:setup uninstall`.
The command markdown instructs Claude to run the script and relay its output.

**install**
1. Require `jq`; otherwise print install instructions and exit non-zero.
2. Read managed settings (`/Library/Application Support/ClaudeCode/managed-settings.json`
   on macOS, `/etc/claude-code/managed-settings.json` on Linux; path
   overridable via `USAGE_GUARD_MANAGED_SETTINGS` for tests). If it sets
   `statusLine`, `allowManagedHooksOnly: true`, or `disableAllHooks: true`:
   write nothing, explain which setting blocks install, and print the managed
   `statusLine` snippet for an admin.
3. If `disableAllHooks: true` is in user settings, report it and stop.
4. If `$PWD/.claude/settings.json` or `.claude/settings.local.json` sets
   `statusLine`, warn that it overrides the user setting in that project (no
   change made).
5. If `~/.claude/settings.json` `statusLine.command` already points at
   `DATA/bin/relay.sh` → report "already installed", exit 0.
6. Copy `relay.sh`, `lib.sh`, `VERSION` to `DATA/bin/`, `chmod +x`.
7. Save the current `statusLine` value (object or null) to
   `inner-statusline.json`.
8. Back up `settings.json` to `DATA/backups/settings-<ts>.json`.
9. Set `statusLine` to `{ ...existing fields, "type": "command", "command": "<DATA>/bin/relay.sh" }`,
   preserving other fields (`padding`, `refreshInterval`, …). Write via `jq` to a
   temp file then `mv`. Create `settings.json` if absent.

**uninstall**
Restore `statusLine` from `inner-statusline.json` (remove the key if it was
null), back up first, leave `DATA/` intact except `bin/`.

**status** (used by `/usage-guard:status`)
Print: relay installed?; blocking managed/user settings; per-window
percentage, tier, reset time and data age; active thresholds; dedupe markers
for the current session if `session_id` is supplied.

### 4.4 Onboarding notices (SessionStart, via systemMessage only)

- Relay not installed → "usage-guard: run /usage-guard:setup to enable usage
  alerts." Shown once per session, at most once per day.
- Relay installed but `state.json` never written after 3 sessions → "usage-guard
  hasn't received usage data. Your plan may not provide it — see
  /usage-guard:status." Shown once.

## 5. Messages

Templates in `messages/`; overridable per file via `messages_dir`.
Placeholders: `{{window}}`, `{{pct}}`, `{{resets_in}}`, `{{resets_at}}` (local
time), `{{handoff_path}}`, `{{resume_max_wait}}`, `{{commit_step}}` (empty
unless `commit_on_wind_down`). When multiple windows are included, per-window
placeholders render as a bulleted list line per window above the template body.

Window labels: `five_hour` → "5-hour", `seven_day` → "weekly",
`spend_limit` → "spend limit". Spend ≥ 100% renders "exceeded (N%)".

**warn.md**
> Plan usage for the {{window}} window is at {{pct}}% (resets in {{resets_in}},
> at {{resets_at}}). Conserve usage: finish the current task before starting
> anything large, avoid spawning new subagents or broad parallel work, and
> prefer targeted reads over broad exploration. Keep notes of progress so a
> handoff is cheap if usage reaches the wind-down threshold. Briefly mention
> this to the user in your next reply.

**wind-down.md**
> Plan usage for the {{window}} window is at {{pct}}%. Resets in {{resets_in}}
> (at {{resets_at}}). Wind down now:
> 1. Finish or cleanly pause the current step. Don't start new work.
> 2. If subagents are running, tell them to stop and report what's done and
>    outstanding.
> 3. Write a handoff to `{{handoff_path}}`: goal, done, in progress, next steps,
>    open questions, relevant files.{{commit_step}}
> 4. If the reset is within {{resume_max_wait}} and you have a tool that can
>    schedule a future prompt in this session, schedule one for just after
>    {{resets_at}} saying: "Usage has reset. Read {{handoff_path}} and
>    continue." Otherwise tell the user when usage resets and that the handoff
>    is ready.
> 5. Tell the user what you did.

**wind-down-subagent.md**
> Plan usage is at {{pct}}% ({{window}}). Stop your task now. Your final report
> must say you stopped because of usage limits and list what's done, what's
> outstanding and any partial results. Your parent session has also been told,
> so don't try to schedule anything.

`{{commit_step}}` when enabled: " Then commit work in progress if this is a
git repository."

## 6. Configuration (`userConfig`)

| Key | Type | Default |
|---|---|---|
| `enabled` | boolean | `true` |
| `five_hour_warn` | number | `75` |
| `five_hour_wind_down` | number | `90` |
| `seven_day_warn` | number | `85` |
| `seven_day_wind_down` | number | `95` |
| `spend_limit_warn` | number | `75` |
| `spend_limit_wind_down` | number | `95` |
| `handoff_path` | string | `HANDOFF.md` (relative to project root) |
| `resume_max_wait` | string | `6h` (accepts `Nm` / `Nh`) |
| `commit_on_wind_down` | boolean | `false` |
| `messages_dir` | directory | unset |

Invalid values (non-numeric, warn ≥ wind-down) fall back to defaults; `status`
reports the fallback.

## 7. Error handling

- `relay.sh` and `guard.sh` always exit 0 and never write to stderr in normal
  operation.
- Corrupt `state.json` is ignored by the guard and overwritten by the next relay
  write.
- `CLAUDE_PLUGIN_DATA` unset → `~/.claude/usage-guard/`.
- Minimum Claude Code for `spend_limit`: v2.1.251. Older versions work for
  Pro/Max windows.
- `setup.sh` is the only component that edits user settings, always with a
  backup and atomic write, and is idempotent.

## 8. Testing

- **bats-core** suites with fixture JSON, temp `HOME` and `DATA`,
  `USAGE_GUARD_MANAGED_SETTINGS`, and a clock override `USAGE_GUARD_NOW`.
  - lib: time formatting, template rendering, atomic write.
  - relay: merges windows, preserves absent windows, passes stdin to inner
    command and prints its output, default output, survives malformed input.
  - guard: tier boundaries per window; spend > 100; expired windows ignored;
    dedupe per session / agent / window / reset / tier; wind-down suppresses
    warn; combined multi-window message; subagent template selection;
    `SubagentStart` delivers current tier; missing/corrupt state; disabled;
    missing jq; housekeeping pruning and relay re-copy.
  - setup: fresh install, reinstall no-op, wraps existing statusLine and
    preserves extra fields, uninstall restores exactly (object and null
    cases), each managed-settings block, user `disableAllHooks`, project
    override warning, backup created.
- **CI:** GitHub Actions matrix (macos-latest, ubuntu-latest) running bats and
  shellcheck.
- **Manual smoke test:** `claude --plugin-dir .` with a fixture `state.json`
  over threshold; confirm the notice appears and Claude acts on the context.

## 9. Documentation

README covers: what it does; supported / unsupported setups; install and
`/usage-guard:setup`; configuration table; customizing messages; admin rollout
(allowlist marketplace under `strictKnownMarketplaces`, force-enable via
managed `enabledPlugins`, set managed `statusLine` to the relay path);
privacy note (local-only, no network, no credentials); migrating from
hand-rolled hooks (remove old hook entries and state files to avoid duplicate
messages); troubleshooting via `/usage-guard:status`.

## 10. Open items to verify during implementation

- That hooks from a plugin force-enabled via managed `enabledPlugins` run
  under `allowManagedHooksOnly` (docs imply yes). If not, the admin guide must
  instead document adding `guard.sh` to managed `hooks`.
- Exact managed-settings file paths against current docs.
- `userConfig` number type handling and env var formatting.
