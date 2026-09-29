#!/usr/bin/env bash
# Installs, removes and reports on the usage-guard status line relay.
# The only usage-guard script that edits user settings.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

data=$(ug_data_dir)
settings="$(ug_config_dir)/settings.json"
relay_cmd=$(ug_relay_command "$data")
now=$(ug_now)

managed_dir() {
  if [ -n "${USAGE_GUARD_MANAGED_DIR:-}" ]; then
    printf '%s' "$USAGE_GUARD_MANAGED_DIR"
  elif [ "$(uname -s)" = Darwin ]; then
    printf '%s' "/Library/Application Support/ClaudeCode"
  else
    printf '%s' "/etc/claude-code"
  fi
}

managed_files() {
  local dir f
  dir=$(managed_dir)
  for f in "$dir/managed-settings.json" "$dir"/managed-settings.d/*.json; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# The first managed settings file whose statusLine runs usage-guard's relay.
managed_relay_file() {
  local f
  while IFS= read -r f; do
    if ug_is_relay_command "$(ug_statusline_command "$f")" "$data"; then
      printf '%s' "$f"
      return 0
    fi
  done <<<"$(managed_files)"
  return 1
}

# One line per managed-settings key that stops the relay from running. A
# managed statusLine that already runs the relay is not a blocker, and then
# neither is allowManagedHooksOnly (it doesn't affect a managed status line).
# Settings delivered by MDM or the claude.ai console can't be read here; the
# relay heartbeat (DATA/last_render) catches those.
managed_blockers() {
  local f managed_relay=false
  managed_relay_file >/dev/null && managed_relay=true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$managed_relay" = false ] &&
      [ "$(jq -r '(.statusLine // null) != null' "$f" 2>/dev/null)" = true ]; then
      echo "statusLine is set in $f"
    fi
    jq -r --arg f "$f" --argjson mr "$managed_relay" '
      (if .allowManagedHooksOnly == true and ($mr | not) then "allowManagedHooksOnly is true in \($f)" else empty end),
      (if .disableAllHooks == true then "disableAllHooks is true in \($f)" else empty end)' "$f" 2>/dev/null
  done <<<"$(managed_files)"
}

admin_snippet() {
  local path="$data/bin/relay.sh"
  case $path in
    "$HOME"/*) path="\$HOME${path#"$HOME"}" ;;
  esac
  jq -n --arg c "\"$path\"" '{statusLine: {type: "command", command: $c}}'
}

settings_json() {
  if [ -s "$settings" ]; then cat "$settings"; else echo '{}'; fi
}

backup_settings() {
  [ -f "$settings" ] || return 0
  # The pid keeps names unique when setup runs twice within a second.
  mkdir -p "$data/backups" && cp "$settings" "$data/backups/settings-$now-$$.json"
}

# Write stdin to settings; write through symlinks so dotfile links survive.
write_settings() {
  local content mode
  content=$(cat)
  if [ -L "$settings" ]; then
    printf '%s\n' "$content" >"$settings"
  else
    mode=$(ug_file_mode "$settings")
    printf '%s\n' "$content" | ug_write_atomic "$settings" || return 1
    # mktemp files are 0600; keep the user's original mode. The write already
    # succeeded, so a failed chmod must not be reported as a failed write.
    [ -z "$mode" ] || chmod "$mode" "$settings" 2>/dev/null || true
  fi
}

project_warnings() {
  local f
  for f in "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '(.statusLine // null) != null' "$f" 2>/dev/null)" = true ]; then
      echo "Note: $f sets its own statusLine, which overrides yours in this project. Alerts won't work here until it's removed or pointed at $relay_cmd."
    fi
  done
}

cmd_install() {
  local blockers current existing updated inner_json prev_inner
  if ! ug_have_jq; then
    echo "usage-guard needs jq. Install it (macOS: brew install jq; Debian/Ubuntu: sudo apt install jq), then run setup again."
    return 1
  fi
  blockers=$(managed_blockers)
  if [ -z "$blockers" ] && managed_relay_file >/dev/null; then
    ug_install_relay_files "$ROOT" "$data" || true
    rm -f "$data/relay-removed"
    echo "usage-guard's relay is set by your organization's managed settings; nothing to do."
    return 0
  fi
  if [ -n "$blockers" ]; then
    echo "Your organization's managed settings stop a personal status line from running:"
    printf '%s\n' "$blockers" | sed 's/^/  - /'
    echo
    echo "Nothing was changed. Ask an administrator to add this to managed settings (see the README's admin guide):"
    admin_snippet
    return 2
  fi
  if [ -s "$settings" ] && ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    echo "$settings isn't a valid JSON object. Fix it and run setup again. Nothing was changed."
    return 1
  fi
  current=$(settings_json)
  if [ "$(jq -r '.disableAllHooks == true' <<<"$current")" = true ]; then
    echo "disableAllHooks is true in $settings, which also turns off the status line. Set it to false, then run setup again."
    return 2
  fi
  existing=$(ug_statusline_command "$settings")
  if ug_is_foreign_relay_command "$existing" "$data"; then
    echo "Your statusLine runs an old usage-guard relay: $existing"
    echo "Your original status line may be saved in that old folder's inner-statusline.json, or in its backups/ folder."
    echo "Set statusLine back to your original status line (or remove it), then run setup again. Nothing was changed."
    return 1
  fi
  project_warnings
  if ! ug_install_relay_files "$ROOT" "$data"; then
    echo "Couldn't copy the relay into $data/bin."
    return 1
  fi
  if ug_is_relay_command "$existing" "$data"; then
    rm -f "$data/relay-removed"
    echo "usage-guard is already installed."
    return 0
  fi
  inner_json=$(jq -c '.statusLine // null' <<<"$current") || return 1
  updated=$(jq --arg cmd "$relay_cmd" \
    '.statusLine = ((if (.statusLine | type) == "object" then .statusLine else {} end) + {type: "command", command: $cmd})' \
    <<<"$current") || return 1
  if ! backup_settings; then
    echo "Couldn't back up $settings into $data/backups. Nothing was changed."
    return 1
  fi
  prev_inner=
  [ -f "$data/inner-statusline.json" ] && prev_inner=$(cat "$data/inner-statusline.json")
  if ! printf '%s\n' "$inner_json" | ug_write_atomic "$data/inner-statusline.json"; then
    echo "Couldn't save your current status line to $data. Nothing was changed."
    return 1
  fi
  if ! printf '%s\n' "$updated" | write_settings; then
    if [ -n "$prev_inner" ]; then
      printf '%s\n' "$prev_inner" | ug_write_atomic "$data/inner-statusline.json"
    else
      rm -f "$data/inner-statusline.json"
    fi
    echo "Couldn't write $settings. Nothing was changed."
    return 1
  fi
  rm -f "$data/relay-removed"
  echo "Installed. usage-guard now records usage from your status line; your previous status line (if any) still renders."
  echo "Alerts start after the next API response. Check anytime with /usage-guard:status."
}

cmd_uninstall() {
  local inner updated saved=true
  if ! ug_is_relay_command "$(ug_statusline_command "$settings")" "$data"; then
    echo "usage-guard's relay isn't your current status line; nothing to undo."
    return 0
  fi
  inner=$(jq -c . "$data/inner-statusline.json" 2>/dev/null)
  if [ -z "$inner" ]; then
    inner=null saved=false
  fi
  if ! backup_settings; then
    echo "Couldn't back up $settings into $data/backups. Nothing was changed."
    return 1
  fi
  updated=$(jq --argjson inner "$inner" \
    'if $inner == null then del(.statusLine) else .statusLine = $inner end' "$settings") || return 1
  if ! printf '%s\n' "$updated" | write_settings; then
    echo "Couldn't write $settings. Nothing was changed."
    return 1
  fi
  # Without the relay nothing refreshes these, and the hooks would keep
  # alerting from the last reading until its window reset.
  touch "$data/relay-removed"
  rm -f "$data/inner-statusline.json" "$data/state.json" "$data/last_render"
  if [ "$saved" = true ]; then
    echo "Removed. Your previous status line setting has been restored."
  else
    echo "No saved status line was found, so statusLine was removed. Backups of your settings are in $data/backups/."
  fi
}

# /config thresholds come from the SessionStart snapshot (the Bash tool doesn't
# see plugin options), with `setup thresholds` overrides applied on top.
effective_thresholds() {
  local base=""
  [ -f "$data/config.json" ] && base=$(jq -c '.thresholds // empty' "$data/config.json" 2>/dev/null)
  [ -n "$base" ] || base=$(ug_config_thresholds_json)
  ug_apply_threshold_overrides "$base"
}

# print_thresholds <thresholds_json> <indent>
print_thresholds() {
  jq -r 'to_entries[] | [.key, (.value.warn | tostring), (.value.wind_down | tostring),
    (.value.fallback | tostring), (.value.override // false | tostring)] | @tsv' <<<"$1" |
    while IFS="$(printf '\t')" read -r w a b f o; do
      note=""
      [ "$f" = true ] && note=" (invalid setting, using defaults)"
      [ "$o" = true ] && note=" (set with /usage-guard:setup thresholds)"
      echo "$2$(ug_window_label "$w"): $a% / $b%$note"
    done
}

thresholds_usage() {
  echo "usage: /usage-guard:setup thresholds                     show current thresholds"
  echo "       /usage-guard:setup thresholds <window> <warn> <wind-down>"
  echo "       /usage-guard:setup thresholds reset [window]"
  echo "windows: 5h, weekly, spend (or five_hour, seven_day, spend_limit); values are percentages from 1 to 100, warn below wind-down"
}

window_name() {
  case $1 in
    5h | 5-hour | five_hour) echo five_hour ;;
    weekly | week | 7d | seven_day) echo seven_day ;;
    spend | spend_limit) echo spend_limit ;;
    *) return 1 ;;
  esac
}

show_thresholds() {
  echo "Thresholds (warn / wind-down):"
  print_thresholds "$(effective_thresholds)" "  "
}

cmd_thresholds() {
  local file="$data/thresholds.json" w current updated
  current=$(jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null)
  [ -n "$current" ] || current='{}'
  case ${1:-} in
    '')
      show_thresholds
      ;;
    reset)
      if [ $# -gt 2 ]; then
        thresholds_usage
        return 1
      fi
      if [ -n "${2:-}" ]; then
        if ! w=$(window_name "$2"); then
          echo "Unknown window \"$2\"."
          thresholds_usage
          return 1
        fi
        updated=$(jq -c --arg w "$w" 'del(.[$w])' <<<"$current")
        if [ "$updated" = '{}' ]; then
          rm -f "$file"
        elif ! printf '%s\n' "$updated" | ug_write_atomic "$file"; then
          echo "Couldn't write $file. Nothing was changed."
          return 1
        fi
        echo "$(ug_window_label "$w") thresholds reset to your /config values or the defaults."
      else
        rm -f "$file"
        echo "All thresholds reset to your /config values or the defaults."
      fi
      show_thresholds
      ;;
    *)
      if ! w=$(window_name "$1"); then
        echo "Unknown window \"$1\"."
        thresholds_usage
        return 1
      fi
      if [ $# -ne 3 ] || ! ug_is_number "$2" || ! ug_is_number "$3" ||
        ! awk -v a="$2" -v b="$3" 'BEGIN { exit !(a >= 1 && b <= 100 && a < b) }'; then
        echo "Thresholds must be two percentages from 1 to 100, with warn below wind-down."
        thresholds_usage
        return 1
      fi
      updated=$(jq -c --arg w "$w" --argjson a "$2" --argjson b "$3" \
        '.[$w] = {warn: $a, wind_down: $b}' <<<"$current") || return 1
      if ! printf '%s\n' "$updated" | ug_write_atomic "$file"; then
        echo "Couldn't write $file. Nothing was changed."
        return 1
      fi
      echo "$(ug_window_label "$w") thresholds set: warn at $2%, wind down at $3%. This applies from the next prompt or tool call."
      ;;
  esac
}

tier_word() {
  case $1 in wind_down) echo "wind-down" ;; *) echo "$1" ;; esac
}

cmd_status() {
  local session=${1:-} cfg="$data/config.json" th blockers managed_file
  case $session in '' | '$'*) session="" ;; esac

  printf 'usage-guard %s\n\n' "$(ug_plugin_version "$ROOT")"

  echo "Status line relay"
  if managed_file=$(managed_relay_file); then
    echo "  configured by managed settings in $managed_file"
  elif ug_is_relay_command "$(ug_statusline_command "$settings")" "$data"; then
    echo "  configured in $settings"
  elif ug_relay_removed "$data"; then
    echo "  removed with /usage-guard:setup uninstall, so alerts are off (run /usage-guard:setup to turn them back on)"
  else
    echo "  not configured in $settings (run /usage-guard:setup)"
  fi
  if [ -f "$data/last_render" ]; then
    echo "  last ran $(ug_fmt_duration $((now - $(cat "$data/last_render")))) ago"
  elif ! ug_relay_removed "$data"; then
    echo "  has never run. If it's configured, managed or project settings may be overriding it."
  fi
  blockers=$(managed_blockers)
  if [ -n "$blockers" ]; then
    echo "  blocked by managed settings:"
    printf '%s\n' "$blockers" | sed 's/^/    - /'
  fi
  if [ -f "$settings" ] && [ "$(jq -r '.disableAllHooks == true' "$settings" 2>/dev/null)" = true ]; then
    echo "  disableAllHooks is true in $settings, which turns off the status line"
  fi

  th=$(effective_thresholds)

  echo
  echo "Usage"
  if [ -f "$data/state.json" ]; then
    jq -r --argjson th "$th" '
      to_entries[]
      | .value.used_percentage as $p
      | [.key, ($p | tostring), (.value.resets_at | tostring), (.value.updated_at | tostring),
         (if $th[.key] == null then ""
          elif $p >= $th[.key].wind_down then "wind_down"
          elif $p >= $th[.key].warn then "warn" else "" end)]
      | @tsv' "$data/state.json" |
      while IFS="$(printf '\t')" read -r w p r u t; do
        if [ "$r" -le "$now" ]; then
          echo "  $(ug_window_label "$w"): window has reset (last reading $(ug_fmt_pct "$w" "$p"))"
          continue
        fi
        echo "  $(ug_window_label "$w"): $(ug_fmt_pct "$w" "$p")${t:+ ($(tier_word "$t"))}, resets in $(ug_fmt_duration $((r - now))) at $(ug_fmt_local_time "$r"); updated $(ug_fmt_duration $((now - u))) ago"
      done
  else
    echo "  no usage data received yet. Claude Code only provides it on claude.ai Pro/Max plans and behind a Claude apps gateway with spend limits."
  fi

  echo
  echo "Settings"
  if [ -f "$cfg" ]; then
    [ "$(jq -r .enabled "$cfg")" = false ] && echo "  alerts are disabled"
    echo "  handoff file: $(jq -r .handoff_path "$cfg")"
    echo "  resume scheduling limit: $(jq -r .resume_max_wait "$cfg")"
  else
    echo "  defaults (your settings appear here after the next session starts)"
  fi
  echo "  thresholds (warn / wind-down):"
  print_thresholds "$th" "    "

  if [ -n "$session" ] && [ -d "$data/sent/$(ug_safe_id "$session")" ]; then
    echo
    echo "This session has been told"
    local agent_dir marker name
    for agent_dir in "$data/sent/$(ug_safe_id "$session")"/*; do
      [ -d "$agent_dir" ] || continue
      for marker in "$agent_dir"/*; do
        [ -f "$marker" ] || continue
        name=$(basename "$marker")
        echo "  $(basename "$agent_dir"): $(ug_window_label "${name%%-*}") $(tier_word "${name##*-}")"
      done
    done
  fi
}

case ${1:-} in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status "${2:-}" ;;
  thresholds)
    shift
    cmd_thresholds "$@"
    ;;
  *)
    echo "usage: setup.sh install|uninstall|status [session_id]|thresholds [...]"
    exit 1
    ;;
esac
