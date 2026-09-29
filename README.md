# usage-guard

usage-guard tells Claude when your plan's usage limits are getting close. At the warn threshold Claude starts conserving usage; at the wind-down threshold it finishes its current step, writes a handoff, stops subagents and, if usage resets soon, schedules itself to continue.

It is a Claude Code plugin written in bash and `jq`. It records the limits your status line receives and injects short alerts into your sessions through hooks.

## Does it work for me?

| Your setup | Works? | Windows tracked |
|---|---|---|
| claude.ai Pro or Max | Yes | 5-hour, weekly |
| Claude apps gateway with spend limits (Claude Code v2.1.251 or later) | Yes | spend limit |
| Either of the above, rolled out by an admin through managed settings | Yes | same |
| claude.ai Team or Enterprise seat without a gateway | No usage data | none |
| API key, Bedrock, Vertex, Foundry | No usage data | none |

Claude Code only gives usage data to the status line on the first two setups. Where there is no data, the plugin stays quiet and `/usage-guard:status` explains why. usage-guard does not try undocumented data sources.

Requirements: `jq`. macOS and Linux are supported. Windows (Git Bash) is untested. It doesn't wake idle sessions; alerts arrive with your next prompt, tool call or subagent start.

## Install

```
/plugin marketplace add <owner>/usage-guard
/plugin install usage-guard@usage-guard
/usage-guard:setup
```

Plugins can't set the status line, so `/usage-guard:setup` adds a small relay in front of your existing one. The relay records the usage data, then runs your original status line, which keeps rendering as before. If you had no status line, it prints a minimal default.

`/usage-guard:setup uninstall` restores your previous `statusLine` setting exactly. Every change to `settings.json` is backed up first, to `~/.claude/usage-guard/backups/`.

Setup is safe to repeat. It recognizes its own relay however it is written and won't wrap it in itself. It makes no changes if it can't back up or write your settings, keeps the file's permissions, and writes through a symlinked `settings.json`. If your `settings.json` is invalid JSON, setup stops and changes nothing.

Setup also refuses to install, and tells you why, when managed settings set a `statusLine` or `allowManagedHooksOnly`, or when `disableAllHooks` is true. If the managed `statusLine` already runs usage-guard's relay, setup says there is nothing to do. If your `statusLine` runs a relay from an older usage-guard install, setup stops without changes and tells you where that install kept your original status line. It warns you if a project's `.claude/settings.json` or `.claude/settings.local.json` sets its own `statusLine`, because that overrides yours in that project.

Alerts start after the first API response of a session.

## Uninstalling

1. Run `/usage-guard:setup uninstall`. This puts your original status line back, clears the recorded usage and turns alerts off straight away. Alerts stay off, even if Claude Code redraws the old status line once more, until you run `/usage-guard:setup` again.
2. Run `/plugin uninstall usage-guard@<marketplace>`.
3. Optionally, delete the data folder: `rm -rf ~/.claude/usage-guard`.

If you remove the plugin without step 1, nothing breaks: the relay lives in `~/.claude/usage-guard/bin/`, not in the plugin, so it keeps rendering your original status line. Alerts simply stop. To put your status line back afterwards, reinstall the plugin and run step 1, or copy the saved setting from `~/.claude/usage-guard/inner-statusline.json` into `statusLine` yourself.

## What Claude is told

Each of the three messages below is a file in `messages/`. Each session, and each subagent, hears about each threshold once per reset period. A wind-down message replaces a warn message for the same window. When several windows cross a threshold together, they are combined into one message with a line per window.

**Warn** (`messages/warn.md`)

> Plan usage for the {{window}} window is at {{pct}}% (resets in {{resets_in}}, at {{resets_at}}). Conserve usage: finish the current task before starting anything large, avoid spawning new subagents or broad parallel work, and prefer targeted reads over broad exploration. Keep notes of progress so a handoff is cheap if usage reaches the wind-down threshold. Briefly mention this to the user in your next reply.

**Wind down** (`messages/wind-down.md`)

> Plan usage for the {{window}} window is at {{pct}}%. Resets in {{resets_in}} (at {{resets_at}}). Wind down now:
> 1. Finish or cleanly pause the current step. Don't start new work.
> 2. If subagents are running, tell them to stop and report what's done and outstanding.
> 3. Write a handoff to `{{handoff_path}}`: goal, done, in progress, next steps, open questions, relevant files.{{commit_step}}
> 4. If the reset is within {{resume_max_wait}} and you have a tool that can schedule a future prompt in this session, schedule one for just after {{resets_at}} saying: "Usage has reset. Read {{handoff_path}} and continue." Otherwise tell the user when usage resets and that the handoff is ready.
> 5. Tell the user what you did.

**Wind down, for subagents** (`messages/wind-down-subagent.md`)

> Plan usage is at {{pct}}% ({{window}}). Stop your task now. Your final report must say you stopped because of usage limits and list what's done, what's outstanding and any partial results. Your parent session has also been told, so don't try to schedule anything.

You also see a short notice, such as `⚠️ usage-guard: 5-hour 92% ...`, when an alert is sent. Subagents started after a threshold was crossed get the current message as they start.

## Configuration

Set these with `/config`, or when you enable the plugin.

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | on | Turn alerts on or off without uninstalling. |
| `five_hour_warn` | 75 | Warn at this % of the 5-hour limit. |
| `five_hour_wind_down` | 90 | Wind down at this % of the 5-hour limit. |
| `seven_day_warn` | 85 | Warn at this % of the weekly limit. |
| `seven_day_wind_down` | 95 | Wind down at this % of the weekly limit. |
| `spend_limit_warn` | 75 | Warn at this % of your gateway spend limit. |
| `spend_limit_wind_down` | 95 | Wind down at this % of your gateway spend limit. |
| `handoff_path` | `HANDOFF.md` | Where Claude writes its handoff, relative to the project root. |
| `resume_max_wait` | `6h` | Claude only schedules a resume if usage resets within this time. Use `Nm` or `Nh`, such as `90m` or `6h`. |
| `commit_on_wind_down` | off | Also ask Claude to commit work in progress when winding down. |
| `messages_dir` | unset | Folder with your own message files (see below). |

