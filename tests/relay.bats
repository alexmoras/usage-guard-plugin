#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  mkdir -p "$USAGE_GUARD_HOME/bin"
  cp "$ROOT/scripts/relay.sh" "$ROOT/scripts/lib.sh" "$USAGE_GUARD_HOME/bin/"
}
teardown() { teardown_env; }

run_relay() {
  run "$UG_BASH" "$USAGE_GUARD_HOME/bin/relay.sh" <<<"$1"
}

@test "records windows with updated_at and writes heartbeat" {
  rl=$(rl_entry five_hour 42.5)
  run_relay "$(sl_input "$rl")"
  [ "$status" -eq 0 ]
  [ "$(jq -c .five_hour "$USAGE_GUARD_HOME/state.json")" = "{\"used_percentage\":42.5,\"resets_at\":$RESET,\"updated_at\":$NOW}" ]
  [ "$(cat "$USAGE_GUARD_HOME/last_render")" = "$NOW" ]
}

@test "keeps windows that are absent from this render" {
  write_state "$(state_entry seven_day 50 "$WEEK_RESET")"
  rl=$(rl_entry five_hour 10)
  run_relay "$(sl_input "$rl")"
  [ "$(jq -r '.seven_day.used_percentage' "$USAGE_GUARD_HOME/state.json")" = 50 ]
  [ "$(jq -r '.five_hour.used_percentage' "$USAGE_GUARD_HOME/state.json")" = 10 ]
}

@test "records spend_limit and ignores unknown windows" {
  rl=$(jq -sc add <<<"$(rl_entry spend_limit 104) $(echo '{"other":{"used_percentage":1,"resets_at":1}}')")
  run_relay "$(sl_input "$rl")"
  [ "$(jq -r '.spend_limit.used_percentage' "$USAGE_GUARD_HOME/state.json")" = 104 ]
  [ "$(jq -r 'has("other")' "$USAGE_GUARD_HOME/state.json")" = false ]
}

@test "no rate_limits leaves state untouched" {
  run_relay "$(sl_input)"
  [ "$status" -eq 0 ]
  [ ! -f "$USAGE_GUARD_HOME/state.json" ]
  [ -f "$USAGE_GUARD_HOME/last_render" ]
}

@test "replaces a corrupt state file" {
  write_state 'not json'
  rl=$(rl_entry five_hour 5)
  run_relay "$(sl_input "$rl")"
  [ "$(jq -r '.five_hour.used_percentage' "$USAGE_GUARD_HOME/state.json")" = 5 ]
}

@test "default line without an inner status line" {
  rl=$(jq -sc add <<<"$(rl_entry five_hour 42.5) $(rl_entry seven_day 9 "$WEEK_RESET")")
  run_relay "$(sl_input "$rl")"
  [ "$output" = "Opus | 5h: 42% | 7d: 9%" ]
}

@test "runs the inner object command with the same stdin" {
  jq -nc --arg c "cat > '$TEST_TMP/inner-stdin'; echo INNER" '{type: "command", command: $c, padding: 0}' \
    >"$USAGE_GUARD_HOME/inner-statusline.json"
  input=$(sl_input)
  run_relay "$input"
  [ "$output" = "INNER" ]
  [ "$(cat "$TEST_TMP/inner-stdin")" = "$input" ]
}

@test "runs a string-form inner command" {
  echo '"echo STRING-FORM"' >"$USAGE_GUARD_HOME/inner-statusline.json"
  run_relay "$(sl_input)"
  [ "$output" = "STRING-FORM" ]
}

@test "survives garbage input" {
  run_relay "}{ not json"
  [ "$status" -eq 0 ]
}

@test "an inner status line that points back at the relay does not recurse" {
  jq -n --arg c "\"$USAGE_GUARD_HOME/bin/relay.sh\"" '{type: "command", command: $c}' >"$USAGE_GUARD_HOME/inner-statusline.json"
  run_relay '{"model":{"display_name":"Opus"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "Opus" ]
}
