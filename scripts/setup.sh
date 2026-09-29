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

# One line per managed-settings key that stops a personal status line from running.
# Settings delivered by MDM or the claude.ai console can't be read here; the
# relay heartbeat (DATA/last_render) catches those.
managed_blockers() {
  local dir f
  dir=$(managed_dir)
  for f in "$dir/managed-settings.json" "$dir"/managed-settings.d/*.json; do
    [ -f "$f" ] || continue
    jq -r --arg f "$f" '
      (if (.statusLine // null) != null then "statusLine is set in \($f)" else empty end),
      (if .allowManagedHooksOnly == true then "allowManagedHooksOnly is true in \($f)" else empty end),
      (if .disableAllHooks == true then "disableAllHooks is true in \($f)" else empty end)' "$f" 2>/dev/null
  done
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
  mkdir -p "$data/backups" && cp "$settings" "$data/backups/settings-$now.json"
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
    # mktemp files are 0600; keep the user's original mode.
    [ -z "$mode" ] || chmod "$mode" "$settings"
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
  local blockers current updated inner_json prev_inner
  if ! ug_have_jq; then
    echo "usage-guard needs jq. Install it (macOS: brew install jq; Debian/Ubuntu: sudo apt install jq), then run setup again."
    return 1
  fi
  blockers=$(managed_blockers)
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
  project_warnings
  if ! ug_install_relay_files "$ROOT" "$data"; then
    echo "Couldn't copy the relay into $data/bin."
    return 1
  fi
  if ug_is_relay_command "$(ug_statusline_command "$settings")" "$data"; then
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
  echo "Installed. usage-guard now records usage from your status line; your previous status line (if any) still renders."
  echo "Alerts start after the next API response. Check anytime with /usage-guard:status."
}

cmd_uninstall() {
  local inner updated
  if ! ug_is_relay_command "$(ug_statusline_command "$settings")" "$data"; then
    echo "usage-guard's relay isn't your current status line; nothing to undo."
    return 0
  fi
  inner=$(jq -c . "$data/inner-statusline.json" 2>/dev/null)
  [ -n "$inner" ] || inner=null
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
  rm -f "$data/inner-statusline.json"
  echo "Removed. Your previous status line setting has been restored."
}

case ${1:-} in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "usage: setup.sh install|uninstall|status [session_id]"
    exit 1
    ;;
esac