If a threshold is not a number, or a warn value isn't below its wind-down value, the defaults for that window are used. `/usage-guard:status` reports when that happens.

## Custom messages

Set `messages_dir` to a folder containing any of `warn.md`, `wind-down.md` and `wind-down-subagent.md`. A file there replaces the built-in message of the same name; messages you don't provide keep the defaults.

Placeholders you can use:

| Placeholder | Becomes |
|---|---|
| `{{window}}` | `5-hour`, `weekly` or `spend limit` |
| `{{pct}}` | Percentage used |
| `{{resets_in}}` | Time until reset, such as `1h 12m` |
| `{{resets_at}}` | Reset time in local time |
| `{{handoff_path}}` | The `handoff_path` setting |
| `{{resume_max_wait}}` | The `resume_max_wait` setting |
| `{{commit_step}}` | Empty, unless `commit_on_wind_down` is on |

When several windows cross a threshold together, the message starts with a "Usage thresholds crossed:" list with one line per window. The placeholders in the message body (`{{window}}`, `{{pct}}`, `{{resets_in}}`, `{{resets_at}}`) describe only the top crossing (wind-down before warn, then the highest percentage); the other windows appear only in that list. An exceeded spend limit shows as "spend limit (exceeded)" in `{{window}}`; `{{pct}}` stays numeric.

## For administrators

To roll usage-guard out to a team:

1. If you use `strictKnownMarketplaces`, add the usage-guard marketplace to the allowlist.
2. Force-enable `usage-guard@<marketplace>` in managed `enabledPlugins`. Its hooks then run even under `allowManagedHooksOnly`. That exemption matches the full `plugin@marketplace` ID, so the same plugin installed from a different marketplace stays blocked.
3. Set the managed `statusLine` to the snippet that `/usage-guard:setup` prints when managed settings block it:

   ```json
   {"statusLine":{"type":"command","command":"\"$HOME/.claude/usage-guard/bin/relay.sh\""}}
   ```

   The path is the same for every user (it moves only if `CLAUDE_CONFIG_DIR` is set). On session start the guard copies the relay there if it is missing or the plugin version has changed, so it stays current with plugin updates. Once this is in place, `/usage-guard:setup` reports that there is nothing to do and `/usage-guard:status` shows the relay as configured by managed settings.

A managed `statusLine` replaces any personal status line, so users lose theirs. The relay does not wrap it. Managed settings delivered by MDM or the claude.ai console can't be read by setup; if the relay never runs, `/usage-guard:status` says so.

## Privacy

usage-guard makes no network calls, and nothing leaves your machine. It doesn't read your credentials or call any API. It does keep local files in its data folder, `~/.claude/usage-guard/` (or `usage-guard/` inside `CLAUDE_CONFIG_DIR` if you set it). The folder is kept when the plugin is uninstalled; delete it yourself if you no longer need it:

- `state.json`: the latest usage percentages and reset times.
- `sent/`: small marker files recording what each session and subagent has been told. Markers older than 8 days are deleted.
- `backups/`: a full copy of your `settings.json` from before each setup change. If that file holds env values or tokens, the backups hold them too. Delete them if you don't want them.
- `inner-statusline.json`: your original status line setting, kept so uninstall can restore it.
- `bin/`: the relay script copy.
- `config.json`, `onboarding.json` and `last_render`: a snapshot of the plugin settings, notice bookkeeping and the time the relay last ran.
- `relay-removed`: present after `/usage-guard:setup uninstall`, until the next setup. While it exists nothing is recorded and no alerts are sent.

## Migrating from hand-made hooks

If you built your own usage hooks, remove them from `~/.claude/settings.json` and delete their old state files. Otherwise Claude gets duplicate messages.

## Troubleshooting

Run `/usage-guard:status`. It shows whether the relay is configured and when it last ran, each window's usage, tier and reset time, your thresholds, and what the current session has been told.

- **"has never run"**: the relay is not being used. Your status line is overridden by managed settings or a project's `.claude/settings.json` or `.claude/settings.local.json`, or `disableAllHooks` is on.
- **"old usage-guard relay" from setup**: your `statusLine` points at a relay from an earlier install, for example under `~/.claude/plugins/data/`. Your original status line may be in that folder's `inner-statusline.json` or `backups/`. Put it back in `statusLine` (or remove the key), then run `/usage-guard:setup` again.
- **"no usage data"**: your plan doesn't provide it (see the table above), or there hasn't been an API response yet.
- **No alerts, but usage is high**: check that `enabled` is on and that the window's reading hasn't reset.

## Development

```bash
brew install bash bats-core jq shellcheck
"$(brew --prefix)/bin/bash" "$(command -v bats)" tests
UG_BASH=/bin/bash "$(brew --prefix)/bin/bash" "$(command -v bats)" tests
shellcheck scripts/*.sh
claude plugin validate . --strict
claude --plugin-dir .
```

Run bats under bash 4 or later: under macOS's bash 3.2 it does not fail a test on a failing `[[ ]]` that isn't the last command. `UG_BASH=/bin/bash` makes the tests run the scripts themselves under bash 3.2, which they must support. On Linux, `bats tests` with the system bash is enough. CI on macOS runs bats under Homebrew bash with `UG_BASH=/bin/bash`; CI on Ubuntu runs `bats tests` with the system bash.

## License

MIT
