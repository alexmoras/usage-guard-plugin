# usage-guard

A Claude Code plugin that warns Claude before you run out of plan usage, so it can wrap up cleanly instead of stopping mid-task.

- **At the warn threshold** (75% of your 5-hour limit, by default), Claude starts conserving usage: it finishes the current task before starting anything big and avoids spawning extra subagents.
- **At the wind-down threshold** (90%), Claude finishes or pauses the current step, stops its subagents, writes a handoff file (`HANDOFF.md`) and, if usage resets soon, schedules itself to pick up where it left off.

You see a one-line notice when this happens, for example:

```
⚠️ usage-guard: 5-hour 91%, resets in 1h 12m
```

## Which plans does it work with?

usage-guard reads the usage figures that Claude Code gives to your status line. Claude Code only provides them on some plans:

| You use Claude Code with… | Works? | What it watches |
|---|---|---|
| A claude.ai **Pro** or **Max** plan | ✅ Yes | 5-hour and weekly limits |
| A **Claude apps gateway** with spend limits (Claude Code 2.1.251 or later) | ✅ Yes | Your spend limit |
| Either of the above, rolled out by your admin | ✅ Yes | The same |
| A claude.ai **Team** or **Enterprise** seat without a gateway | ❌ No | — |
| An **API key**, **Amazon Bedrock**, **Google Vertex AI** or **Microsoft Foundry** | ❌ No | — |

On unsupported setups the plugin stays quiet, and `/usage-guard:status` tells you there's no usage data.

**You also need:**
- **macOS or Linux.** Windows with Git Bash may work but is untested.
- **`jq`.** Check with `jq --version`. To install it, run `brew install jq` on macOS or `sudo apt install jq` on Debian/Ubuntu.

## Install

Run these inside Claude Code:

```
/plugin marketplace add alexmoras/usage-guard-plugin
/plugin install usage-guard@usage-guard
```

