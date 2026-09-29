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
  [ -f "$USAGE_GUARD_HOME/sent/s1/main/five_hour-$RESET-warn" ]
  run_guard "$(hook_input PostToolUse s1)"
  [ -z "$output" ]
}

@test "concurrent hooks for the same session and agent deliver exactly one alert" {
  write_state "$(state_entry five_hour 92)"
  input=$(hook_input PostToolUse sess1)
  for i in 1 2 3 4 5 6; do
    "$UG_BASH" "$ROOT/scripts/guard.sh" <<<"$input" >"$TEST_TMP/out-$i" 2>&1 &
  done
  wait
  alerts=0
  for i in 1 2 3 4 5 6; do
    [ -s "$TEST_TMP/out-$i" ] && alerts=$((alerts + 1))
  done
  [ "$alerts" -eq 1 ]
  [ -f "$USAGE_GUARD_HOME/sent/sess1/main/five_hour-$RESET-wind_down" ]
}

@test "checking for alerts without crossings creates no marker folders" {
  write_state "$(state_entry five_hour 10)"
  run_guard "$(hook_input PostToolUse sess1)"
  [ ! -e "$USAGE_GUARD_HOME/sent" ]
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
  [ -f "$USAGE_GUARD_HOME/sent/sess1/main/five_hour-$RESET-warn" ]
  [ -f "$USAGE_GUARD_HOME/sent/sess1/main/seven_day-$WEEK_RESET-wind_down" ]
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
  [ -f "$USAGE_GUARD_HOME/sent/sess1/agent-7/five_hour-$RESET-wind_down" ]
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
  [ -f "$USAGE_GUARD_HOME/sent/______evil/___x/five_hour-$RESET-warn" ]
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

fake_plugin_root() {
  # Copy the plugin so tests can change its version without touching the repo.
  cp -R "$ROOT" "$TEST_TMP/plugin"
  jq '.version = "9.9.9"' "$ROOT/.claude-plugin/plugin.json" >"$TEST_TMP/plugin/.claude-plugin/plugin.json"
}

@test "SessionStart installs relay files and refreshes them on version change" {
  run_guard "$(hook_input SessionStart)"
  [ -x "$USAGE_GUARD_HOME/bin/relay.sh" ]
  [ -f "$USAGE_GUARD_HOME/bin/lib.sh" ]
  [ "$(cat "$USAGE_GUARD_HOME/bin/VERSION")" = "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" ]
  fake_plugin_root
  run "$UG_BASH" "$TEST_TMP/plugin/scripts/guard.sh" <<<"$(hook_input SessionStart)"
  [ "$(cat "$USAGE_GUARD_HOME/bin/VERSION")" = "9.9.9" ]
}

@test "SessionStart restores a missing bin/lib.sh" {
  run_guard "$(hook_input SessionStart)"
  rm "$USAGE_GUARD_HOME/bin/lib.sh"
  run_guard "$(hook_input SessionStart s2)"
  cmp "$ROOT/scripts/lib.sh" "$USAGE_GUARD_HOME/bin/lib.sh"
}

@test "SessionStart prunes markers older than 8 days" {
  mkdir -p "$USAGE_GUARD_HOME/sent/old/main" "$USAGE_GUARD_HOME/sent/new/main"
  touch -t 202001010000 "$USAGE_GUARD_HOME/sent/old/main/five_hour-1-warn"
  touch "$USAGE_GUARD_HOME/sent/new/main/five_hour-1-warn"
  run_guard "$(hook_input SessionStart)"
  [ ! -e "$USAGE_GUARD_HOME/sent/old" ]
  [ -f "$USAGE_GUARD_HOME/sent/new/main/five_hour-1-warn" ]
}

@test "SessionStart writes a config snapshot" {
  export CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WARN=60 CLAUDE_PLUGIN_OPTION_ENABLED=false
  run_guard "$(hook_input SessionStart)"
  [ "$(jq -r .thresholds.five_hour.warn "$USAGE_GUARD_HOME/config.json")" = 60 ]
  [ "$(jq -r .enabled "$USAGE_GUARD_HOME/config.json")" = false ]
  [ "$(jq -r .handoff_path "$USAGE_GUARD_HOME/config.json")" = HANDOFF.md ]
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
  jq -n --arg c "\"$USAGE_GUARD_HOME/bin/relay.sh\"" '{statusLine: {type: "command", command: $c}}' \
    >"$HOME/.claude/settings.json"
  run_guard "$(hook_input SessionStart)"
  [[ $(sysmsg) == "usage-guard's status line relay is configured but hasn't run."* ]]
}

@test "onboarding: recognises other spellings of the relay command" {
  export USAGE_GUARD_HOME="$HOME/.claude/usage-guard"
  jq -n '{statusLine: {type: "command", command: "bash ~/.claude/usage-guard/bin/relay.sh"}}' \
    >"$HOME/.claude/settings.json"
  run_guard "$(hook_input SessionStart)"
  [[ $(sysmsg) == "usage-guard's status line relay is configured but hasn't run."* ]]
}

@test "onboarding: no-data notice after 3 sessions, shown once" {
  echo "$NOW" >"$USAGE_GUARD_HOME/last_render"
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
  echo "$NOW" >"$USAGE_GUARD_HOME/last_render"
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

@test "onboarding stays quiet after the relay was removed on purpose" {
  touch "$USAGE_GUARD_HOME/relay-removed"
  run_guard "$(hook_input SessionStart)"
  [ -z "$output" ]
}
