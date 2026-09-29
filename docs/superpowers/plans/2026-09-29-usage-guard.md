# usage-guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a publicly releasable Claude Code plugin that records the account's usage limits from the status line and injects tiered, once-only instructions into sessions and subagents when thresholds are crossed.

**Architecture:** A status-line relay (`relay.sh`) persists `rate_limits` to `state.json` in the plugin data directory and then renders the user's original status line. A hook script (`guard.sh`) runs on `SessionStart`, `UserPromptSubmit`, `PostToolUse` and `SubagentStart`, compares state against thresholds, dedupes with marker files per session/agent/window/reset/tier, and emits `additionalContext` + `systemMessage`. `setup.sh` is the only component that edits the user's `settings.json`.

**Tech Stack:** bash (3.2-compatible), jq, bats-core for tests, shellcheck, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-29-usage-guard-design.md`

## Global Constraints

- Runtime dependencies: bash and `jq` only. No network calls, no credential access.
- Every script must run on **bash 3.2** (macOS `/bin/bash`): no associative arrays, no `mapfile`/`readarray`, no `${var,,}`/`${var^^}`, no `declare -n`, no `&>>`.
- `relay.sh` and `guard.sh` always exit 0 and never print to stderr in normal operation.
- Only `setup.sh` edits user settings; always back up first and write atomically (or in place for symlinks).
- Data dir: `${CLAUDE_PLUGIN_DATA:-$HOME/.claude/usage-guard}`. Claude config dir: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
- Windows tracked: `five_hour`, `seven_day`, `spend_limit`. Labels: "5-hour", "weekly", "spend limit".
- Default thresholds (warn / wind-down): five_hour 75/90, seven_day 85/95, spend_limit 75/95.
- Other options and defaults: `enabled` true, `handoff_path` `HANDOFF.md`, `resume_max_wait` `6h`, `commit_on_wind_down` false, `messages_dir` unset.
- Options reach hooks as `CLAUDE_PLUGIN_OPTION_<KEY>` (key uppercased). They are **not** in the Bash tool's environment, so `/usage-guard:status` reads a snapshot (`config.json`) written by the guard.
- Minimum Claude Code for `spend_limit`: v2.1.251.
- Supported platforms: macOS and Linux. Windows (Git Bash) best-effort, documented as untested.
- No attribution trailers (`Co-Authored-By`, `Claude-Session`, "Generated with Claude Code") in commits or PRs.

## Deltas from the spec (decided while planning)

These came out of re-reading the docs; each is small and noted where implemented.

1. **Relay heartbeat.** Managed settings can come from the claude.ai console or MDM, which a script can't read. The relay writes `DATA/last_render` on every run, and onboarding/status use it to detect "configured but not running".
2. **`managed-settings.d/*.json`** is checked alongside `managed-settings.json`.
3. **Config snapshot.** Guard writes `DATA/config.json` on `SessionStart` so `status` can show the user's real thresholds.
4. **String-form `statusLine`** (`"statusLine": "cmd"`) is supported when wrapping and restoring.
5. **Uninstall keeps `DATA/bin/`.** The guard maintains the relay copy on every `SessionStart` (so admins can point managed settings at it), so deleting it would just be undone.
6. **Exceeded spend** renders the template's `{{window}}` as "spend limit (exceeded)"; `{{pct}}` stays numeric.
7. **Repo is also a marketplace**: `.claude-plugin/marketplace.json` at the root lists the plugin with `source: "./"`.
8. **Status shows this session's markers** via `${CLAUDE_SESSION_ID}` substitution in the command; if it isn't substituted, that section is skipped.

## Review Focus

1. **Existing `statusLine` in string form, or an object with extra fields (`padding`, `refreshInterval`)** — install must wrap it and keep the extra fields; uninstall must restore it byte-for-byte in meaning. (Tests in Task 6.)
2. **`~/.claude/settings.json` is a symlink** (dotfiles repos) — setup must write through the link, not replace it with a regular file. (Task 6.)
3. **Settings file missing, empty, or invalid JSON** — missing/empty is treated as `{}`; invalid JSON aborts with no changes. (Task 6.)
4. **Paths with spaces in `HOME` / data dir** — the relay command written to settings must be quoted and still run. (Task 6.)
5. **Session or agent IDs containing `/` or other odd characters** — marker paths must be sanitized so dedupe can't escape `DATA/sent/`. (Task 4.)

## File Structure

```
.claude-plugin/plugin.json        manifest + userConfig                     (Task 8)
.claude-plugin/marketplace.json   single-plugin marketplace                 (Task 8)
hooks/hooks.json                  hook registrations → scripts/guard.sh     (Task 8)
scripts/lib.sh                    shared helpers (sourced only)             (Tasks 1–2)
scripts/relay.sh                  status line relay                         (Task 3)
scripts/guard.sh                  hook entry point                          (Tasks 4–5)
scripts/setup.sh                  install / uninstall / status              (Tasks 6–7)
commands/setup.md                 /usage-guard:setup [uninstall]            (Task 7)
commands/status.md                /usage-guard:status                       (Task 7)
messages/warn.md                  warn template                             (Task 4)
messages/wind-down.md             wind-down template (main session)        (Task 4)
messages/wind-down-subagent.md    wind-down template (subagents)           (Task 4)
tests/test_helper.bash            shared bats setup                         (Task 1)
tests/lib.bats, relay.bats, guard.bats, setup.bats, status.bats
.github/workflows/ci.yml          bats + shellcheck on macOS & Ubuntu       (Task 8)
README.md, LICENSE, .gitignore                                             (Tasks 1, 9)
```

---

### Task 1: Scaffold, test harness and core helpers

**Files:**
- Create: `.gitignore`, `LICENSE`, `scripts/lib.sh`, `tests/test_helper.bash`, `tests/lib.bats`

**Interfaces:**
- Produces (in `scripts/lib.sh`):
  - `UG_WINDOWS` — string `"five_hour seven_day spend_limit"` (iterate with unquoted `for w in $UG_WINDOWS`)
  - `ug_data_dir` → prints data dir
  - `ug_config_dir` → prints Claude config dir
  - `ug_now` → prints epoch seconds (`USAGE_GUARD_NOW` overrides)
  - `ug_write_atomic <dest>` → writes stdin to dest via temp file + `mv`
  - `ug_fmt_duration <seconds>` → `"2d 3h"` / `"1h 12m"` / `"45m"`
  - `ug_fmt_local_time <epoch>` → `"Thu 00:00"` style, local TZ
  - `ug_parse_duration <"90m"|"6h">` → prints seconds, returns 1 if invalid
  - `ug_option <key> <default>` → value of `CLAUDE_PLUGIN_OPTION_<KEY>` or default
  - `ug_bool_option <key> <default>` → prints `true`/`false`
  - `ug_safe_id <string>` → path-safe id (`[A-Za-z0-9_-]`, others → `_`; empty → `unknown`)
  - `ug_have_jq` → exit 0 if jq available (`USAGE_GUARD_JQ` overrides the binary name, for tests)
- Produces (in `tests/test_helper.bash`): `setup_env`, `teardown_env`, variables `ROOT`, `TEST_TMP`, `UG_BASH`, `NOW`, `RESET`, `WEEK_RESET`.

- [ ] **Step 1: Install dev tools**

Run: `brew install bats-core shellcheck` (Linux: `sudo apt-get install -y bats shellcheck jq`)
Expected: `bats --version` prints `Bats 1.x`; `shellcheck --version` prints a version.

- [ ] **Step 2: Create `.gitignore` and `LICENSE`**

`.gitignore`:
```
.DS_Store
*.swp
/tmp/
```

`LICENSE`: the standard MIT License text with the line `Copyright (c) 2026 Alex`.

- [ ] **Step 3: Write the test helper**

`tests/test_helper.bash`:
```bash
# Shared setup for usage-guard bats suites.

NOW=1790000000
RESET=$((NOW + 4320))         # 1h 12m from NOW
WEEK_RESET=$((NOW + 266400))  # 3d 2h from NOW

setup_env() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_TMP="$(mktemp -d)"
  export TZ=UTC
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME/.claude"
  export CLAUDE_PLUGIN_DATA="$TEST_TMP/data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  export USAGE_GUARD_MANAGED_DIR="$TEST_TMP/managed"
  export USAGE_GUARD_NOW=$NOW
  unset CLAUDE_CONFIG_DIR USAGE_GUARD_JQ
  local v
  for v in $(compgen -v CLAUDE_PLUGIN_OPTION_); do unset "$v"; done
  UG_BASH="${UG_BASH:-bash}"
}

teardown_env() {
  rm -rf "$TEST_TMP"
}

# Run a script from scripts/ with stdin from $2.
run_script() {
  local script=$1 stdin=$2
  shift 2
  run "$UG_BASH" "$ROOT/scripts/$script" "$@" <<<"$stdin"
}

write_state() {
  printf '%s' "$1" >"$CLAUDE_PLUGIN_DATA/state.json"
}

# state_entry <window> <pct> [resets_at] -> {"<window>": {...}}
state_entry() {
  jq -nc --arg w "$1" --argjson p "$2" --argjson r "${3:-$RESET}" --argjson u "$NOW" \
    '{($w): {used_percentage: $p, resets_at: $r, updated_at: $u}}'
}

# hook_input <event> [session_id] [agent_id]
hook_input() {
  jq -nc --arg e "$1" --arg s "${2:-sess1}" --arg a "${3:-}" \
    '{hook_event_name: $e, session_id: $s} + (if $a == "" then {} else {agent_id: $a, agent_type: "general-purpose"} end)'
}
```

- [ ] **Step 4: Write the failing tests**

`tests/lib.bats`:
```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  # shellcheck source=../scripts/lib.sh
  . "$ROOT/scripts/lib.sh"
}
teardown() { teardown_env; }

@test "ug_data_dir uses CLAUDE_PLUGIN_DATA, else ~/.claude/usage-guard" {
  [ "$(ug_data_dir)" = "$TEST_TMP/data" ]
  unset CLAUDE_PLUGIN_DATA
  [ "$(ug_data_dir)" = "$HOME/.claude/usage-guard" ]
}

@test "ug_config_dir honours CLAUDE_CONFIG_DIR" {
  [ "$(ug_config_dir)" = "$HOME/.claude" ]
  CLAUDE_CONFIG_DIR=/x/y
  [ "$(ug_config_dir)" = "/x/y" ]
}

@test "ug_now uses USAGE_GUARD_NOW" {
  [ "$(ug_now)" = "$NOW" ]
}

@test "ug_write_atomic writes content and leaves no temp files" {
  printf 'hello' | ug_write_atomic "$TEST_TMP/out/file.json"
  [ "$(cat "$TEST_TMP/out/file.json")" = "hello" ]
  [ "$(ls -A "$TEST_TMP/out" | wc -l | tr -d ' ')" = 1 ]
}

@test "ug_fmt_duration formats days, hours and minutes" {
  [ "$(ug_fmt_duration 4320)" = "1h 12m" ]
  [ "$(ug_fmt_duration 266400)" = "3d 2h" ]
  [ "$(ug_fmt_duration 2700)" = "45m" ]
  [ "$(ug_fmt_duration -5)" = "0m" ]
}

@test "ug_fmt_local_time formats an epoch in local time" {
  [ "$(ug_fmt_local_time 0)" = "Thu 00:00" ]
}

@test "ug_parse_duration accepts Nm and Nh only" {
  [ "$(ug_parse_duration 90m)" = 5400 ]
  [ "$(ug_parse_duration 6h)" = 21600 ]
  [ "$(ug_parse_duration 08h)" = 28800 ]
  run ug_parse_duration 6
  [ "$status" -eq 1 ]
  run ug_parse_duration abc
  [ "$status" -eq 1 ]
}

@test "ug_option reads CLAUDE_PLUGIN_OPTION_<KEY> or returns the default" {
  [ "$(ug_option handoff_path HANDOFF.md)" = "HANDOFF.md" ]
  export CLAUDE_PLUGIN_OPTION_HANDOFF_PATH=docs/NEXT.md
  [ "$(ug_option handoff_path HANDOFF.md)" = "docs/NEXT.md" ]
}

@test "ug_bool_option normalises values and falls back on junk" {
  [ "$(ug_bool_option enabled true)" = true ]
  export CLAUDE_PLUGIN_OPTION_ENABLED=false
  [ "$(ug_bool_option enabled true)" = false ]
  export CLAUDE_PLUGIN_OPTION_ENABLED=0
  [ "$(ug_bool_option enabled true)" = false ]
  export CLAUDE_PLUGIN_OPTION_ENABLED=maybe
  [ "$(ug_bool_option enabled true)" = true ]
}

@test "ug_safe_id keeps ids inside one path segment" {
  [ "$(ug_safe_id abc-123_X)" = "abc-123_X" ]
  [ "$(ug_safe_id ../../etc)" = "______etc" ]
  [ "$(ug_safe_id 'a/b c')" = "a_b_c" ]
  [ "$(ug_safe_id '')" = "unknown" ]
}

@test "ug_have_jq honours USAGE_GUARD_JQ" {
  ug_have_jq
  USAGE_GUARD_JQ=/nonexistent/jq
  run ug_have_jq
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `bats tests/lib.bats`
Expected: FAIL — `scripts/lib.sh: No such file or directory`.

- [ ] **Step 6: Implement core helpers**

`scripts/lib.sh`:
```bash
#!/usr/bin/env bash
# Shared helpers for usage-guard scripts. Sourced, never executed.
# Must stay compatible with bash 3.2 (macOS /bin/bash).

UG_WINDOWS="five_hour seven_day spend_limit"

ug_data_dir() {
  printf '%s' "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/usage-guard}"
}

ug_config_dir() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

ug_now() {
  printf '%s' "${USAGE_GUARD_NOW:-$(date +%s)}"
}

ug_have_jq() {
  command -v "${USAGE_GUARD_JQ:-jq}" >/dev/null 2>&1
}

# Write stdin to $1 atomically: temp file in the same directory, then rename.
ug_write_atomic() {
  local dest=$1 dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.ug.XXXXXX") || return 1
  if cat >"$tmp"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Seconds -> "2d 3h", "1h 12m" or "45m".
ug_fmt_duration() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  local d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  if [ "$d" -gt 0 ]; then
    printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh %dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

# Epoch -> "Thu 14:30" in local time. BSD date first, then GNU date.
ug_fmt_local_time() {
  date -r "$1" '+%a %H:%M' 2>/dev/null || date -d "@$1" '+%a %H:%M'
}

# "90m" / "6h" -> seconds. Returns 1 for anything else.
ug_parse_duration() {
  if [[ $1 =~ ^([0-9]+)([mh])$ ]]; then
    local n=$((10#${BASH_REMATCH[1]}))
    if [ "${BASH_REMATCH[2]}" = h ]; then
      echo $((n * 3600))
    else
      echo $((n * 60))
    fi
  else
    return 1
  fi
}

# Plugin option from CLAUDE_PLUGIN_OPTION_<KEY>, or $2 when unset/empty.
ug_option() {
  local var
  var="CLAUDE_PLUGIN_OPTION_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${!var:-}" ]; then
    printf '%s' "${!var}"
  else
    printf '%s' "$2"
  fi
}

ug_bool_option() {
  case $(ug_option "$1" "$2") in
    true | TRUE | True | 1 | yes) echo true ;;
    false | FALSE | False | 0 | no) echo false ;;
    *) echo "$2" ;;
  esac
}

# Make an id safe to use as a single path segment.
ug_safe_id() {
  if [ -z "$1" ]; then
    printf 'unknown'
  else
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
  fi
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bats tests/lib.bats && UG_BASH=/bin/bash bats tests/lib.bats`
Expected: all tests PASS.

- [ ] **Step 8: Lint**

Run: `shellcheck scripts/lib.sh`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add .gitignore LICENSE scripts/lib.sh tests/test_helper.bash tests/lib.bats
git commit -m "Add core shell helpers and test harness"
```

---

### Task 2: Thresholds, formatting, templates and relay install helpers

**Files:**
- Modify: `scripts/lib.sh` (append)
- Test: `tests/lib.bats` (append)

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces (in `scripts/lib.sh`):
  - `ug_default_threshold <window> <warn|wind_down>` → number
  - `ug_thresholds_json` → `{"five_hour":{"warn":75,"wind_down":90,"fallback":false},...}` (fallback true when options were invalid)
  - `ug_window_label <window>` → `5-hour` / `weekly` / `spend limit`
  - `ug_fmt_pct <window> <pct>` → `91%`, or `exceeded (104%)` for spend ≥ 100
  - `ug_resume_max_wait` → valid `resume_max_wait` option or `6h`
  - `ug_render_template <file> <vars_json>` → file text with `{{key}}` replaced by string values
  - `ug_template_path <plugin_root> <name>` → `$messages_dir/<name>` if that file exists, else `<plugin_root>/messages/<name>`
  - `ug_plugin_version <plugin_root>` → `version` from `.claude-plugin/plugin.json` (or `0`)
  - `ug_install_relay_files <plugin_root> <data_dir>` → copies `relay.sh`, `lib.sh` into `<data>/bin/`, writes `<data>/bin/VERSION`
  - `ug_relay_command <data_dir>` → `"<data>/bin/relay.sh"` including the double quotes (what goes in `statusLine.command`)
  - `ug_statusline_command <settings_file>` → the `statusLine` command from a settings file (object `.command` or string form), empty if none

- [ ] **Step 1: Write the failing tests** (append to `tests/lib.bats`)

```bash
@test "ug_thresholds_json returns defaults" {
  run ug_thresholds_json
  [ "$(jq -c .five_hour <<<"$output")" = '{"warn":75,"wind_down":90,"fallback":false}' ]
  [ "$(jq -c .seven_day <<<"$output")" = '{"warn":85,"wind_down":95,"fallback":false}' ]
  [ "$(jq -c .spend_limit <<<"$output")" = '{"warn":75,"wind_down":95,"fallback":false}' ]
}

@test "ug_thresholds_json uses valid options" {
  export CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WARN=60 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WIND_DOWN=80.5
  run ug_thresholds_json
  [ "$(jq -c .five_hour <<<"$output")" = '{"warn":60,"wind_down":80.5,"fallback":false}' ]
}

@test "ug_thresholds_json falls back when values are junk or inverted" {
  export CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WARN=abc
  export CLAUDE_PLUGIN_OPTION_SEVEN_DAY_WARN=96 CLAUDE_PLUGIN_OPTION_SEVEN_DAY_WIND_DOWN=90
  export CLAUDE_PLUGIN_OPTION_SPEND_LIMIT_WARN=075
  run ug_thresholds_json
  [ "$(jq -c .five_hour <<<"$output")" = '{"warn":75,"wind_down":90,"fallback":true}' ]
  [ "$(jq -c .seven_day <<<"$output")" = '{"warn":85,"wind_down":95,"fallback":true}' ]
  [ "$(jq -c .spend_limit <<<"$output")" = '{"warn":75,"wind_down":95,"fallback":true}' ]
}

@test "ug_window_label and ug_fmt_pct" {
  [ "$(ug_window_label five_hour)" = "5-hour" ]
  [ "$(ug_window_label seven_day)" = "weekly" ]
  [ "$(ug_window_label spend_limit)" = "spend limit" ]
  [ "$(ug_fmt_pct five_hour 91.6)" = "91%" ]
  [ "$(ug_fmt_pct five_hour 104)" = "104%" ]
  [ "$(ug_fmt_pct spend_limit 104.2)" = "exceeded (104%)" ]
  [ "$(ug_fmt_pct spend_limit 99)" = "99%" ]
}

@test "ug_resume_max_wait validates the option" {
  [ "$(ug_resume_max_wait)" = "6h" ]
  export CLAUDE_PLUGIN_OPTION_RESUME_MAX_WAIT=90m
  [ "$(ug_resume_max_wait)" = "90m" ]
  export CLAUDE_PLUGIN_OPTION_RESUME_MAX_WAIT=soon
  [ "$(ug_resume_max_wait)" = "6h" ]
}

@test "ug_render_template replaces placeholders literally" {
  printf 'At {{pct}}%% of {{window}}; {{pct}} again. {{unknown}}\n' >"$TEST_TMP/t.md"
  run ug_render_template "$TEST_TMP/t.md" '{"pct":"91","window":"a & b \\1 $x"}'
  [ "$output" = 'At 91% of a & b \1 $x; 91 again. {{unknown}}' ]
}

@test "ug_template_path prefers messages_dir when the file exists there" {
  mkdir -p "$TEST_TMP/custom"
  echo custom >"$TEST_TMP/custom/warn.md"
  [ "$(ug_template_path "$ROOT" warn.md)" = "$ROOT/messages/warn.md" ]
  export CLAUDE_PLUGIN_OPTION_MESSAGES_DIR="$TEST_TMP/custom"
  [ "$(ug_template_path "$ROOT" warn.md)" = "$TEST_TMP/custom/warn.md" ]
  [ "$(ug_template_path "$ROOT" wind-down.md)" = "$ROOT/messages/wind-down.md" ]
}

@test "ug_plugin_version reads plugin.json" {
  mkdir -p "$TEST_TMP/p/.claude-plugin"
  echo '{"name":"x","version":"1.2.3"}' >"$TEST_TMP/p/.claude-plugin/plugin.json"
  [ "$(ug_plugin_version "$TEST_TMP/p")" = "1.2.3" ]
  [ "$(ug_plugin_version "$TEST_TMP/missing")" = "0" ]
}

@test "ug_install_relay_files copies relay, lib and VERSION" {
  mkdir -p "$TEST_TMP/p/.claude-plugin" "$TEST_TMP/p/scripts"
  echo '{"version":"2.0.0"}' >"$TEST_TMP/p/.claude-plugin/plugin.json"
  echo 'relay' >"$TEST_TMP/p/scripts/relay.sh"
  echo 'lib' >"$TEST_TMP/p/scripts/lib.sh"
  ug_install_relay_files "$TEST_TMP/p" "$TEST_TMP/d"
  [ -x "$TEST_TMP/d/bin/relay.sh" ]
  [ "$(cat "$TEST_TMP/d/bin/lib.sh")" = lib ]
  [ "$(cat "$TEST_TMP/d/bin/VERSION")" = "2.0.0" ]
}

@test "ug_relay_command quotes the path" {
  [ "$(ug_relay_command "/a b/data")" = '"/a b/data/bin/relay.sh"' ]
}

@test "ug_statusline_command reads object and string forms" {
  echo '{"statusLine":{"type":"command","command":"foo.sh","padding":1}}' >"$TEST_TMP/s1.json"
  echo '{"statusLine":"bar.sh"}' >"$TEST_TMP/s2.json"
  echo '{}' >"$TEST_TMP/s3.json"
  [ "$(ug_statusline_command "$TEST_TMP/s1.json")" = "foo.sh" ]
  [ "$(ug_statusline_command "$TEST_TMP/s2.json")" = "bar.sh" ]
  [ -z "$(ug_statusline_command "$TEST_TMP/s3.json")" ]
  [ -z "$(ug_statusline_command "$TEST_TMP/missing.json")" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/lib.bats`
Expected: FAIL — `ug_thresholds_json: command not found` (and similar).

- [ ] **Step 3: Implement** (append to `scripts/lib.sh`)

```bash
ug_default_threshold() {
  case "$1:$2" in
    five_hour:warn) echo 75 ;;
    five_hour:wind_down) echo 90 ;;
    seven_day:warn) echo 85 ;;
    seven_day:wind_down) echo 95 ;;
    spend_limit:warn) echo 75 ;;
    spend_limit:wind_down) echo 95 ;;
  esac
}

ug_is_number() {
  [[ $1 =~ ^(0|[1-9][0-9]*)([.][0-9]+)?$ ]]
}

# Effective thresholds per window. Invalid or inverted pairs fall back to defaults.
ug_thresholds_json() {
  local json='{}' w dw dd warn wind fb
  for w in $UG_WINDOWS; do
    dw=$(ug_default_threshold "$w" warn)
    dd=$(ug_default_threshold "$w" wind_down)
    warn=$(ug_option "${w}_warn" "$dw")
    wind=$(ug_option "${w}_wind_down" "$dd")
    fb=false
    if ! ug_is_number "$warn" || ! ug_is_number "$wind" ||
      awk -v a="$warn" -v b="$wind" 'BEGIN { exit !(a >= b) }'; then
      warn=$dw wind=$dd fb=true
    fi
    json=$(jq -c --arg w "$w" --argjson a "$warn" --argjson b "$wind" --argjson f "$fb" \
      '.[$w] = {warn: $a, wind_down: $b, fallback: $f}' <<<"$json")
  done
  printf '%s' "$json"
}

ug_window_label() {
  case $1 in
    five_hour) echo "5-hour" ;;
    seven_day) echo "weekly" ;;
    spend_limit) echo "spend limit" ;;
    *) echo "$1" ;;
  esac
}

# Whole-number percentage; spend at or over 100 reads "exceeded (N%)".
ug_fmt_pct() {
  local p=${2%%.*}
  if [ "$1" = spend_limit ] && [ "$p" -ge 100 ]; then
    printf 'exceeded (%s%%)' "$p"
  else
    printf '%s%%' "$p"
  fi
}

ug_resume_max_wait() {
  local v
  v=$(ug_option resume_max_wait 6h)
  if ug_parse_duration "$v" >/dev/null; then echo "$v"; else echo 6h; fi
}

# Replace {{key}} with each string value in $2 (a JSON object). jq gsub keeps
# replacement text literal, so values may contain &, \ or $.
ug_render_template() {
  jq -Rrs --argjson v "$2" \
    'reduce ($v | to_entries[]) as $e (.; gsub("\\{\\{" + $e.key + "\\}\\}"; $e.value)) | sub("\n$"; "")' "$1"
}

ug_template_path() {
  local custom
  custom=$(ug_option messages_dir "")
  if [ -n "$custom" ] && [ -f "$custom/$2" ]; then
    printf '%s' "$custom/$2"
  else
    printf '%s' "$1/messages/$2"
  fi
}

ug_plugin_version() {
  local v
  v=$(jq -r '.version // empty' "$1/.claude-plugin/plugin.json" 2>/dev/null)
  printf '%s' "${v:-0}"
}

ug_install_relay_files() {
  local root=$1 data=$2
  mkdir -p "$data/bin" || return 1
  cp "$root/scripts/relay.sh" "$root/scripts/lib.sh" "$data/bin/" || return 1
  chmod +x "$data/bin/relay.sh"
  ug_plugin_version "$root" >"$data/bin/VERSION"
}

ug_relay_command() {
  printf '"%s/bin/relay.sh"' "$1"
}

ug_statusline_command() {
  [ -f "$1" ] || return 0
  jq -r '.statusLine
    | if type == "object" then (.command // "")
      elif type == "string" then .
      else "" end' "$1" 2>/dev/null
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/lib.bats && UG_BASH=/bin/bash bats tests/lib.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/lib.sh
git add scripts/lib.sh tests/lib.bats
git commit -m "Add threshold, formatting and template helpers"
```

---

### Task 3: Status line relay

**Files:**
- Create: `scripts/relay.sh`
- Test: `tests/relay.bats`

**Interfaces:**
- Consumes: `ug_now`, `ug_write_atomic` from `lib.sh` (sourced from the relay's own directory).
- Produces:
  - `DATA/state.json`: `{"<window>": {"used_percentage": n, "resets_at": epoch, "updated_at": epoch}}`, windows merged across renders.
  - `DATA/last_render`: epoch of the most recent run (heartbeat, spec delta 1).
  - Stdout: the inner status line's output, or the default line.
- The relay's data dir is **always the parent of its own directory** (it runs from `DATA/bin/relay.sh`, where `CLAUDE_PLUGIN_DATA` isn't set).
- Reads `DATA/inner-statusline.json`: `null`, a string command, or an object with `type: "command"` and `command`.

- [ ] **Step 1: Write the failing tests**

`tests/relay.bats`:
```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  mkdir -p "$CLAUDE_PLUGIN_DATA/bin"
  cp "$ROOT/scripts/relay.sh" "$ROOT/scripts/lib.sh" "$CLAUDE_PLUGIN_DATA/bin/"
}
teardown() { teardown_env; }

run_relay() {
  run "$UG_BASH" "$CLAUDE_PLUGIN_DATA/bin/relay.sh" <<<"$1"
}

sl_input() {
  jq -nc --argjson rl "${1:-null}" '{model: {display_name: "Opus"}} + (if $rl == null then {} else {rate_limits: $rl} end)'
}

@test "records windows with updated_at and writes heartbeat" {
  run_relay "$(sl_input "{\"five_hour\":{\"used_percentage\":42.5,\"resets_at\":$RESET}}")"
  [ "$status" -eq 0 ]
  [ "$(jq -c .five_hour "$CLAUDE_PLUGIN_DATA/state.json")" = "{\"used_percentage\":42.5,\"resets_at\":$RESET,\"updated_at\":$NOW}" ]
  [ "$(cat "$CLAUDE_PLUGIN_DATA/last_render")" = "$NOW" ]
}

@test "keeps windows that are absent from this render" {
  write_state "$(state_entry seven_day 50 "$WEEK_RESET")"
  run_relay "$(sl_input "{\"five_hour\":{\"used_percentage\":10,\"resets_at\":$RESET}}")"
  [ "$(jq -r '.seven_day.used_percentage' "$CLAUDE_PLUGIN_DATA/state.json")" = 50 ]
  [ "$(jq -r '.five_hour.used_percentage' "$CLAUDE_PLUGIN_DATA/state.json")" = 10 ]
}

@test "records spend_limit and ignores unknown windows" {
  run_relay "$(sl_input "{\"spend_limit\":{\"used_percentage\":104,\"resets_at\":$RESET},\"other\":{\"used_percentage\":1,\"resets_at\":1}}")"
  [ "$(jq -r '.spend_limit.used_percentage' "$CLAUDE_PLUGIN_DATA/state.json")" = 104 ]
  [ "$(jq -r 'has("other")' "$CLAUDE_PLUGIN_DATA/state.json")" = false ]
}

@test "no rate_limits leaves state untouched" {
  run_relay "$(sl_input)"
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/state.json" ]
  [ -f "$CLAUDE_PLUGIN_DATA/last_render" ]
}

@test "replaces a corrupt state file" {
  write_state 'not json'
  run_relay "$(sl_input "{\"five_hour\":{\"used_percentage\":5,\"resets_at\":$RESET}}")"
  [ "$(jq -r '.five_hour.used_percentage' "$CLAUDE_PLUGIN_DATA/state.json")" = 5 ]
}

@test "default line without an inner status line" {
  run_relay "$(sl_input "{\"five_hour\":{\"used_percentage\":42.5,\"resets_at\":$RESET},\"seven_day\":{\"used_percentage\":9,\"resets_at\":$WEEK_RESET}}")"
  [ "$output" = "Opus | 5h: 42% | 7d: 9%" ]
}

@test "runs the inner object command with the same stdin" {
  jq -nc --arg c "cat > '$TEST_TMP/inner-stdin'; echo INNER" '{type: "command", command: $c, padding: 0}' \
    >"$CLAUDE_PLUGIN_DATA/inner-statusline.json"
  input=$(sl_input)
  run_relay "$input"
  [ "$output" = "INNER" ]
  [ "$(cat "$TEST_TMP/inner-stdin")" = "$input" ]
}

@test "runs a string-form inner command" {
  echo '"echo STRING-FORM"' >"$CLAUDE_PLUGIN_DATA/inner-statusline.json"
  run_relay "$(sl_input)"
  [ "$output" = "STRING-FORM" ]
}

@test "survives garbage input" {
  run_relay "}{ not json"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/relay.bats`
Expected: FAIL — `cp: .../scripts/relay.sh: No such file or directory`.

- [ ] **Step 3: Implement**

`scripts/relay.sh`:
```bash
#!/usr/bin/env bash
# Status line relay for usage-guard. Records rate_limits for guard.sh, then
# renders the user's original status line. Must never fail visibly.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Installed as DATA/bin/relay.sh, where CLAUDE_PLUGIN_DATA isn't set.
data=$(dirname "$SCRIPT_DIR")
input=$(cat)
now=$(ug_now)

record_state() {
  local rl current
  printf '%s' "$now" >"$data/last_render"
  rl=$(jq -c '.rate_limits // {}
    | with_entries(select((.key == "five_hour" or .key == "seven_day" or .key == "spend_limit")
        and (.value.used_percentage != null)))' <<<"$input") || return 0
  [ -n "$rl" ] && [ "$rl" != '{}' ] || return 0
  current=$(jq -c 'if type == "object" then . else {} end' "$data/state.json" 2>/dev/null)
  [ -n "$current" ] || current='{}'
  jq -nc --argjson cur "$current" --argjson rl "$rl" --argjson now "$now" \
    '$cur + ($rl | map_values({used_percentage, resets_at, updated_at: $now}))' |
    ug_write_atomic "$data/state.json"
}

default_line() {
  jq -r '[.model.display_name // empty]
    + (.rate_limits // {} | [
        (.five_hour.used_percentage | select(. != null) | "5h: \(floor)%"),
        (.seven_day.used_percentage | select(. != null) | "7d: \(floor)%"),
        (.spend_limit.used_percentage | select(. != null) | "spend: \(floor)%")
      ])
    | join(" | ")' <<<"$input"
}

render() {
  local inner
  inner=$(jq -r 'if type == "string" then .
    elif type == "object" and .type == "command" then (.command // "")
    else "" end' "$data/inner-statusline.json" 2>/dev/null)
  if [ -n "$inner" ]; then
    printf '%s' "$input" | bash -c "$inner"
  else
    default_line
  fi
}

record_state 2>/dev/null
render 2>/dev/null
exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/relay.bats && UG_BASH=/bin/bash bats tests/relay.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/relay.sh
git add scripts/relay.sh tests/relay.bats
git commit -m "Add status line relay"
```

---

### Task 4: Message templates and guard core

**Files:**
- Create: `messages/warn.md`, `messages/wind-down.md`, `messages/wind-down-subagent.md`, `scripts/guard.sh`
- Test: `tests/guard.bats`

**Interfaces:**
- Consumes: all `lib.sh` helpers from Tasks 1–2; `DATA/state.json` from Task 3.
- Produces:
  - `guard.sh` reads hook JSON on stdin; prints nothing, or one JSON object:
    `{"systemMessage": "...", "hookSpecificOutput": {"hookEventName": "<event>", "additionalContext": "..."}}`
  - Marker files `DATA/sent/<safe session_id>/<safe agent_id or main>/<window>-<resets_at>-<warn|wind_down>`.
  - Template placeholders: `window`, `pct`, `resets_in`, `resets_at`, `handoff_path`, `resume_max_wait`, `commit_step`.
- Task 5 extends `guard.sh` by filling in `session_start` (defined here as a no-op).

- [ ] **Step 1: Create the templates**

`messages/warn.md`:
```
Plan usage for the {{window}} window is at {{pct}}% (resets in {{resets_in}}, at {{resets_at}}). Conserve usage: finish the current task before starting anything large, avoid spawning new subagents or broad parallel work, and prefer targeted reads over broad exploration. Keep notes of progress so a handoff is cheap if usage reaches the wind-down threshold. Briefly mention this to the user in your next reply.
```

`messages/wind-down.md`:
```
Plan usage for the {{window}} window is at {{pct}}%. Resets in {{resets_in}} (at {{resets_at}}). Wind down now:
1. Finish or cleanly pause the current step. Don't start new work.
2. If subagents are running, tell them to stop and report what's done and outstanding.
3. Write a handoff to `{{handoff_path}}`: goal, done, in progress, next steps, open questions, relevant files.{{commit_step}}
4. If the reset is within {{resume_max_wait}} and you have a tool that can schedule a future prompt in this session, schedule one for just after {{resets_at}} saying: "Usage has reset. Read {{handoff_path}} and continue." Otherwise tell the user when usage resets and that the handoff is ready.
5. Tell the user what you did.
```

`messages/wind-down-subagent.md`:
```
Plan usage is at {{pct}}% ({{window}}). Stop your task now. Your final report must say you stopped because of usage limits and list what's done, what's outstanding and any partial results. Your parent session has also been told, so don't try to schedule anything.
```

- [ ] **Step 2: Write the failing tests**

`tests/guard.bats`:
```bash
#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

run_guard() { run_script guard.sh "$1"; }
ctx() { jq -r '.hookSpecificOutput.additionalContext' <<<"$output"; }
sysmsg() { jq -r '.systemMessage' <<<"$output"; }

@test "no state file: silent" {
  run_guard "$(hook_input UserPromptSubmit)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "below warn: silent" {
  write_state "$(state_entry five_hour 74.9)"
  run_guard "$(hook_input PostToolUse)"
  [ -z "$output" ]
}

@test "warn fires once per session with rendered template" {
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit s1)"
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = UserPromptSubmit ]
  [[ $(ctx) == "Plan usage for the 5-hour window is at 80% (resets in 1h 12m, at "* ]]
  [[ $(ctx) == *"Conserve usage"* ]]
  [ "$(sysmsg)" = "⚠️ usage-guard: 5-hour 80%, resets in 1h 12m" ]
  [ -f "$CLAUDE_PLUGIN_DATA/sent/s1/main/five_hour-$RESET-warn" ]
  run_guard "$(hook_input PostToolUse s1)"
  [ -z "$output" ]
}

@test "another session is told separately" {
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit s1)"
  run_guard "$(hook_input UserPromptSubmit s2)"
  [[ $(ctx) == *"Conserve usage"* ]]
}

@test "wind-down after warn, then nothing more" {
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit)"
  write_state "$(state_entry five_hour 91)"
  run_guard "$(hook_input PostToolUse)"
  [[ $(ctx) == *"Wind down now"* ]]
  [[ $(ctx) == *'Write a handoff to `HANDOFF.md`'* ]]
  [[ $(ctx) == *"within 6h"* ]]
  run_guard "$(hook_input PostToolUse)"
  [ -z "$output" ]
}

@test "straight to wind-down suppresses a later warn for the same window" {
  write_state "$(state_entry five_hour 95)"
  run_guard "$(hook_input UserPromptSubmit)"
  [[ $(ctx) == *"Wind down now"* ]]
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit)"
  [ -z "$output" ]
}

@test "a new reset period warns again" {
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit)"
  write_state "$(state_entry five_hour 80 $((RESET + 18000)))"
  run_guard "$(hook_input UserPromptSubmit)"
  [[ $(ctx) == *"Conserve usage"* ]]
}

@test "expired windows are ignored" {
  write_state "$(state_entry five_hour 99 "$NOW")"
  run_guard "$(hook_input UserPromptSubmit)"
  [ -z "$output" ]
}

@test "several windows combine into one message led by the highest tier" {
  write_state "$(jq -sc 'add' <<<"$(state_entry five_hour 80) $(state_entry seven_day 96 "$WEEK_RESET")")"
  run_guard "$(hook_input UserPromptSubmit)"
  [[ $(ctx) == "Usage thresholds crossed:"* ]]
  [[ $(ctx) == *"- weekly: 96% (resets in 3d 2h, at "* ]]
  [[ $(ctx) == *"- 5-hour: 80% (resets in 1h 12m, at "* ]]
  [[ $(ctx) == *"Plan usage for the weekly window is at 96%"* ]]
  [[ $(ctx) == *"Wind down now"* ]]
  [ "$(sysmsg)" = "⚠️ usage-guard: weekly 96%, resets in 3d 2h; 5-hour 80%, resets in 1h 12m" ]
  [ -f "$CLAUDE_PLUGIN_DATA/sent/sess1/main/five_hour-$RESET-warn" ]
  [ -f "$CLAUDE_PLUGIN_DATA/sent/sess1/main/seven_day-$WEEK_RESET-wind_down" ]
}

@test "spend over 100 reads as exceeded" {
  write_state "$(state_entry spend_limit 104.2)"
  run_guard "$(hook_input UserPromptSubmit)"
  [[ $(ctx) == "Plan usage for the spend limit (exceeded) window is at 104%."* ]]
  [ "$(sysmsg)" = "⚠️ usage-guard: spend limit exceeded (104%), resets in 1h 12m" ]
}

@test "subagents get their own markers and the subagent template" {
  write_state "$(state_entry five_hour 92)"
  run_guard "$(hook_input UserPromptSubmit sess1)"
  run_guard "$(hook_input PostToolUse sess1 agent-7)"
  [[ $(ctx) == "Plan usage is at 92% (5-hour). Stop your task now."* ]]
  [ -f "$CLAUDE_PLUGIN_DATA/sent/sess1/agent-7/five_hour-$RESET-wind_down" ]
}

@test "subagent warn uses the normal warn template" {
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input PostToolUse sess1 agent-7)"
  [[ $(ctx) == *"Conserve usage"* ]]
}

@test "SubagentStart delivers the current tier to a new subagent" {
  write_state "$(state_entry five_hour 92)"
  run_guard "$(hook_input SubagentStart sess1 agent-9)"
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = SubagentStart ]
  [[ $(ctx) == *"Stop your task now"* ]]
}

@test "hostile session ids stay inside sent/" {
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit '../../evil' '../x')"
  [ -f "$CLAUDE_PLUGIN_DATA/sent/______evil/___x/five_hour-$RESET-warn" ]
  [ ! -e "$TEST_TMP/evil" ]
}

@test "options change thresholds, handoff path, resume wait and commit step" {
  export CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WARN=50 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WIND_DOWN=60
  export CLAUDE_PLUGIN_OPTION_HANDOFF_PATH=docs/NEXT.md CLAUDE_PLUGIN_OPTION_RESUME_MAX_WAIT=90m
  export CLAUDE_PLUGIN_OPTION_COMMIT_ON_WIND_DOWN=true
  write_state "$(state_entry five_hour 61)"
  run_guard "$(hook_input UserPromptSubmit)"
  [[ $(ctx) == *'Write a handoff to `docs/NEXT.md`'* ]]
  [[ $(ctx) == *"relevant files. Then commit work in progress if this is a git repository."* ]]
  [[ $(ctx) == *"within 90m"* ]]
}

@test "messages_dir overrides a template" {
  mkdir -p "$TEST_TMP/msgs"
  echo 'CUSTOM {{window}} {{pct}}' >"$TEST_TMP/msgs/warn.md"
  export CLAUDE_PLUGIN_OPTION_MESSAGES_DIR="$TEST_TMP/msgs"
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit)"
  [ "$(ctx)" = "CUSTOM 5-hour 80" ]
}

@test "disabled: silent" {
  export CLAUDE_PLUGIN_OPTION_ENABLED=false
  write_state "$(state_entry five_hour 95)"
  run_guard "$(hook_input UserPromptSubmit)"
  [ -z "$output" ]
}

@test "corrupt state: silent, exit 0" {
  write_state '{oops'
  run_guard "$(hook_input UserPromptSubmit)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "garbage stdin: silent, exit 0" {
  write_state "$(state_entry five_hour 95)"
  run_guard "not json"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats tests/guard.bats`
Expected: FAIL — `scripts/guard.sh: No such file or directory`.

- [ ] **Step 4: Implement**

`scripts/guard.sh`:
```bash
#!/usr/bin/env bash
# Hook entry point for usage-guard: turns recorded usage into one-time
# instructions for Claude. Always exits 0 so it can never block a session.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

input=$(cat)
data=$(ug_data_dir)
now=$(ug_now)
TAB=$(printf '\t')

# Filled in by Task 5; prints an optional user notice.
session_start() {
  :
}

# Marker directory for this session and agent.
marker_dir() {
  local session agent
  session=$(jq -r '.session_id // ""' <<<"$input")
  agent=$(jq -r '.agent_id // "main"' <<<"$input")
  printf '%s/sent/%s/%s' "$data" "$(ug_safe_id "$session")" "$(ug_safe_id "$agent")"
}

# Prints "window<TAB>tier<TAB>pct<TAB>resets_at" for each crossing this
# session/agent hasn't been told about yet.
new_crossings() {
  local dir=$1 th
  [ -f "$data/state.json" ] || return 0
  th=$(ug_thresholds_json)
  jq -r --argjson th "$th" --argjson now "$now" '
    if type == "object" then . else {} end
    | to_entries[]
    | select($th[.key] != null and ((.value.resets_at // 0) > $now))
    | .value.used_percentage as $p
    | (if $p >= $th[.key].wind_down then "wind_down"
       elif $p >= $th[.key].warn then "warn"
       else empty end) as $tier
    | [.key, $tier, ($p | tostring), (.value.resets_at | tostring)] | @tsv' "$data/state.json" |
    while IFS="$TAB" read -r window tier pct resets; do
      [ -e "$dir/$window-$resets-$tier" ] && continue
      [ "$tier" = warn ] && [ -e "$dir/$window-$resets-wind_down" ] && continue
      printf '%s\t%s\t%s\t%s\n' "$window" "$tier" "$pct" "$resets"
    done
}

# Builds the hook output for new crossings (wind_down first, then highest %).
emit() {
  local event=$1 notice=$2 crossings=$3 dir=$4
  if [ -z "$crossings" ]; then
    [ -n "$notice" ] && jq -nc --arg m "$notice" '{systemMessage: $m}'
    return 0
  fi

  local sorted count lines="" summary="" window tier pct resets label shown left
  sorted=$(printf '%s\n' "$crossings" | sort -t "$TAB" -k2,2r -k3,3nr)
  count=$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')
  mkdir -p "$dir"
  while IFS="$TAB" read -r window tier pct resets; do
    label=$(ug_window_label "$window")
    shown=$(ug_fmt_pct "$window" "$pct")
    left=$(ug_fmt_duration $((resets - now)))
    lines="$lines- $label: $shown (resets in $left, at $(ug_fmt_local_time "$resets"))
"
    summary="${summary:+$summary; }$label $shown, resets in $left"
    touch "$dir/$window-$resets-$tier"
  done <<<"$sorted"

  local p_window p_tier p_pct p_resets p_label template commit_step="" vars body context sm
  IFS="$TAB" read -r p_window p_tier p_pct p_resets <<<"$(printf '%s\n' "$sorted" | head -n 1)"
  p_label=$(ug_window_label "$p_window")
  if [ "$p_window" = spend_limit ] && [ "${p_pct%%.*}" -ge 100 ]; then
    p_label="$p_label (exceeded)"
  fi
  if [ "$p_tier" = warn ]; then
    template=warn.md
  elif [ -n "$(jq -r '.agent_id // empty' <<<"$input")" ]; then
    template=wind-down-subagent.md
  else
    template=wind-down.md
  fi
  if [ "$(ug_bool_option commit_on_wind_down false)" = true ]; then
    commit_step=" Then commit work in progress if this is a git repository."
  fi
  vars=$(jq -nc \
    --arg window "$p_label" \
    --arg pct "${p_pct%%.*}" \
    --arg resets_in "$(ug_fmt_duration $((p_resets - now)))" \
    --arg resets_at "$(ug_fmt_local_time "$p_resets")" \
    --arg handoff_path "$(ug_option handoff_path HANDOFF.md)" \
    --arg resume_max_wait "$(ug_resume_max_wait)" \
    --arg commit_step "$commit_step" \
    '$ARGS.named')
  body=$(ug_render_template "$(ug_template_path "$ROOT" "$template")" "$vars")

  context=$body
  if [ "$count" -gt 1 ]; then
    context="Usage thresholds crossed:
$lines
$body"
  fi
  sm="⚠️ usage-guard: $summary"
  [ -n "$notice" ] && sm="$notice
$sm"
  jq -nc --arg e "$event" --arg c "$context" --arg s "$sm" \
    '{systemMessage: $s, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

main() {
  local event notice="" dir
  ug_have_jq || return 0
  event=$(jq -r '.hook_event_name // empty' <<<"$input") || return 0
  if [ "$event" = SessionStart ]; then
    notice=$(session_start)
  fi
  if [ "$(ug_bool_option enabled true)" != true ]; then
    [ -n "$notice" ] && jq -nc --arg m "$notice" '{systemMessage: $m}'
    return 0
  fi
  dir=$(marker_dir)
  emit "$event" "$notice" "$(new_crossings "$dir")" "$dir"
}

main 2>/dev/null
exit 0
```

Note on the `jq -nc ... '$ARGS.named'` call: it builds an object from every `--arg`, so all values are strings, which `ug_render_template` requires.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/guard.bats && UG_BASH=/bin/bash bats tests/guard.bats`
Expected: all PASS.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck scripts/guard.sh
git add messages scripts/guard.sh tests/guard.bats
git commit -m "Add hook guard with tiered, deduplicated alerts"
```

---

### Task 5: SessionStart — housekeeping, relay upkeep, config snapshot, onboarding, missing jq

**Files:**
- Modify: `scripts/guard.sh` (replace the `session_start` stub; add the no-jq branch in `main`)
- Test: `tests/guard.bats` (append)

**Interfaces:**
- Consumes: `ug_install_relay_files`, `ug_plugin_version`, `ug_thresholds_json`, `ug_statusline_command`, `ug_relay_command`, `ug_config_dir`.
- Produces:
  - `DATA/config.json`: `{"enabled": bool, "thresholds": <ug_thresholds_json>, "handoff_path": str, "resume_max_wait": str, "commit_on_wind_down": bool, "messages_dir": str, "updated_at": epoch}` (read by `setup.sh status` in Task 7).
  - `DATA/onboarding.json`: `{"last_setup_notice_day": int, "sessions_without_data": int, "no_data_shown": bool}`.
  - `DATA/.nojq-<day>`: marker limiting the missing-jq notice to once a day.
  - `DATA/bin/relay.sh`, `DATA/bin/lib.sh` and `DATA/bin/VERSION` are always present and current after any `SessionStart`.

- [ ] **Step 1: Write the failing tests** (append to `tests/guard.bats`)

```bash
fake_plugin_root() {
  # Copy the plugin so tests can change its version without touching the repo.
  cp -R "$ROOT" "$TEST_TMP/plugin"
  jq '.version = "9.9.9"' "$ROOT/.claude-plugin/plugin.json" >"$TEST_TMP/plugin/.claude-plugin/plugin.json"
}

@test "SessionStart installs relay files and refreshes them on version change" {
  run_guard "$(hook_input SessionStart)"
  [ -x "$CLAUDE_PLUGIN_DATA/bin/relay.sh" ]
  [ -f "$CLAUDE_PLUGIN_DATA/bin/lib.sh" ]
  [ "$(cat "$CLAUDE_PLUGIN_DATA/bin/VERSION")" = "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" ]
  fake_plugin_root
  run "$UG_BASH" "$TEST_TMP/plugin/scripts/guard.sh" <<<"$(hook_input SessionStart)"
  [ "$(cat "$CLAUDE_PLUGIN_DATA/bin/VERSION")" = "9.9.9" ]
}

@test "SessionStart prunes markers older than 8 days" {
  mkdir -p "$CLAUDE_PLUGIN_DATA/sent/old/main" "$CLAUDE_PLUGIN_DATA/sent/new/main"
  touch -t 202001010000 "$CLAUDE_PLUGIN_DATA/sent/old/main/five_hour-1-warn"
  touch "$CLAUDE_PLUGIN_DATA/sent/new/main/five_hour-1-warn"
  run_guard "$(hook_input SessionStart)"
  [ ! -e "$CLAUDE_PLUGIN_DATA/sent/old" ]
  [ -f "$CLAUDE_PLUGIN_DATA/sent/new/main/five_hour-1-warn" ]
}

@test "SessionStart writes a config snapshot" {
  export CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WARN=60 CLAUDE_PLUGIN_OPTION_ENABLED=false
  run_guard "$(hook_input SessionStart)"
  [ "$(jq -r .thresholds.five_hour.warn "$CLAUDE_PLUGIN_DATA/config.json")" = 60 ]
  [ "$(jq -r .enabled "$CLAUDE_PLUGIN_DATA/config.json")" = false ]
  [ "$(jq -r .handoff_path "$CLAUDE_PLUGIN_DATA/config.json")" = HANDOFF.md ]
}

@test "onboarding: setup hint when relay has never run, once per day" {
  run_guard "$(hook_input SessionStart s1)"
  [ "$(sysmsg)" = "usage-guard: run /usage-guard:setup to enable usage alerts." ]
  run_guard "$(hook_input SessionStart s2)"
  [ -z "$output" ]
  export USAGE_GUARD_NOW=$((NOW + 86400))
  run_guard "$(hook_input SessionStart s3)"
  [[ $(sysmsg) == *"/usage-guard:setup"* ]]
}

@test "onboarding: configured but never ran points to status" {
  jq -n --arg c "\"$CLAUDE_PLUGIN_DATA/bin/relay.sh\"" '{statusLine: {type: "command", command: $c}}' \
    >"$HOME/.claude/settings.json"
  run_guard "$(hook_input SessionStart)"
  [[ $(sysmsg) == "usage-guard's status line relay is configured but hasn't run."* ]]
}

@test "onboarding: no-data notice after 3 sessions, shown once" {
  echo "$NOW" >"$CLAUDE_PLUGIN_DATA/last_render"
  run_guard "$(hook_input SessionStart s1)"
  [ -z "$output" ]
  run_guard "$(hook_input SessionStart s2)"
  [ -z "$output" ]
  run_guard "$(hook_input SessionStart s3)"
  [[ $(sysmsg) == "usage-guard hasn't received any usage data."* ]]
  run_guard "$(hook_input SessionStart s4)"
  [ -z "$output" ]
}

@test "onboarding: silent once data is flowing" {
  echo "$NOW" >"$CLAUDE_PLUGIN_DATA/last_render"
  write_state "$(state_entry five_hour 10)"
  run_guard "$(hook_input SessionStart)"
  [ -z "$output" ]
}

@test "SessionStart combines an onboarding notice with an alert" {
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input SessionStart)"
  [ "$(sysmsg)" = "usage-guard: run /usage-guard:setup to enable usage alerts.
⚠️ usage-guard: 5-hour 80%, resets in 1h 12m" ]
  [[ $(ctx) == *"Conserve usage"* ]]
}

@test "missing jq: one notice per day on SessionStart, silent otherwise" {
  export USAGE_GUARD_JQ=/nonexistent/jq
  run_guard '{"hook_event_name":"UserPromptSubmit","session_id":"s"}'
  [ -z "$output" ]
  run_guard '{"hook_event_name": "SessionStart","session_id":"s"}'
  [[ $output == *'"systemMessage":"usage-guard needs jq'* ]]
  run_guard '{"hook_event_name":"SessionStart","session_id":"s"}'
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/guard.bats`
Expected: the new tests FAIL (no relay files, no config.json, no notices).

- [ ] **Step 3: Implement**

In `scripts/guard.sh`, replace the `session_start` stub with:
```bash
# SessionStart upkeep. Prints an optional one-line notice for the user.
session_start() {
  housekeeping
  snapshot_config
  onboarding
}

housekeeping() {
  if [ -d "$data/sent" ]; then
    find "$data/sent" -type f -mtime +8 -delete
    find "$data/sent" -mindepth 1 -type d -empty -delete
  fi
  if [ ! -f "$data/bin/relay.sh" ] ||
    [ "$(cat "$data/bin/VERSION" 2>/dev/null)" != "$(ug_plugin_version "$ROOT")" ]; then
    ug_install_relay_files "$ROOT" "$data"
  fi
}

# Hooks see plugin options but the Bash tool doesn't, so /usage-guard:status
# reads this snapshot.
snapshot_config() {
  jq -nc \
    --argjson enabled "$(ug_bool_option enabled true)" \
    --argjson thresholds "$(ug_thresholds_json)" \
    --arg handoff_path "$(ug_option handoff_path HANDOFF.md)" \
    --arg resume_max_wait "$(ug_resume_max_wait)" \
    --argjson commit "$(ug_bool_option commit_on_wind_down false)" \
    --arg messages_dir "$(ug_option messages_dir "")" \
    --argjson now "$now" \
    '{enabled: $enabled, thresholds: $thresholds, handoff_path: $handoff_path,
      resume_max_wait: $resume_max_wait, commit_on_wind_down: $commit,
      messages_dir: $messages_dir, updated_at: $now}' |
    ug_write_atomic "$data/config.json"
}

onboarding() {
  local file="$data/onboarding.json" state day
  state=$(jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null)
  [ -n "$state" ] || state='{}'
  day=$((now / 86400))
  if [ -f "$data/last_render" ]; then
    [ -f "$data/state.json" ] && return 0
    state=$(jq -c '.sessions_without_data = ((.sessions_without_data // 0) + 1)' <<<"$state")
    if [ "$(jq -r '.sessions_without_data >= 3 and (.no_data_shown | not)' <<<"$state")" = true ]; then
      state=$(jq -c '.no_data_shown = true' <<<"$state")
      echo "usage-guard hasn't received any usage data. Your plan may not provide it; run /usage-guard:status for details."
    fi
  elif [ "$(jq -r --argjson d "$day" '.last_setup_notice_day == $d' <<<"$state")" != true ]; then
    state=$(jq -c --argjson d "$day" '.last_setup_notice_day = $d' <<<"$state")
    if [ "$(ug_statusline_command "$(ug_config_dir)/settings.json")" = "$(ug_relay_command "$data")" ]; then
      echo "usage-guard's status line relay is configured but hasn't run. Managed or project settings may override it; run /usage-guard:status for details."
    else
      echo "usage-guard: run /usage-guard:setup to enable usage alerts."
    fi
  fi
  printf '%s' "$state" | ug_write_atomic "$file"
}

nojq_notice() {
  local marker
  marker="$data/.nojq-$((now / 86400))"
  [ -e "$marker" ] && return 0
  mkdir -p "$data" && touch "$marker"
  printf '%s\n' '{"systemMessage":"usage-guard needs jq to work. Install it (macOS: brew install jq; Debian/Ubuntu: sudo apt install jq) and restart Claude Code."}'
}
```

In `main`, replace `ug_have_jq || return 0` with:
```bash
  if ! ug_have_jq; then
    if printf '%s' "$input" | grep -q '"hook_event_name" *: *"SessionStart"'; then
      nojq_notice
    fi
    return 0
  fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/guard.bats && UG_BASH=/bin/bash bats tests/guard.bats`
Expected: all PASS. (The version-refresh test needs `.claude-plugin/plugin.json`; if Task 8 hasn't run yet, create it now with `{"name":"usage-guard","version":"0.1.0"}` — Task 8 fills in the rest.)

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/guard.sh
git add scripts/guard.sh tests/guard.bats .claude-plugin/plugin.json
git commit -m "Add SessionStart upkeep, config snapshot and onboarding notices"
```

---

### Task 6: setup.sh install and uninstall

**Files:**
- Create: `scripts/setup.sh`
- Test: `tests/setup.bats`

**Interfaces:**
- Consumes: `ug_data_dir`, `ug_config_dir`, `ug_now`, `ug_write_atomic`, `ug_install_relay_files`, `ug_relay_command`, `ug_statusline_command`, `ug_have_jq`.
- Produces:
  - CLI: `setup.sh install` / `setup.sh uninstall` / `setup.sh status [session_id]` (status added in Task 7).
  - Exit codes: `0` success or no-op; `1` error (missing jq, invalid JSON, copy failure); `2` blocked by settings.
  - `DATA/inner-statusline.json`: the previous `statusLine` value (JSON `null`, string or object).
  - `DATA/backups/settings-<epoch>.json` before every settings write.
  - Env override for tests: `USAGE_GUARD_MANAGED_DIR`.

- [ ] **Step 1: Write the failing tests**

`tests/setup.bats`:
```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  SETTINGS="$HOME/.claude/settings.json"
  RELAY_CMD="\"$CLAUDE_PLUGIN_DATA/bin/relay.sh\""
  cd "$TEST_TMP"
}
teardown() { teardown_env; }

run_setup() { run "$UG_BASH" "$ROOT/scripts/setup.sh" "$@"; }

@test "fresh install creates settings with the relay" {
  run_setup install
  [ "$status" -eq 0 ]
  [ "$(jq -c .statusLine "$SETTINGS")" = "$(jq -nc --arg c "$RELAY_CMD" '{type: "command", command: $c}')" ]
  [ "$(cat "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = "null" ]
  [ -x "$CLAUDE_PLUGIN_DATA/bin/relay.sh" ]
  [[ $output == *"Installed"* ]]
}

@test "empty settings file is treated as {}" {
  : >"$SETTINGS"
  run_setup install
  [ "$status" -eq 0 ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
}

@test "wraps an existing object statusLine and keeps extra fields and other keys" {
  echo '{"model":"opus","statusLine":{"type":"command","command":"~/sl.sh","padding":2,"refreshInterval":5}}' >"$SETTINGS"
  run_setup install
  [ "$(jq -r .model "$SETTINGS")" = opus ]
  [ "$(jq -c '.statusLine | {padding, refreshInterval, command}' "$SETTINGS")" = "$(jq -nc --arg c "$RELAY_CMD" '{padding: 2, refreshInterval: 5, command: $c}')" ]
  [ "$(jq -c . "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = '{"type":"command","command":"~/sl.sh","padding":2,"refreshInterval":5}' ]
  ls "$CLAUDE_PLUGIN_DATA"/backups/settings-*.json
}

@test "wraps a string-form statusLine" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
  [ "$(jq -c . "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = '"~/sl.sh"' ]
}

@test "reinstall is a no-op and keeps the saved inner status line" {
  echo '{"statusLine":{"type":"command","command":"~/sl.sh"}}' >"$SETTINGS"
  run_setup install
  run_setup install
  [ "$status" -eq 0 ]
  [[ $output == *"already installed"* ]]
  [ "$(jq -r .command "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = "~/sl.sh" ]
}

@test "invalid JSON aborts without changes" {
  echo '{nope' >"$SETTINGS"
  run_setup install
  [ "$status" -eq 1 ]
  [ "$(cat "$SETTINGS")" = '{nope' ]
}

@test "symlinked settings stay a symlink" {
  mkdir -p "$TEST_TMP/dotfiles"
  echo '{}' >"$TEST_TMP/dotfiles/settings.json"
  ln -s "$TEST_TMP/dotfiles/settings.json" "$SETTINGS"
  run_setup install
  [ -L "$SETTINGS" ]
  [ "$(jq -r .statusLine.command "$TEST_TMP/dotfiles/settings.json")" = "$RELAY_CMD" ]
}

@test "data dir with spaces produces a runnable quoted command" {
  export CLAUDE_PLUGIN_DATA="$TEST_TMP/data dir"
  run_setup install
  cmd=$(jq -r .statusLine.command "$SETTINGS")
  [ "$cmd" = "\"$TEST_TMP/data dir/bin/relay.sh\"" ]
  run bash -c "$cmd" <<<'{"model":{"display_name":"Opus"}}'
  [ "$output" = "Opus" ]
}

@test "managed statusLine blocks install and prints an admin snippet" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR"
  echo '{"statusLine":{"type":"command","command":"corp.sh"}}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"statusLine is set in $USAGE_GUARD_MANAGED_DIR/managed-settings.json"* ]]
  [[ $output == *'bin/relay.sh'* ]]
  [ ! -f "$SETTINGS" ]
}

@test "allowManagedHooksOnly in managed-settings.d blocks install" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR/managed-settings.d"
  echo '{"allowManagedHooksOnly":true}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.d/10-hooks.json"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"allowManagedHooksOnly is true"* ]]
}

@test "managed disableAllHooks blocks install" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR"
  echo '{"disableAllHooks":true}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"disableAllHooks is true"* ]]
}

@test "user disableAllHooks blocks install" {
  echo '{"disableAllHooks":true}' >"$SETTINGS"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"disableAllHooks is true in $SETTINGS"* ]]
  [ "$(jq -c . "$SETTINGS")" = '{"disableAllHooks":true}' ]
}

@test "warns about a project statusLine override" {
  mkdir -p "$TEST_TMP/.claude"
  echo '{"statusLine":"proj.sh"}' >"$TEST_TMP/.claude/settings.local.json"
  run_setup install
  [ "$status" -eq 0 ]
  [[ $output == *"$TEST_TMP/.claude/settings.local.json sets its own statusLine"* ]]
}

@test "uninstall restores an object statusLine exactly" {
  echo '{"statusLine":{"type":"command","command":"~/sl.sh","padding":2}}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ "$status" -eq 0 ]
  [ "$(jq -c .statusLine "$SETTINGS")" = '{"type":"command","command":"~/sl.sh","padding":2}' ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/inner-statusline.json" ]
}

@test "uninstall removes the key when there was none, keeping other keys" {
  echo '{"model":"opus"}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ "$(jq -c . "$SETTINGS")" = '{"model":"opus"}' ]
}

@test "uninstall restores a string statusLine" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ "$(jq -c .statusLine "$SETTINGS")" = '"~/sl.sh"' ]
}

@test "uninstall does nothing when the relay isn't the current status line" {
  echo '{"statusLine":"other.sh"}' >"$SETTINGS"
  run_setup uninstall
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to undo"* ]]
  [ "$(jq -c . "$SETTINGS")" = '{"statusLine":"other.sh"}' ]
}

@test "missing jq fails with install instructions" {
  export USAGE_GUARD_JQ=/nonexistent/jq
  run_setup install
  [ "$status" -eq 1 ]
  [[ $output == *"brew install jq"* ]]
}

@test "unknown subcommand prints usage" {
  run_setup frobnicate
  [ "$status" -eq 1 ]
  [[ $output == *"usage: setup.sh install|uninstall|status"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/setup.bats`
Expected: FAIL — `scripts/setup.sh: No such file or directory`.

- [ ] **Step 3: Implement**

`scripts/setup.sh`:
```bash
#!/usr/bin/env bash
# Installs, removes and reports on the usage-guard status line relay.
# The only usage-guard script that edits user settings.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

data=$(ug_data_dir)
settings="$(ug_config_dir)/settings.json"
relay_cmd=$(ug_relay_command "$data")
now=$(ug_now)

managed_dir() {
  if [ -n "${USAGE_GUARD_MANAGED_DIR:-}" ]; then
    printf '%s' "$USAGE_GUARD_MANAGED_DIR"
  elif [ "$(uname -s)" = Darwin ]; then
    printf '%s' "/Library/Application Support/ClaudeCode"
  else
    printf '%s' "/etc/claude-code"
  fi
}

# One line per managed-settings key that stops a personal status line from running.
# Settings delivered by MDM or the claude.ai console can't be read here; the
# relay heartbeat (DATA/last_render) catches those.
managed_blockers() {
  local dir f
  dir=$(managed_dir)
  for f in "$dir/managed-settings.json" "$dir"/managed-settings.d/*.json; do
    [ -f "$f" ] || continue
    jq -r --arg f "$f" '
      (if (.statusLine // null) != null then "statusLine is set in \($f)" else empty end),
      (if .allowManagedHooksOnly == true then "allowManagedHooksOnly is true in \($f)" else empty end),
      (if .disableAllHooks == true then "disableAllHooks is true in \($f)" else empty end)' "$f" 2>/dev/null
  done
}

admin_snippet() {
  local path="$data/bin/relay.sh"
  case $path in
    "$HOME"/*) path="\$HOME${path#"$HOME"}" ;;
  esac
  jq -n --arg c "\"$path\"" '{statusLine: {type: "command", command: $c}}'
}

settings_json() {
  if [ -s "$settings" ]; then cat "$settings"; else echo '{}'; fi
}

backup_settings() {
  [ -f "$settings" ] || return 0
  mkdir -p "$data/backups"
  cp "$settings" "$data/backups/settings-$now.json"
}

# Write stdin to settings; write through symlinks so dotfile links survive.
write_settings() {
  local content
  content=$(cat)
  if [ -L "$settings" ]; then
    printf '%s\n' "$content" >"$settings"
  else
    printf '%s\n' "$content" | ug_write_atomic "$settings"
  fi
}

project_warnings() {
  local f
  for f in "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '(.statusLine // null) != null' "$f" 2>/dev/null)" = true ]; then
      echo "Note: $f sets its own statusLine, which overrides yours in this project. Alerts won't work here until it's removed or pointed at $relay_cmd."
    fi
  done
}

cmd_install() {
  local blockers current updated
  if ! ug_have_jq; then
    echo "usage-guard needs jq. Install it (macOS: brew install jq; Debian/Ubuntu: sudo apt install jq), then run setup again."
    return 1
  fi
  blockers=$(managed_blockers)
  if [ -n "$blockers" ]; then
    echo "Your organization's managed settings stop a personal status line from running:"
    printf '%s\n' "$blockers" | sed 's/^/  - /'
    echo
    echo "Nothing was changed. Ask an administrator to add this to managed settings (see the README's admin guide):"
    admin_snippet
    return 2
  fi
  if [ -s "$settings" ] && ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    echo "$settings isn't a valid JSON object. Fix it and run setup again. Nothing was changed."
    return 1
  fi
  current=$(settings_json)
  if [ "$(jq -r '.disableAllHooks == true' <<<"$current")" = true ]; then
    echo "disableAllHooks is true in $settings, which also turns off the status line. Set it to false, then run setup again."
    return 2
  fi
  project_warnings
  if ! ug_install_relay_files "$ROOT" "$data"; then
    echo "Couldn't copy the relay into $data/bin."
    return 1
  fi
  if [ "$(ug_statusline_command "$settings")" = "$relay_cmd" ]; then
    echo "usage-guard is already installed."
    return 0
  fi
  jq '.statusLine // null' <<<"$current" | ug_write_atomic "$data/inner-statusline.json"
  backup_settings
  updated=$(jq --arg cmd "$relay_cmd" \
    '.statusLine = ((if (.statusLine | type) == "object" then .statusLine else {} end) + {type: "command", command: $cmd})' \
    <<<"$current") || return 1
  printf '%s\n' "$updated" | write_settings
  echo "Installed. usage-guard now records usage from your status line; your previous status line (if any) still renders."
  echo "Alerts start after the next API response. Check anytime with /usage-guard:status."
}

cmd_uninstall() {
  local inner updated
  if [ "$(ug_statusline_command "$settings")" != "$relay_cmd" ]; then
    echo "usage-guard's relay isn't your current status line; nothing to undo."
    return 0
  fi
  inner=$(jq -c . "$data/inner-statusline.json" 2>/dev/null)
  [ -n "$inner" ] || inner=null
  backup_settings
  updated=$(jq --argjson inner "$inner" \
    'if $inner == null then del(.statusLine) else .statusLine = $inner end' "$settings") || return 1
  printf '%s\n' "$updated" | write_settings
  rm -f "$data/inner-statusline.json"
  echo "Removed. Your previous status line setting has been restored."
}

case ${1:-} in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "usage: setup.sh install|uninstall|status [session_id]"
    exit 1
    ;;
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/setup.bats && UG_BASH=/bin/bash bats tests/setup.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck scripts/setup.sh
git add scripts/setup.sh tests/setup.bats
git commit -m "Add setup script to install and remove the status line relay"
```

---

### Task 7: Status report and slash commands

**Files:**
- Modify: `scripts/setup.sh` (add `cmd_status`, wire the `status` case)
- Create: `commands/setup.md`, `commands/status.md`
- Test: `tests/status.bats`

**Interfaces:**
- Consumes: `DATA/config.json` (Task 5), `DATA/state.json` (Task 3), `DATA/last_render` (Task 3), `managed_blockers` (Task 6).
- Produces: `setup.sh status [session_id]` — a plain-text report; `session_id` values that are empty or start with `$` (unsubstituted) are ignored.

- [ ] **Step 1: Write the failing tests**

`tests/status.bats`:
```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  cd "$TEST_TMP"
}
teardown() { teardown_env; }

run_status() { run "$UG_BASH" "$ROOT/scripts/setup.sh" status "$@"; }

@test "fresh machine: not configured, never ran, no data, default thresholds" {
  run_status
  [ "$status" -eq 0 ]
  [[ $output == *"not configured in $HOME/.claude/settings.json (run /usage-guard:setup)"* ]]
  [[ $output == *"has never run"* ]]
  [[ $output == *"no usage data received yet"* ]]
  [[ $output == *"5-hour: 75% / 90%"* ]]
}

@test "installed and running with data" {
  "$UG_BASH" "$ROOT/scripts/setup.sh" install >/dev/null
  echo $((NOW - 120)) >"$CLAUDE_PLUGIN_DATA/last_render"
  write_state "$(jq -sc add <<<"$(state_entry five_hour 91) $(state_entry seven_day 40 "$WEEK_RESET")")"
  run_status
  [[ $output == *"configured in $HOME/.claude/settings.json"* ]]
  [[ $output == *"last ran 2m ago"* ]]
  [[ $output == *"5-hour: 91% (wind-down), resets in 1h 12m at "* ]]
  [[ $output == *"weekly: 40%, resets in 3d 2h at "* ]]
}

@test "expired windows are reported as reset" {
  write_state "$(state_entry five_hour 99 "$NOW")"
  run_status
  [[ $output == *"5-hour: window has reset (last reading 99%)"* ]]
}

@test "uses the config snapshot and flags fallbacks" {
  echo '{"enabled":false,"thresholds":{"five_hour":{"warn":60,"wind_down":80,"fallback":false},"seven_day":{"warn":85,"wind_down":95,"fallback":true},"spend_limit":{"warn":75,"wind_down":95,"fallback":false}},"handoff_path":"docs/NEXT.md","resume_max_wait":"6h","commit_on_wind_down":false,"messages_dir":"","updated_at":1}' \
    >"$CLAUDE_PLUGIN_DATA/config.json"
  run_status
  [[ $output == *"alerts are disabled"* ]]
  [[ $output == *"5-hour: 60% / 80%"* ]]
  [[ $output == *"weekly: 85% / 95% (invalid setting, using defaults)"* ]]
  [[ $output == *"handoff file: docs/NEXT.md"* ]]
}

@test "reports user disableAllHooks" {
  echo '{"disableAllHooks":true}' >"$HOME/.claude/settings.json"
  run_status
  [[ $output == *"disableAllHooks is true in $HOME/.claude/settings.json"* ]]
}

@test "reports managed blockers" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR"
  echo '{"allowManagedHooksOnly":true}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  run_status
  [[ $output == *"allowManagedHooksOnly is true"* ]]
}

@test "lists this session's alerts, ignoring an unsubstituted id" {
  mkdir -p "$CLAUDE_PLUGIN_DATA/sent/s1/main" "$CLAUDE_PLUGIN_DATA/sent/s1/agent-2"
  touch "$CLAUDE_PLUGIN_DATA/sent/s1/main/five_hour-$RESET-warn" "$CLAUDE_PLUGIN_DATA/sent/s1/agent-2/five_hour-$RESET-wind_down"
  run_status s1
  [[ $output == *"main: 5-hour warn"* ]]
  [[ $output == *"agent-2: 5-hour wind-down"* ]]
  run_status '${CLAUDE_SESSION_ID}'
  [[ $output != *"This session"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/status.bats`
Expected: FAIL — output is the usage line.

- [ ] **Step 3: Implement**

Add to `scripts/setup.sh` above the `case`:
```bash
tier_word() {
  case $1 in wind_down) echo "wind-down" ;; *) echo "$1" ;; esac
}

cmd_status() {
  local session=${1:-} cfg="$data/config.json" th blockers
  case $session in '' | '$'*) session="" ;; esac

  printf 'usage-guard %s\n\n' "$(ug_plugin_version "$ROOT")"

  echo "Status line relay"
  if [ "$(ug_statusline_command "$settings")" = "$relay_cmd" ]; then
    echo "  configured in $settings"
  else
    echo "  not configured in $settings (run /usage-guard:setup)"
  fi
  if [ -f "$data/last_render" ]; then
    echo "  last ran $(ug_fmt_duration $((now - $(cat "$data/last_render")))) ago"
  else
    echo "  has never run. If it's configured, managed or project settings may be overriding it."
  fi
  blockers=$(managed_blockers)
  if [ -n "$blockers" ]; then
    echo "  blocked by managed settings:"
    printf '%s\n' "$blockers" | sed 's/^/    - /'
  fi
  if [ -f "$settings" ] && [ "$(jq -r '.disableAllHooks == true' "$settings" 2>/dev/null)" = true ]; then
    echo "  disableAllHooks is true in $settings, which turns off the status line"
  fi

  if [ -f "$cfg" ]; then
    th=$(jq -c .thresholds "$cfg")
  else
    th=$(ug_thresholds_json)
  fi

  echo
  echo "Usage"
  if [ -f "$data/state.json" ]; then
    jq -r --argjson th "$th" '
      to_entries[]
      | .value.used_percentage as $p
      | [.key, ($p | tostring), (.value.resets_at | tostring), (.value.updated_at | tostring),
         (if $th[.key] == null then ""
          elif $p >= $th[.key].wind_down then "wind_down"
          elif $p >= $th[.key].warn then "warn" else "" end)]
      | @tsv' "$data/state.json" |
      while IFS="$(printf '\t')" read -r w p r u t; do
        if [ "$r" -le "$now" ]; then
          echo "  $(ug_window_label "$w"): window has reset (last reading $(ug_fmt_pct "$w" "$p"))"
          continue
        fi
        echo "  $(ug_window_label "$w"): $(ug_fmt_pct "$w" "$p")${t:+ ($(tier_word "$t"))}, resets in $(ug_fmt_duration $((r - now))) at $(ug_fmt_local_time "$r"); updated $(ug_fmt_duration $((now - u))) ago"
      done
  else
    echo "  no usage data received yet. Claude Code only provides it on claude.ai Pro/Max plans and behind a Claude apps gateway with spend limits."
  fi

  echo
  echo "Settings"
  if [ -f "$cfg" ]; then
    [ "$(jq -r .enabled "$cfg")" = false ] && echo "  alerts are disabled"
    echo "  handoff file: $(jq -r .handoff_path "$cfg")"
    echo "  resume scheduling limit: $(jq -r .resume_max_wait "$cfg")"
  else
    echo "  defaults (your settings appear here after the next session starts)"
  fi
  echo "  thresholds (warn / wind-down):"
  jq -r 'to_entries[] | [.key, (.value.warn | tostring), (.value.wind_down | tostring), (.value.fallback | tostring)] | @tsv' <<<"$th" |
    while IFS="$(printf '\t')" read -r w a b f; do
      echo "    $(ug_window_label "$w"): $a% / $b%$([ "$f" = true ] && echo " (invalid setting, using defaults)")"
    done

  if [ -n "$session" ] && [ -d "$data/sent/$(ug_safe_id "$session")" ]; then
    echo
    echo "This session has been told"
    local agent_dir marker name
    for agent_dir in "$data/sent/$(ug_safe_id "$session")"/*; do
      [ -d "$agent_dir" ] || continue
      for marker in "$agent_dir"/*; do
        [ -f "$marker" ] || continue
        name=$(basename "$marker")
        echo "  $(basename "$agent_dir"): $(ug_window_label "${name%%-*}") $(tier_word "${name##*-}")"
      done
    done
  fi
}
```

Change the `case` to:
```bash
case ${1:-} in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status "${2:-}" ;;
  *)
    echo "usage: setup.sh install|uninstall|status [session_id]"
    exit 1
    ;;
esac
```

- [ ] **Step 4: Create the commands**

`commands/setup.md`:
````markdown
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
````

`commands/status.md`:
````markdown
---
description: Show usage-guard's current usage readings, thresholds and alerts for this session
allowed-tools: Bash
---

Run:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" status "${CLAUDE_SESSION_ID}"
```

Show the user the output as-is, then add at most two sentences on anything that needs their attention.
````

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests && UG_BASH=/bin/bash bats tests`
Expected: all suites PASS.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck scripts/*.sh
git add scripts/setup.sh tests/status.bats commands
git commit -m "Add status report and setup/status slash commands"
```

---

### Task 8: Plugin manifest, hooks, marketplace and CI

**Files:**
- Create/replace: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`, `hooks/hooks.json`, `.github/workflows/ci.yml`
- Test: `tests/manifest.bats`

**Interfaces:**
- Consumes: `scripts/guard.sh`.
- Produces: userConfig keys matching `ug_option` calls exactly: `enabled`, `five_hour_warn`, `five_hour_wind_down`, `seven_day_warn`, `seven_day_wind_down`, `spend_limit_warn`, `spend_limit_wind_down`, `handoff_path`, `resume_max_wait`, `commit_on_wind_down`, `messages_dir`.

- [ ] **Step 1: Write the failing test**

`tests/manifest.bats`:
```bash
#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "userConfig declares every option the scripts read" {
  expected="commit_on_wind_down enabled five_hour_warn five_hour_wind_down handoff_path messages_dir resume_max_wait seven_day_warn seven_day_wind_down spend_limit_warn spend_limit_wind_down"
  actual=$(jq -r '.userConfig | keys | join(" ")' "$ROOT/.claude-plugin/plugin.json")
  [ "$actual" = "$expected" ]
}

@test "userConfig defaults match the scripts' defaults" {
  . "$ROOT/scripts/lib.sh"
  for w in $UG_WINDOWS; do
    [ "$(jq -r ".userConfig.${w}_warn.default" "$ROOT/.claude-plugin/plugin.json")" = "$(ug_default_threshold "$w" warn)" ]
    [ "$(jq -r ".userConfig.${w}_wind_down.default" "$ROOT/.claude-plugin/plugin.json")" = "$(ug_default_threshold "$w" wind_down)" ]
  done
}

@test "hooks register guard.sh for the four events" {
  [ "$(jq -r '.hooks | keys | sort | join(" ")' "$ROOT/hooks/hooks.json")" = "PostToolUse SessionStart SubagentStart UserPromptSubmit" ]
  [ "$(jq -r '[.hooks[][].hooks[].command] | unique | .[]' "$ROOT/hooks/hooks.json")" = 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh"' ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/manifest.bats`
Expected: FAIL (userConfig missing, `hooks/hooks.json` missing).

- [ ] **Step 3: Write the manifest**

`.claude-plugin/plugin.json`:
```json
{
  "name": "usage-guard",
  "displayName": "Usage Guard",
  "version": "0.1.0",
  "description": "Tells Claude when your plan's usage limits are getting close, so it conserves usage and then winds down with a handoff before you hit them.",
  "author": { "name": "Alex Moras", "email": "alex@codesix.dev" },
  "license": "MIT",
  "keywords": ["usage", "rate-limits", "status-line", "handoff"],
  "userConfig": {
    "enabled": {
      "type": "boolean",
      "title": "Enable alerts",
      "description": "Turn usage alerts on or off without uninstalling.",
      "default": true
    },
    "five_hour_warn": {
      "type": "number",
      "title": "5-hour: warn at %",
      "description": "Claude starts conserving usage at this share of the 5-hour limit.",
      "default": 75, "min": 1, "max": 100
    },
    "five_hour_wind_down": {
      "type": "number",
      "title": "5-hour: wind down at %",
      "description": "Claude wraps up and writes a handoff at this share of the 5-hour limit.",
      "default": 90, "min": 1, "max": 100
    },
    "seven_day_warn": {
      "type": "number",
      "title": "Weekly: warn at %",
      "description": "Claude starts conserving usage at this share of the weekly limit.",
      "default": 85, "min": 1, "max": 100
    },
    "seven_day_wind_down": {
      "type": "number",
      "title": "Weekly: wind down at %",
      "description": "Claude wraps up and writes a handoff at this share of the weekly limit.",
      "default": 95, "min": 1, "max": 100
    },
    "spend_limit_warn": {
      "type": "number",
      "title": "Spend limit: warn at %",
      "description": "For Claude apps gateway users: conserve at this share of your spend limit.",
      "default": 75, "min": 1, "max": 100
    },
    "spend_limit_wind_down": {
      "type": "number",
      "title": "Spend limit: wind down at %",
      "description": "For Claude apps gateway users: wrap up at this share of your spend limit.",
      "default": 95, "min": 1, "max": 100
    },
    "handoff_path": {
      "type": "string",
      "title": "Handoff file",
      "description": "Where Claude writes its handoff when winding down, relative to the project root.",
      "default": "HANDOFF.md"
    },
    "resume_max_wait": {
      "type": "string",
      "title": "Longest wait to schedule a resume",
      "description": "Claude only schedules a resume prompt if usage resets within this time, e.g. 90m or 6h.",
      "default": "6h"
    },
    "commit_on_wind_down": {
      "type": "boolean",
      "title": "Commit when winding down",
      "description": "Also ask Claude to commit work in progress when winding down.",
      "default": false
    },
    "messages_dir": {
      "type": "directory",
      "title": "Custom messages folder",
      "description": "Optional folder with warn.md, wind-down.md or wind-down-subagent.md to replace the default messages."
    }
  }
}
```

`.claude-plugin/marketplace.json`:
```json
{
  "name": "usage-guard",
  "owner": { "name": "Alex Moras", "email": "alex@codesix.dev" },
  "plugins": [
    {
      "name": "usage-guard",
      "source": "./",
      "description": "Usage-limit alerts that Claude acts on: conserve, then wind down with a handoff."
    }
  ]
}
```

`hooks/hooks.json`:
```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh\"", "timeout": 10 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh\"", "timeout": 10 }] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh\"", "timeout": 10 }] }
    ],
    "SubagentStart": [
      { "hooks": [{ "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh\"", "timeout": 10 }] }
    ]
  }
}
```

- [ ] **Step 4: Add CI**

`.github/workflows/ci.yml`:
```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Install tools (Linux)
        if: runner.os == 'Linux'
        run: sudo apt-get update && sudo apt-get install -y bats jq shellcheck
      - name: Install tools (macOS)
        if: runner.os == 'macOS'
        run: brew install bats-core jq shellcheck
      - name: Lint
        run: shellcheck scripts/*.sh
      - name: Test
        run: bats tests
        env:
          UG_BASH: ${{ runner.os == 'macOS' && '/bin/bash' || 'bash' }}
```

- [ ] **Step 5: Run tests and validate the plugin**

Run: `bats tests && UG_BASH=/bin/bash bats tests`
Expected: all PASS.

Run: `claude plugin validate . --strict`
Expected: `Validation passed`. Fix anything it reports (for example if `min`/`max` on a number needs a newer Claude Code, keep them and note the version in the README).

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin hooks .github tests/manifest.bats
git commit -m "Add plugin manifest, hooks, marketplace entry and CI"
```

---

### Task 9: README and end-to-end smoke test

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above. No code.

- [ ] **Step 1: Write the README**

`README.md` must contain these sections, in this order, with this content:

1. **Title and one-paragraph summary:** "usage-guard tells Claude when your plan's usage limits are getting close. At the warn threshold Claude starts conserving usage; at the wind-down threshold it finishes its current step, writes a handoff, stops subagents and, if usage resets soon, schedules itself to continue."
2. **Does it work for me?** The supported / not supported table from spec §1 (Pro/Max: 5-hour + weekly; gateway spend limits with Claude Code ≥ v2.1.251; Team/Enterprise seats without a gateway, API key, Bedrock, Vertex, Foundry: no usage data, plugin stays quiet and `/usage-guard:status` explains). Requires `jq`. macOS and Linux; Windows untested.
3. **Install:**
   ```
   /plugin marketplace add <owner>/usage-guard
   /plugin install usage-guard@usage-guard
   /usage-guard:setup
   ```
   Explain that plugins can't set the status line, so setup adds a small relay in front of your existing status line (which keeps rendering), and that `/usage-guard:setup uninstall` restores the previous setting exactly. Backups go to the plugin data folder.
4. **What Claude is told:** the three default messages verbatim from `messages/`, and that each session and each subagent hears about each threshold once per reset period.
5. **Configuration:** the userConfig table (key, default, meaning) from spec §6, set via `/config` or when enabling the plugin.
6. **Custom messages:** `messages_dir`, file names, and the placeholder list.
7. **For administrators:** (a) allowlist the marketplace if you use `strictKnownMarketplaces`; (b) force-enable `usage-guard@<marketplace>` in managed `enabledPlugins` — its hooks then run even under `allowManagedHooksOnly`; (c) set managed `statusLine` to the snippet `/usage-guard:setup` prints (`{"statusLine":{"type":"command","command":"\"$HOME/.claude/plugins/data/<id>/bin/relay.sh\""}}`) — the guard keeps that relay file current on every session start. Note that a managed `statusLine` replaces any personal status line.
8. **Privacy:** no network calls, no credentials; stores only percentages, reset times and marker files under `~/.claude/plugins/data/`.
9. **Migrating from hand-made hooks:** remove old usage hooks from `~/.claude/settings.json` and old state files to avoid duplicate messages.
10. **Troubleshooting:** `/usage-guard:status`; "has never run" means the status line is overridden (managed, project or `disableAllHooks`); "no usage data" means the plan doesn't provide it or no API response yet.
11. **Development:** `brew install bats-core shellcheck jq`, `bats tests`, `UG_BASH=/bin/bash bats tests`, `shellcheck scripts/*.sh`, `claude --plugin-dir .`.
12. **License:** MIT.

- [ ] **Step 2: Smoke test in a real session**

```bash
cd "$(mktemp -d)"
claude --plugin-dir /path/to/usage-guard-plugin
```
In the session: run `/usage-guard:setup`; confirm the status line still renders. Then from another terminal write a fixture over the wind-down threshold:
```bash
D=~/.claude/plugins/data/<the usage-guard id>   # shown by /usage-guard:status
jq -n --argjson r $(( $(date +%s) + 3600 )) '{five_hour:{used_percentage:92,resets_at:$r,updated_at:0}}' > "$D/state.json"
```
Send any prompt. Expected: a `⚠️ usage-guard: 5-hour 92%…` notice, and Claude writes `HANDOFF.md` and explains the wind-down. Send another prompt: no repeat. Run `/usage-guard:status`: the alert is listed under "This session has been told". Finally run `/usage-guard:setup uninstall` and confirm the original status line setting is back.

Record the result (pass/fail and anything surprising) in the task report.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Add README"
```

---

### Task 10: Retire the hand-made hooks on this machine (needs the user's go-ahead)

This changes `~/.claude/settings.json` outside the repo. **Ask the user before doing it**, show them the exact diff, and back up the file first.

- [ ] **Step 1: Back up and show what will change**

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak-usage-guard
jq '.hooks.PostToolUse, .hooks.UserPromptSubmit' ~/.claude/settings.json
```
Expected: entries whose command is `~/.claude/hooks/usage-guard.sh`.

- [ ] **Step 2: After approval, remove those entries**

```bash
jq '(.hooks.PostToolUse, .hooks.UserPromptSubmit) |= map(select(all(.hooks[]; .command != "~/.claude/hooks/usage-guard.sh")))
    | .hooks |= with_entries(select(.value | length > 0))' ~/.claude/settings.json > ~/.claude/settings.json.new \
  && mv ~/.claude/settings.json.new ~/.claude/settings.json
rm -f ~/.claude/rl-state.json ~/.claude/rl-warned-*
```
Leave `~/.claude/hooks/*.sh` and `~/.claude/heavy-usage/` in place unless the user asks to delete them.

- [ ] **Step 3: Verify**

Run: `jq '.hooks' ~/.claude/settings.json`
Expected: no `usage-guard.sh` references; other hooks untouched.
