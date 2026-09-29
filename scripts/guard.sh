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

# SessionStart upkeep. Prints an optional one-line notice for the user.
session_start() {
  housekeeping
  snapshot_config
  onboarding
}

housekeeping() {
  if [ -d "$data/sent" ]; then
    find "$data/sent" -type f -mtime +8 -delete
    find "$data/sent" -mindepth 1 -type d -empty -delete
  fi
  if [ ! -f "$data/bin/relay.sh" ] || [ ! -f "$data/bin/lib.sh" ] ||
    [ "$(cat "$data/bin/VERSION" 2>/dev/null)" != "$(ug_plugin_version "$ROOT")" ]; then
    ug_install_relay_files "$ROOT" "$data"
  fi
}

# Hooks see plugin options but the Bash tool doesn't, so /usage-guard:status
# reads this snapshot.
snapshot_config() {
  jq -nc \
    --argjson enabled "$(ug_bool_option enabled true)" \
    --argjson thresholds "$(ug_thresholds_json)" \
    --arg handoff_path "$(ug_option handoff_path HANDOFF.md)" \
    --arg resume_max_wait "$(ug_resume_max_wait)" \
    --argjson commit "$(ug_bool_option commit_on_wind_down false)" \
    --arg messages_dir "$(ug_option messages_dir "")" \
    --argjson now "$now" \
    '{enabled: $enabled, thresholds: $thresholds, handoff_path: $handoff_path,
      resume_max_wait: $resume_max_wait, commit_on_wind_down: $commit,
      messages_dir: $messages_dir, updated_at: $now}' |
    ug_write_atomic "$data/config.json"
}

onboarding() {
  local file="$data/onboarding.json" state day
  state=$(jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null)
  [ -n "$state" ] || state='{}'
  day=$((now / 86400))
  if [ -f "$data/last_render" ]; then
    [ -f "$data/state.json" ] && return 0
    state=$(jq -c '.sessions_without_data = ((.sessions_without_data // 0) + 1)' <<<"$state")
    if [ "$(jq -r '.sessions_without_data >= 3 and (.no_data_shown | not)' <<<"$state")" = true ]; then
      state=$(jq -c '.no_data_shown = true' <<<"$state")
      echo "usage-guard hasn't received any usage data. Your plan may not provide it; run /usage-guard:status for details."
    fi
  elif [ "$(jq -r --argjson d "$day" '.last_setup_notice_day == $d' <<<"$state")" != true ]; then
    state=$(jq -c --argjson d "$day" '.last_setup_notice_day = $d' <<<"$state")
    if ug_is_relay_command "$(ug_statusline_command "$(ug_config_dir)/settings.json")" "$data"; then
      echo "usage-guard's status line relay is configured but hasn't run. Managed or project settings may override it; run /usage-guard:status for details."
    else
      echo "usage-guard: run /usage-guard:setup to enable usage alerts."
    fi
  fi
  printf '%s' "$state" | ug_write_atomic "$file"
}

nojq_notice() {
  local marker
  marker="$data/.nojq-$((now / 86400))"
  [ -e "$marker" ] && return 0
  mkdir -p "$data" && touch "$marker"
  printf '%s\n' '{"systemMessage":"usage-guard needs jq to work. Install it (macOS: brew install jq; Debian/Ubuntu: sudo apt install jq) and restart Claude Code."}'
}

# Marker directory for this session and agent.
marker_dir() {
  local session agent
  session=$(jq -r '.session_id // ""' <<<"$input")
  agent=$(jq -r '.agent_id // "main"' <<<"$input")
  printf '%s/sent/%s/%s' "$data" "$(ug_safe_id "$session")" "$(ug_safe_id "$agent")"
}

# Prints "window<TAB>tier<TAB>pct<TAB>resets_at" for each crossing this
# session/agent hasn't been told about yet. Each marker is claimed atomically
# (noclobber create), so when several hooks run at once only the one that
# creates the marker reports the crossing.
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
      mkdir -p "$dir" || continue
      (set -C && : >"$dir/$window-$resets-$tier") 2>/dev/null || continue
      printf '%s\t%s\t%s\t%s\n' "$window" "$tier" "$pct" "$resets"
    done
}

# Builds the hook output for new crossings (wind_down first, then highest %).
emit() {
  local event=$1 notice=$2 crossings=$3
  if [ -z "$crossings" ]; then
    [ -n "$notice" ] && jq -nc --arg m "$notice" '{systemMessage: $m}'
    return 0
  fi

  local sorted count lines="" summary="" window tier pct resets label shown left
  sorted=$(printf '%s\n' "$crossings" | sort -t "$TAB" -k2,2r -k3,3nr)
  count=$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')
  while IFS="$TAB" read -r window tier pct resets; do
    label=$(ug_window_label "$window")
    shown=$(ug_fmt_pct "$window" "$pct")
    left=$(ug_fmt_duration $((resets - now)))
    lines="$lines- $label: $shown (resets in $left, at $(ug_fmt_local_time "$resets"))
"
    summary="${summary:+$summary; }$label $shown, resets in $left"
  done <<<"$sorted"

  local p_window p_tier p_pct p_resets p_label template commit_step="" vars body context sm
  IFS="$TAB" read -r p_window p_tier p_pct p_resets <<<"$(printf '%s\n' "$sorted" | head -n 1)"
  p_label=$(ug_window_label "$p_window")
  if [ "$p_window" = spend_limit ] && [ "${p_pct%%.*}" -ge 100 ]; then
    p_label="$p_label (exceeded)"
  fi
  if [ "$p_tier" = warn ]; then
    template="warn.md"
  elif [ -n "$(jq -r '.agent_id // empty' <<<"$input")" ]; then
    template="wind-down-subagent.md"
  else
    template="wind-down.md"
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
  if ! ug_have_jq; then
    if printf '%s' "$input" | grep -q '"hook_event_name" *: *"SessionStart"'; then
      nojq_notice
    fi
    return 0
  fi
  event=$(jq -r '.hook_event_name // empty' <<<"$input") || return 0
  if [ "$event" = SessionStart ]; then
    notice=$(session_start)
  fi
  if [ "$(ug_bool_option enabled true)" != true ]; then
    [ -n "$notice" ] && jq -nc --arg m "$notice" '{systemMessage: $m}'
    return 0
  fi
  dir=$(marker_dir)
  emit "$event" "$notice" "$(new_crossings "$dir")"
}

main 2>/dev/null
exit 0
