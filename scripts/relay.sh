#!/usr/bin/env bash
# Status line relay for usage-guard. Records rate_limits for guard.sh, then
# renders the user's original status line. Must never fail visibly.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Installed as DATA/bin/relay.sh, where CLAUDE_PLUGIN_DATA isn't set.
data=$(dirname "$SCRIPT_DIR")
input=$(cat)
now=$(ug_now)

record_state() {
  local rl current
  printf '%s' "$now" >"$data/last_render"
  rl=$(jq -c '.rate_limits // {}
    | with_entries(select((.key == "five_hour" or .key == "seven_day" or .key == "spend_limit")
        and (.value.used_percentage != null)))' <<<"$input") || return 0
  [ -n "$rl" ] && [ "$rl" != '{}' ] || return 0
  current=$(jq -c 'if type == "object" then . else {} end' "$data/state.json" 2>/dev/null)
  [ -n "$current" ] || current='{}'
  jq -nc --argjson cur "$current" --argjson rl "$rl" --argjson now "$now" \
    '$cur + ($rl | map_values({used_percentage, resets_at, updated_at: $now}))' |
    ug_write_atomic "$data/state.json"
}

default_line() {
  jq -r '[.model.display_name // empty]
    + (.rate_limits // {} | [
        (.five_hour.used_percentage | select(. != null) | "5h: \(floor)%"),
        (.seven_day.used_percentage | select(. != null) | "7d: \(floor)%"),
        (.spend_limit.used_percentage | select(. != null) | "spend: \(floor)%")
      ])
    | join(" | ")' <<<"$input"
}

render() {
  local inner
  inner=$(jq -r 'if type == "string" then .
    elif type == "object" and .type == "command" then (.command // "")
    else "" end' "$data/inner-statusline.json" 2>/dev/null)
  # USAGE_GUARD_IN_RELAY stops a status line that points back at the relay from recursing.
  if [ -n "$inner" ] && [ -z "${USAGE_GUARD_IN_RELAY:-}" ]; then
    printf '%s' "$input" | USAGE_GUARD_IN_RELAY=1 bash -c "$inner"
  else
    default_line
  fi
}

record_state 2>/dev/null
render 2>/dev/null
exit 0