This installs the latest [release](https://github.com/alexmoras/usage-guard-plugin/releases), never unreleased work from `main`.

Then start a new Claude Code session and run:

```
/usage-guard:setup
```

Setup is needed because Claude Code only gives usage figures to the status line, and plugins can't change your status line themselves. Setup puts a small relay in front of your status line:
- The relay records the usage figures, then runs your existing status line, so it looks the same as before.
- If you had no status line, you get a simple one showing the model and your usage.
- Your `settings.json` is backed up before anything changes.

**Check it's working.** Send any message, then run:

```
/usage-guard:status
```

You should see the relay's "last ran" time and your current usage, for example `5-hour: 14%, resets in 4h 10m`. Usage figures appear after the first reply in a session.

### Trying unreleased changes

To run the current `main`, or any other branch, without installing it, clone the repository and load it for one session:

```
git clone https://github.com/alexmoras/usage-guard-plugin.git
claude --plugin-dir /path/to/usage-guard-plugin
```

Then run `/usage-guard:setup`. When you're done, run `/usage-guard:setup uninstall`.

### Updating

Claude Code doesn't update third-party plugins automatically unless you turn it on. To get the latest release, run this in your shell, then start a new session:

```
claude plugin update usage-guard@usage-guard
```

To update automatically instead, open `/plugin`, go to **Marketplaces**, select **usage-guard** and turn on **Enable auto-update**.

## Using it

Once it's set up there's nothing to do: alerts arrive with your next message, tool call or subagent start. Each session and each subagent is told about each threshold once per usage period.

| Command | What it does |
|---|---|
| `/usage-guard:status` | Shows your current usage, your thresholds, whether the relay is working and what this session has been told. |
| `/usage-guard:setup` | Installs the status line relay. It's safe to run again. |
| `/usage-guard:setup thresholds` | Shows your alert thresholds. |
| `/usage-guard:setup thresholds 5h 80 95` | Warn at 80% and wind down at 95% of the 5-hour limit. The windows are `5h`, `weekly` and `spend`. |
| `/usage-guard:setup thresholds reset` | Puts all thresholds back to their defaults. Add a window name (`reset 5h`) to reset just one. |
| `/usage-guard:setup uninstall` | Restores your original status line and turns alerts off. |

Threshold changes apply from your next message; you don't need to restart.

## Settings

Change thresholds with `/usage-guard:setup thresholds` (above), or change any setting with `/config`:

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | on | Turn alerts on or off without uninstalling. |
| `five_hour_warn` / `five_hour_wind_down` | 75 / 90 | Thresholds for the 5-hour limit, in %. |
| `seven_day_warn` / `seven_day_wind_down` | 85 / 95 | Thresholds for the weekly limit, in %. |
| `spend_limit_warn` / `spend_limit_wind_down` | 75 / 95 | Thresholds for a gateway spend limit, in %. |
| `handoff_path` | `HANDOFF.md` | Where Claude writes its handoff, relative to the project. |
| `resume_max_wait` | `6h` | Claude only schedules itself to continue if usage resets within this time. Use minutes or hours, such as `90m` or `6h`. |
| `commit_on_wind_down` | off | Also ask Claude to commit work in progress when winding down. |
| `messages_dir` | unset | A folder with your own versions of the messages (see [Changing what Claude is told](#changing-what-claude-is-told)). |

**How thresholds are chosen:**
- A threshold set with `/usage-guard:setup thresholds` takes priority over `/config`, so `/config` may show a different number from the one in use. Both `/usage-guard:setup thresholds` and `/usage-guard:status` mark those windows "(set with /usage-guard:setup thresholds)".
- If a `/config` value is invalid, the defaults for that window are used. Invalid means not a number, or a warn value that isn't below its wind-down value.
- Lowering a threshold can send an alert straight away. Raising one never takes back an alert that's already been sent.

## Uninstalling

1. Run `/usage-guard:setup uninstall`. This restores your original status line and turns alerts off.
2. Run `/plugin uninstall usage-guard@usage-guard`.
3. If you like, delete the data folder: `rm -rf ~/.claude/usage-guard`.

**If you skip step 1**, nothing breaks. The relay keeps showing your original status line and alerts stop. To restore the original setting later, reinstall and run `/usage-guard:setup uninstall`. Or copy the saved setting from `~/.claude/usage-guard/inner-statusline.json` into `statusLine` in `~/.claude/settings.json`.

## Troubleshooting

Start with `/usage-guard:status`.

- **"no usage data received yet"**: either your plan doesn't provide usage figures (see [Which plans does it work with?](#which-plans-does-it-work-with)), or there hasn't been a reply in this session yet.
- **"has never run"**: something is overriding your status line. It could be:
  - your organization's managed settings;
  - a project's `.claude/settings.json` or `.claude/settings.local.json`;
  - `disableAllHooks`.

  Setup warns about the ones it can see.
- **"removed with /usage-guard:setup uninstall"**: alerts are off. Run `/usage-guard:setup` to turn them back on.
- **Setup says an "old usage-guard relay" was found**: your status line points at a relay from an earlier install, for example under `~/.claude/plugins/data/`. Your original status line may be in that folder's `inner-statusline.json` or `backups/`. Put it back in `statusLine` (or remove the key), then run `/usage-guard:setup` again.
- **Setup is blocked by managed settings**: your organization controls the status line. Setup prints the snippet your administrator needs (see [For administrators](#for-administrators)).
- **Usage is high but there are no alerts**: check that `enabled` is on, and look at your thresholds in `/usage-guard:status`.
- **You see duplicate alerts**: remove any usage hooks you built yourself from `~/.claude/settings.json`.

Two limits to be aware of:
- Alerts can't wake an idle session. They arrive with your next message, tool call or subagent start.
- After Claude compacts a conversation, an alert sent earlier isn't repeated.

## Changing what Claude is told

The messages are in `messages/`. To use your own, set `messages_dir` to a folder containing any of `warn.md`, `wind-down.md` and `wind-down-subagent.md`. Any file you don't provide keeps the built-in version.

These placeholders are filled in:

| Placeholder | Becomes |
|---|---|
| `{{window}}` | `5-hour`, `weekly` or `spend limit`, or `spend limit (exceeded)` when you're over it |
| `{{pct}}` | The percentage used |
| `{{resets_in}}` | The time until reset, such as `1h 12m` |
| `{{resets_at}}` | The reset time, in local time |
| `{{handoff_path}}` | The `handoff_path` setting |
| `{{resume_max_wait}}` | The `resume_max_wait` setting |
| `{{commit_step}}` | Empty, unless `commit_on_wind_down` is on |

If several limits cross a threshold at once, Claude gets one message:
- It starts with a "Usage thresholds crossed:" line for each limit.
- The placeholders in the message body describe the most urgent one: wind-down before warn, then the highest percentage.

<details>
<summary>The built-in messages</summary>

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

</details>

## For administrators

To roll usage-guard out to a team:

1. If you use `strictKnownMarketplaces`, add the usage-guard marketplace to the allowlist.
2. Force-enable `usage-guard@usage-guard` in managed `enabledPlugins`. Its hooks then run even under `allowManagedHooksOnly`. That exemption matches the full `plugin@marketplace` ID, so the same plugin installed from a different marketplace stays blocked.
3. Set the managed `statusLine` to:

   ```json
   {"statusLine":{"type":"command","command":"\"$HOME/.claude/usage-guard/bin/relay.sh\""}}
   ```

   - **The path** is the same for every user. It only changes if a user sets `CLAUDE_CONFIG_DIR`.
   - **The relay file** is copied into place by the plugin at session start, and replaced whenever the plugin is updated.
   - **Afterwards**, `/usage-guard:setup` tells users there's nothing to do, and `/usage-guard:status` shows the relay as set by managed settings.

A managed `statusLine` replaces users' personal status lines, and the relay doesn't bring them back.

Setup can't read managed settings delivered by MDM or the claude.ai admin console. If those override the status line, `/usage-guard:status` reports that the relay has never run.

## What setup changes, and privacy

`/usage-guard:setup` changes only the `statusLine` setting in `~/.claude/settings.json`. It is careful with that file:

- **Backs it up first**, to `~/.claude/usage-guard/backups/`, and changes nothing if the backup or the write fails.
- **Keeps the file intact:** the file's permissions and its other settings stay as they are. If `settings.json` is a symlink, setup writes through it.
- **Leaves broken files alone:** if `settings.json` isn't valid JSON, setup stops and changes nothing.
- **Is safe to run again:** it recognizes its own relay and never wraps it inside itself.

**Privacy:** usage-guard makes no network calls, and nothing leaves your machine. It doesn't read your credentials. It keeps these local files in `~/.claude/usage-guard/` (or in `usage-guard/` inside `CLAUDE_CONFIG_DIR`, if you set it):

| File | Contents |
|---|---|
| `state.json` | The latest usage percentages and reset times. |
| `sent/` | Markers recording what each session has been told. They're deleted after 8 days. |
| `backups/` | Full copies of your `settings.json` from before each change. If that file contains tokens or env values, so do the backups. |
| `inner-statusline.json` | Your original status line setting, so uninstall can restore it. |
| `thresholds.json` | Thresholds set with `/usage-guard:setup thresholds`. |
| `bin/` | The relay script. |
| `config.json`, `onboarding.json`, `last_render` | A copy of your settings, notice bookkeeping and when the relay last ran. |
| `relay-removed` | Present after `/usage-guard:setup uninstall`. While it exists, nothing is recorded and no alerts are sent. |

Uninstalling the plugin leaves this folder in place. Delete it yourself if you don't need it.

## Development

The plugin is written in bash (compatible with macOS's bash 3.2) and `jq`, with tests in [bats](https://github.com/bats-core/bats-core).

```bash
brew install bash bats-core jq shellcheck

"$(brew --prefix)/bin/bash" "$(command -v bats)" tests                     # tests
UG_BASH=/bin/bash "$(brew --prefix)/bin/bash" "$(command -v bats)" tests   # tests, running the scripts under bash 3.2
shellcheck scripts/*.sh
claude plugin validate . --strict
claude --plugin-dir .                                                        # try your changes
```

Run bats under bash 4 or later. Under bash 3.2 it can report a test as passing when one of its checks failed. On Linux, `bats tests` with the system bash is enough. CI runs the tests on macOS (with the scripts under bash 3.2) and on Ubuntu.

### Releasing

The marketplace installs the plugin from the `release` branch, not from `main`. Only the release workflow moves that branch, so merging to `main` changes nothing for users until you publish a release.

1. In a pull request, set `version` in `.claude-plugin/plugin.json` to the new version, for example `0.2.0`, and merge it. You can take as long as you like before step 2.
2. On GitHub, [draft a new release](https://github.com/alexmoras/usage-guard-plugin/releases/new) with the tag `v0.2.0`, targeting `main`, and publish it.

The [release workflow](.github/workflows/release.yml) then:
1. checks that the tag matches `plugin.json`'s version and is on `main`;
2. runs the tests on that commit;
3. fast-forwards `release` to it.

If any check fails, nothing changes for users. A release older than the current one is refused, and pre-releases are ignored.

Existing users get the new version when they run `claude plugin update`, or automatically if they've turned on auto-update.

The `release` branch is protected by a repository ruleset, so only GitHub Actions can update or delete it. A test in CI fails any pull request that changes where the marketplace installs from.

## License

[MIT](LICENSE)
