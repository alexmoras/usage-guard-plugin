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
