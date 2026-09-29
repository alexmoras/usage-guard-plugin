#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  FILE="$USAGE_GUARD_HOME/thresholds.json"
  cd "$TEST_TMP"
}
teardown() { teardown_env; }

run_thresholds() { run "$UG_BASH" "$ROOT/scripts/setup.sh" thresholds "$@"; }
run_guard() { run "$UG_BASH" "$ROOT/scripts/guard.sh" <<<"$1"; }
ctx() { jq -r '.hookSpecificOutput.additionalContext' <<<"$output"; }

@test "setting a window writes the override and says when it applies" {
  run_thresholds 5h 80 95
  [ "$status" -eq 0 ]
  [ "$(jq -c .five_hour "$FILE")" = '{"warn":80,"wind_down":95}' ]
  [[ $output == *"5-hour thresholds set: warn at 80%, wind down at 95%."* ]]
  [[ $output == *"next prompt or tool call"* ]]
}

@test "window aliases map to the right window and keep other overrides" {
  run_thresholds weekly 90 97
  [ "$status" -eq 0 ]
  run_thresholds spend 60 85.5
  [ "$status" -eq 0 ]
  run_thresholds five_hour 70 80
  [ "$status" -eq 0 ]
  run_thresholds 7d 91 98
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$FILE")" = '{"seven_day":{"warn":91,"wind_down":98},"spend_limit":{"warn":60,"wind_down":85.5},"five_hour":{"warn":70,"wind_down":80}}' ]
}

@test "invalid input changes nothing" {
  run_thresholds 5h 80 95
  before=$(cat "$FILE")
  for args in "5h abc 95" "5h 95 80" "5h 90 90" "5h 0 50" "5h 50 101" "5h 080 95" "hourly 50 60" "5h 50" "5h 50 60 70"; do
    # shellcheck disable=SC2086
    run_thresholds $args
    [ "$status" -eq 1 ]
    [[ $output == *"usage: /usage-guard:setup thresholds"* ]]
    [ "$(cat "$FILE")" = "$before" ]
  done
}

@test "no arguments shows each window and marks overrides" {
  run_thresholds 5h 80 95
  run_thresholds
  [ "$status" -eq 0 ]
  [[ $output == *"5-hour: 80% / 95% (set with /usage-guard:setup thresholds)"* ]]
  [[ $output == *"weekly: 85% / 95%"* ]]
  [[ $output != *"weekly: 85% / 95% (set with"* ]]
}

@test "reset for one window keeps the others" {
  run_thresholds 5h 80 95
  run_thresholds weekly 90 97
  run_thresholds reset 5h
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$FILE")" = '{"seven_day":{"warn":90,"wind_down":97}}' ]
  [[ $output == *"5-hour: 75% / 90%"* ]]
}

@test "reset for the last override removes the file" {
  run_thresholds 5h 80 95
  run_thresholds reset five_hour
  [ "$status" -eq 0 ]
  [ ! -e "$FILE" ]
}

@test "reset with no window removes every override" {
  run_thresholds 5h 80 95
  run_thresholds weekly 90 97
  run_thresholds reset
  [ "$status" -eq 0 ]
  [ ! -e "$FILE" ]
  [[ $output == *"All thresholds reset"* ]]
}

@test "reset with an unknown window fails without changes" {
  run_thresholds 5h 80 95
  run_thresholds reset hourly
  [ "$status" -eq 1 ]
  [ -f "$FILE" ]
}

@test "the guard uses a new threshold on the very next call" {
  write_state "$(state_entry five_hour 61)"
  run_guard "$(hook_input UserPromptSubmit s1)"
  [ -z "$output" ]
  run_thresholds 5h 50 60
  run_guard "$(hook_input UserPromptSubmit s1)"
  [[ $(ctx) == *"Wind down now"* ]]
}

@test "an override beats the /config value" {
  export CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WARN=60 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WIND_DOWN=70
  write_state "$(state_entry five_hour 72)"
  run_thresholds 5h 80 95
  run_guard "$(hook_input UserPromptSubmit s1)"
  [ -z "$output" ]
}

@test "the session snapshot keeps /config values so a reset shows them" {
  export CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WARN=60 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_WIND_DOWN=70
  run_thresholds 5h 80 95
  run_guard "$(hook_input SessionStart s1)"
  [ "$(jq -c '.thresholds.five_hour | {warn, wind_down}' "$USAGE_GUARD_HOME/config.json")" = '{"warn":60,"wind_down":70}' ]
  run_thresholds reset 5h
  [[ $output == *"5-hour: 60% / 70%"* ]]
}

@test "status shows overrides and uses them for the tier" {
  run_thresholds 5h 50 60
  write_state "$(state_entry five_hour 61)"
  run "$UG_BASH" "$ROOT/scripts/setup.sh" status
  [[ $output == *"5-hour: 61% (wind-down)"* ]]
  [[ $output == *"5-hour: 50% / 60% (set with /usage-guard:setup thresholds)"* ]]
}

@test "a corrupt overrides file is ignored" {
  mkdir -p "$USAGE_GUARD_HOME"
  echo '{nope' >"$FILE"
  write_state "$(state_entry five_hour 80)"
  run_guard "$(hook_input UserPromptSubmit s1)"
  [[ $(ctx) == *"Conserve usage"* ]]
  run_thresholds 5h 50 60
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$FILE")" = '{"five_hour":{"warn":50,"wind_down":60}}' ]
}

@test "uninstall keeps threshold overrides" {
  echo '{}' >"$HOME/.claude/settings.json"
  "$UG_BASH" "$ROOT/scripts/setup.sh" install >/dev/null
  run_thresholds 5h 80 95
  "$UG_BASH" "$ROOT/scripts/setup.sh" uninstall >/dev/null
  [ "$(jq -c .five_hour "$FILE")" = '{"warn":80,"wind_down":95}' ]
}
