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

# sl_input [rate_limits_json] -> status line input JSON
sl_input() {
  jq -nc --argjson rl "${1:-null}" '{model: {display_name: "Opus"}} + (if $rl == null then {} else {rate_limits: $rl} end)'
}
