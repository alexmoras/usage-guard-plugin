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

@test "the marketplace installs from the release branch only" {
  # Installs must come from the last published release, never from main.
  # Only the release workflow moves the release branch; see RELEASING in the README.
  entry=$(jq -c '.plugins[] | select(.name == "usage-guard")' "$ROOT/.claude-plugin/marketplace.json")
  [ "$(jq -c .source <<<"$entry")" = '{"source":"github","repo":"alexmoras/usage-guard-plugin","ref":"release"}' ]
  # A version here would override the released plugin.json's version.
  [ "$(jq -r 'has("version")' <<<"$entry")" = false ]
}
