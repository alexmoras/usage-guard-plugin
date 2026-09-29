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
