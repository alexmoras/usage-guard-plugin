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
