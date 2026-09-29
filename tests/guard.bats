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
