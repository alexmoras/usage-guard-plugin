#!/usr/bin/env bash
# Hook entry point for usage-guard: turns recorded usage into one-time
# instructions for Claude. Always exits 0 so it can never block a session.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

input=$(cat)
data=$(ug_data_dir)
now=$(ug_now)
TAB=$(printf '\t')

# Filled in by Task 5; prints an optional user notice.
session_start() {
  :
}

# Marker directory for this session and agent.
marker_dir() {
  local session agent
  session=$(jq -r '.session_id // ""' <<<"$input")
  agent=$(jq -r '.agent_id // "main"' <<<"$input")
  printf '%s/sent/%s/%s' "$data" "$(ug_safe_id "$session")" "$(ug_safe_id "$agent")"
}

# Prints "window<TAB>tier<TAB>pct<TAB>resets_at" for each crossing this
# session/agent hasn't been told about yet.
new_crossings() {
  local dir=$1 th
  [ -f "$data/state.json" ] || return 0
  th=$(ug_thresholds_json)
  jq -r --argjson th "$th" --argjson now "$now" '
    if type == "object" then . else {} end
    | to_entries[]
    | select($th[.key] != null and ((.value.resets_at // 0) > $now))
    | .value.used_percentage as $p
    | (if $p >= $th[.key].wind_down then "wind_down"
       elif $p >= $th[.key].warn then "warn"
       else empty end) as $tier
    | [.key, $tier, ($p | tostring), (.value.resets_at | tostring)] | @tsv' "$data/state.json" |
    while IFS="$TAB" read -r window tier pct resets; do
      [ -e "$dir/$window-$resets-$tier" ] && continue
      [ "$tier" = warn ] && [ -e "$dir/$window-$resets-wind_down" ] && continue
      printf '%s\t%s\t%s\t%s\n' "$window" "$tier" "$pct" "$resets"
    done
}

# Builds the hook output for new crossings (wind_down first, then highest %).
emit() {
  local event=$1 notice=$2 crossings=$3 dir=$4
  if [ -z "$crossings" ]; then
    [ -n "$notice" ] && jq -nc --arg m "$notice" '{systemMessage: $m}'
    return 0
  fi

  local sorted count lines="" summary="" window tier pct resets label shown left
  sorted=$(printf '%s\n' "$crossings" | sort -t "$TAB" -k2,2r -k3,3nr)
  count=$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')
  mkdir -p "$dir"
  while IFS="$TAB" read -r window tier pct resets; do
    label=$(ug_window_label "$window")
    shown=$(ug_fmt_pct "$window" "$pct")
    left=$(ug_fmt_duration $((resets - now)))
    lines="$lines- $label: $shown (resets in $left, at $(ug_fmt_local_time "$resets"))
"
    summary="${summary:+$summary; }$label $shown, resets in $left"
    touch "$dir/$window-$resets-$tier"
  done <<<"$sorted"

  local p_window p_tier p_pct p_resets p_label template commit_step="" vars body context sm
  IFS="$TAB" read -r p_window p_tier p_pct p_resets <<<"$(printf '%s\n' "$sorted" | head -n 1)"
  p_label=$(ug_window_label "$p_window")
  if [ "$p_window" = spend_limit ] && [ "${p_pct%%.*}" -ge 100 ]; then
    p_label="$p_label (exceeded)"
  fi
  if [ "$p_tier" = warn ]; then
    template=warn.md
  elif [ -n "$(jq -r '.agent_id // empty' <<<"$input")" ]; then
    template=wind-down-subagent.md
  else
    template=wind-down.md
  fi
  if [ "$(ug_bool_option commit_on_wind_down false)" = true ]; then
    commit_step=" Then commit work in progress if this is a git repository."
  fi
  vars=$(jq -nc \
    --arg window "$p_label" \
    --arg pct "${p_pct%%.*}" \
    --arg resets_in "$(ug_fmt_duration $((p_resets - now)))" \
    --arg resets_at "$(ug_fmt_local_time "$p_resets")" \
    --arg handoff_path "$(ug_option handoff_path HANDOFF.md)" \
    --arg resume_max_wait "$(ug_resume_max_wait)" \
    --arg commit_step "$commit_step" \
    '$ARGS.named')
  body=$(ug_render_template "$(ug_template_path "$ROOT" "$template")" "$vars")

  context=$body
  if [ "$count" -gt 1 ]; then
    context="Usage thresholds crossed:
$lines
$body"
  fi
  sm="⚠️ usage-guard: $summary"
  [ -n "$notice" ] && sm="$notice
$sm"
  jq -nc --arg e "$event" --arg c "$context" --arg s "$sm" \
    '{systemMessage: $s, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

main() {
  local event notice="" dir
  ug_have_jq || return 0
  event=$(jq -r '.hook_event_name // empty' <<<"$input") || return 0
  if [ "$event" = SessionStart ]; then
    notice=$(session_start)
  fi
  if [ "$(ug_bool_option enabled true)" != true ]; then
    [ -n "$notice" ] && jq -nc --arg m "$notice" '{systemMessage: $m}'
    return 0
  fi
  dir=$(marker_dir)
  emit "$event" "$notice" "$(new_crossings "$dir")" "$dir"
}

main 2>/dev/null
exit 0
