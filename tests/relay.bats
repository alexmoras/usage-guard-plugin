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

@test "records windows with updated_at and writes heartbeat" {
  rl=$(rl_entry five_hour 42.5)
  run_relay "$(sl_input "$rl")"
  [ "$status" -eq 0 ]
  [ "$(jq -c .five_hour "$CLAUDE_PLUGIN_DATA/state.json")" = "{\"used_percentage\":42.5,\"resets_at\":$RESET,\"updated_at\":$NOW}" ]
  [ "$(cat "$CLAUDE_PLUGIN_DATA/last_render")" = "$NOW" ]
}

@test "keeps windows that are absent from this render" {
  write_state "$(state_entry seven_day 50 "$WEEK_RESET")"
  rl=$(rl_entry five_hour 10)
  run_relay "$(sl_input "$rl")"
  [ "$(jq -r '.seven_day.used_percentage' "$CLAUDE_PLUGIN_DATA/state.json")" = 50 ]
  [ "$(jq -r '.five_hour.used_percentage' "$CLAUDE_PLUGIN_DATA/state.json")" = 10 ]
}

@test "records spend_limit and ignores unknown windows" {
  rl=$(jq -sc add <<<"$(rl_entry spend_limit 104) $(echo '{"other":{"used_percentage":1,"resets_at":1}}')")
  run_relay "$(sl_input "$rl")"
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
  rl=$(rl_entry five_hour 5)
  run_relay "$(sl_input "$rl")"
  [ "$(jq -r '.five_hour.used_percentage' "$CLAUDE_PLUGIN_DATA/state.json")" = 5 ]
}

@test "default line without an inner status line" {
  rl=$(jq -sc add <<<"$(rl_entry five_hour 42.5) $(rl_entry seven_day 9 "$WEEK_RESET")")
  run_relay "$(sl_input "$rl")"
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
