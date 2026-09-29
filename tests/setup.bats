#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  SETTINGS="$HOME/.claude/settings.json"
  RELAY_CMD="\"$USAGE_GUARD_HOME/bin/relay.sh\""
  cd "$TEST_TMP"
}
teardown() { teardown_env; }

run_setup() { run "$UG_BASH" "$ROOT/scripts/setup.sh" "$@"; }

@test "fresh install creates settings with the relay" {
  run_setup install
  [ "$status" -eq 0 ]
  [ "$(jq -c .statusLine "$SETTINGS")" = "$(jq -nc --arg c "$RELAY_CMD" '{type: "command", command: $c}')" ]
  [ "$(cat "$USAGE_GUARD_HOME/inner-statusline.json")" = "null" ]
  [ -x "$USAGE_GUARD_HOME/bin/relay.sh" ]
  [[ $output == *"Installed"* ]]
}

@test "empty settings file is treated as {}" {
  : >"$SETTINGS"
  run_setup install
  [ "$status" -eq 0 ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
}

@test "wraps an existing object statusLine and keeps extra fields and other keys" {
  echo '{"model":"opus","statusLine":{"type":"command","command":"~/sl.sh","padding":2,"refreshInterval":5}}' >"$SETTINGS"
  run_setup install
  [ "$(jq -r .model "$SETTINGS")" = opus ]
  [ "$(jq -c '.statusLine | {padding, refreshInterval, command}' "$SETTINGS")" = "$(jq -nc --arg c "$RELAY_CMD" '{padding: 2, refreshInterval: 5, command: $c}')" ]
  [ "$(jq -c . "$USAGE_GUARD_HOME/inner-statusline.json")" = '{"type":"command","command":"~/sl.sh","padding":2,"refreshInterval":5}' ]
  ls "$USAGE_GUARD_HOME"/backups/settings-*.json
}

@test "wraps a string-form statusLine" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
  [ "$(jq -c . "$USAGE_GUARD_HOME/inner-statusline.json")" = '"~/sl.sh"' ]
}

@test "reinstall is a no-op and keeps the saved inner status line" {
  echo '{"statusLine":{"type":"command","command":"~/sl.sh"}}' >"$SETTINGS"
  run_setup install
  run_setup install
  [ "$status" -eq 0 ]
  [[ $output == *"already installed"* ]]
  [ "$(jq -r .command "$USAGE_GUARD_HOME/inner-statusline.json")" = "~/sl.sh" ]
}

@test "invalid JSON aborts without changes" {
  echo '{nope' >"$SETTINGS"
  run_setup install
  [ "$status" -eq 1 ]
  [ "$(cat "$SETTINGS")" = '{nope' ]
}

@test "symlinked settings stay a symlink" {
  mkdir -p "$TEST_TMP/dotfiles"
  echo '{}' >"$TEST_TMP/dotfiles/settings.json"
  ln -s "$TEST_TMP/dotfiles/settings.json" "$SETTINGS"
  run_setup install
  [ -L "$SETTINGS" ]
  [ "$(jq -r .statusLine.command "$TEST_TMP/dotfiles/settings.json")" = "$RELAY_CMD" ]
}

@test "data dir with spaces produces a runnable quoted command" {
  export USAGE_GUARD_HOME="$TEST_TMP/data dir"
  run_setup install
  cmd=$(jq -r .statusLine.command "$SETTINGS")
  [ "$cmd" = "\"$TEST_TMP/data dir/bin/relay.sh\"" ]
  run bash -c "$cmd" <<<'{"model":{"display_name":"Opus"}}'
  [ "$output" = "Opus" ]
}

@test "managed statusLine blocks install and prints an admin snippet" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR"
  echo '{"statusLine":{"type":"command","command":"corp.sh"}}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"statusLine is set in $USAGE_GUARD_MANAGED_DIR/managed-settings.json"* ]]
  [[ $output == *'bin/relay.sh'* ]]
  [ ! -f "$SETTINGS" ]
}

@test "allowManagedHooksOnly in managed-settings.d blocks install" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR/managed-settings.d"
  echo '{"allowManagedHooksOnly":true}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.d/10-hooks.json"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"allowManagedHooksOnly is true"* ]]
}

@test "managed disableAllHooks blocks install" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR"
  echo '{"disableAllHooks":true}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"disableAllHooks is true"* ]]
}

@test "user disableAllHooks blocks install" {
  echo '{"disableAllHooks":true}' >"$SETTINGS"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"disableAllHooks is true in $SETTINGS"* ]]
  [ "$(jq -c . "$SETTINGS")" = '{"disableAllHooks":true}' ]
}

@test "warns about a project statusLine override" {
  mkdir -p "$TEST_TMP/.claude"
  echo '{"statusLine":"proj.sh"}' >"$TEST_TMP/.claude/settings.local.json"
  run_setup install
  [ "$status" -eq 0 ]
  [[ $output == *"$TEST_TMP/.claude/settings.local.json sets its own statusLine"* ]]
}

@test "uninstall restores an object statusLine exactly" {
  echo '{"statusLine":{"type":"command","command":"~/sl.sh","padding":2}}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ "$status" -eq 0 ]
  [ "$(jq -c .statusLine "$SETTINGS")" = '{"type":"command","command":"~/sl.sh","padding":2}' ]
  [ ! -f "$USAGE_GUARD_HOME/inner-statusline.json" ]
}

@test "uninstall removes the key when there was none, keeping other keys" {
  echo '{"model":"opus"}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ "$(jq -c . "$SETTINGS")" = '{"model":"opus"}' ]
}

@test "uninstall restores a string statusLine" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ "$(jq -c .statusLine "$SETTINGS")" = '"~/sl.sh"' ]
}

@test "uninstall does nothing when the relay isn't the current status line" {
  echo '{"statusLine":"other.sh"}' >"$SETTINGS"
  run_setup uninstall
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to undo"* ]]
  [ "$(jq -c . "$SETTINGS")" = '{"statusLine":"other.sh"}' ]
}

@test "missing jq fails with install instructions" {
  export USAGE_GUARD_JQ=/nonexistent/jq
  run_setup install
  [ "$status" -eq 1 ]
  [[ $output == *"brew install jq"* ]]
}

@test "unknown subcommand prints usage" {
  run_setup frobnicate
  [ "$status" -eq 1 ]
  [[ $output == *"usage: setup.sh install|uninstall|status"* ]]
}

skip_if_root() { [ "$(id -u)" -eq 0 ] && skip "root ignores directory permissions"; return 0; }

@test "install with an unwritable settings dir fails and changes nothing" {
  skip_if_root
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  chmod 555 "$HOME/.claude"
  run_setup install
  chmod 755 "$HOME/.claude"
  [ "$status" -eq 1 ]
  [[ $output == *"Couldn't write $SETTINGS"* ]]
  [[ $output != *"Installed"* ]]
  [ "$(cat "$SETTINGS")" = '{"statusLine":"~/sl.sh"}' ]
  [ ! -f "$USAGE_GUARD_HOME/inner-statusline.json" ]
}

@test "uninstall with an unwritable settings dir fails and keeps the saved status line" {
  skip_if_root
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  chmod 555 "$HOME/.claude"
  run_setup uninstall
  chmod 755 "$HOME/.claude"
  [ "$status" -eq 1 ]
  [[ $output == *"Couldn't write $SETTINGS"* ]]
  [ "$(jq -c . "$USAGE_GUARD_HOME/inner-statusline.json")" = '"~/sl.sh"' ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
}

@test "install aborts when the backup can't be written" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  mkdir -p "$USAGE_GUARD_HOME"
  echo x >"$USAGE_GUARD_HOME/backups"
  run_setup install
  [ "$status" -eq 1 ]
  [[ $output == *"Couldn't back up"* ]]
  [ "$(cat "$SETTINGS")" = '{"statusLine":"~/sl.sh"}' ]
  [ ! -f "$USAGE_GUARD_HOME/inner-statusline.json" ]
}

@test "install recognises other spellings of the relay command as already installed" {
  export USAGE_GUARD_HOME="$HOME/ug-data"
  for cmd in '"$HOME/ug-data/bin/relay.sh"' "$HOME/ug-data/bin/relay.sh" "bash $HOME/ug-data/bin/relay.sh" "bash \"$HOME/ug-data/bin/relay.sh\"" '~/ug-data/bin/relay.sh'; do
    rm -rf "$USAGE_GUARD_HOME"
    jq -n --arg c "$cmd" '{statusLine: {type: "command", command: $c}}' >"$SETTINGS"
    cp "$SETTINGS" "$TEST_TMP/before.json"
    run_setup install
    [ "$status" -eq 0 ]
    [[ $output == *"already installed"* ]]
    [ ! -f "$USAGE_GUARD_HOME/inner-statusline.json" ]
    cmp "$SETTINGS" "$TEST_TMP/before.json"
  done
}

@test "install preserves the settings file mode" {
  echo '{}' >"$SETTINGS"
  chmod 644 "$SETTINGS"
  run_setup install
  [ "$status" -eq 0 ]
  mode=$(stat -c %a "$SETTINGS" 2>/dev/null || stat -f %Lp "$SETTINGS")
  [ "$mode" = 644 ]
  run_setup uninstall
  mode=$(stat -c %a "$SETTINGS" 2>/dev/null || stat -f %Lp "$SETTINGS")
  [ "$mode" = 644 ]
}

@test "default data dir is ~/.claude/usage-guard, not the plugin data folder" {
  unset USAGE_GUARD_HOME
  export CLAUDE_PLUGIN_DATA="$HOME/.claude/plugins/data/usage-guard-mkt"
  run_setup install
  [ "$status" -eq 0 ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "\"$HOME/.claude/usage-guard/bin/relay.sh\"" ]
  [ -x "$HOME/.claude/usage-guard/bin/relay.sh" ]
  [ -f "$HOME/.claude/usage-guard/inner-statusline.json" ]
  [ ! -e "$CLAUDE_PLUGIN_DATA" ]
}

@test "install refuses to wrap an old or foreign usage-guard relay" {
  old="$HOME/.claude/plugins/data/usage-guard-mkt/bin/relay.sh"
  for cmd in "\"$old\"" "bash $old" '"$HOME/.claude/plugins/data/abc/bin/relay.sh"' "\"$TEST_TMP/other/usage-guard/bin/relay.sh\""; do
    jq -n --arg c "$cmd" '{statusLine: {type: "command", command: $c, padding: 1}}' >"$SETTINGS"
    cp "$SETTINGS" "$TEST_TMP/before.json"
    run_setup install
    [ "$status" -eq 1 ]
    [[ $output == *"old usage-guard relay"* ]]
    [[ $output == *"inner-statusline.json"* ]]
    [[ $output == *"backups/"* ]]
    [[ $output == *"Nothing was changed."* ]]
    cmp "$SETTINGS" "$TEST_TMP/before.json"
    [ ! -f "$USAGE_GUARD_HOME/inner-statusline.json" ]
    [ ! -d "$USAGE_GUARD_HOME/backups" ]
  done
}

@test "uninstall without a saved status line removes the relay and says so honestly" {
  echo '{"model":"opus","statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  rm -f "$USAGE_GUARD_HOME/inner-statusline.json"
  run_setup uninstall
  [ "$status" -eq 0 ]
  [ "$output" = "No saved status line was found, so statusLine was removed. Backups of your settings are in $USAGE_GUARD_HOME/backups/." ]
  [ "$(jq -c . "$SETTINGS")" = '{"model":"opus"}' ]
}

@test "uninstall with an unreadable saved status line does not claim a restore" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  echo '{corrupt' >"$USAGE_GUARD_HOME/inner-statusline.json"
  run_setup uninstall
  [ "$status" -eq 0 ]
  [[ $output == "No saved status line was found"* ]]
  [[ $output != *"restored"* ]]
  [ "$(jq -r 'has("statusLine")' "$SETTINGS")" = false ]
}

@test "uninstall after installing with no previous status line reports a restore" {
  echo '{}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ "$status" -eq 0 ]
  [ "$output" = "Removed. Your previous status line setting has been restored." ]
}

@test "uninstall clears recorded usage so the hooks stop alerting from stale readings" {
  echo '{}' >"$SETTINGS"
  run_setup install
  write_state "$(state_entry five_hour 92)"
  echo "$NOW" >"$USAGE_GUARD_HOME/last_render"
  run_setup uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$USAGE_GUARD_HOME/state.json" ]
  [ ! -e "$USAGE_GUARD_HOME/last_render" ]
  run "$UG_BASH" "$ROOT/scripts/guard.sh" <<<"$(hook_input UserPromptSubmit)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a relay render after uninstall doesn't bring the alerts back" {
  echo '{}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  [ -e "$USAGE_GUARD_HOME/relay-removed" ]
  # Claude Code may render once more with the old settings before reloading them.
  rl=$(rl_entry five_hour 14)
  run "$UG_BASH" "$USAGE_GUARD_HOME/bin/relay.sh" <<<"$(sl_input "$rl")"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$USAGE_GUARD_HOME/state.json" ]
  [ ! -e "$USAGE_GUARD_HOME/last_render" ]
  # Even a reading written by hand is ignored until setup is run again.
  write_state "$(state_entry five_hour 94)"
  run "$UG_BASH" "$ROOT/scripts/guard.sh" <<<"$(hook_input UserPromptSubmit)"
  [ -z "$output" ]
}

@test "install after uninstall records and alerts again" {
  echo '{}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  run_setup install
  [ "$status" -eq 0 ]
  [ ! -e "$USAGE_GUARD_HOME/relay-removed" ]
  rl=$(rl_entry five_hour 94)
  run "$UG_BASH" "$USAGE_GUARD_HOME/bin/relay.sh" <<<"$(sl_input "$rl")"
  [ "$(jq -r .five_hour.used_percentage "$USAGE_GUARD_HOME/state.json")" = 94 ]
  run "$UG_BASH" "$ROOT/scripts/guard.sh" <<<"$(hook_input UserPromptSubmit)"
  [[ $(jq -r .hookSpecificOutput.additionalContext <<<"$output") == *"Wind down now"* ]]
}

@test "status says the relay was removed with uninstall" {
  echo '{}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  run_setup status
  [[ $output == *"removed with /usage-guard:setup uninstall"* ]]
}

@test "managed statusLine that runs the relay is success, not a blocker" {
  unset USAGE_GUARD_HOME
  mkdir -p "$USAGE_GUARD_MANAGED_DIR/managed-settings.d"
  echo '{"statusLine":{"type":"command","command":"corp.sh"}}' >"$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  run_setup install
  [ "$status" -eq 2 ]
  # Roll out exactly the snippet setup printed for the admin.
  printf '%s\n' "$output" | sed -n '/^{/,/^}/p' >"$TEST_TMP/snippet.json"
  [ "$(jq -r .statusLine.command "$TEST_TMP/snippet.json")" = '"$HOME/.claude/usage-guard/bin/relay.sh"' ]
  rm "$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  jq '. + {allowManagedHooksOnly: true}' "$TEST_TMP/snippet.json" >"$USAGE_GUARD_MANAGED_DIR/managed-settings.d/50-usage-guard.json"
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  [ "$status" -eq 0 ]
  [ "$output" = "usage-guard's relay is set by your organization's managed settings; nothing to do." ]
  [ "$(jq -c . "$SETTINGS")" = '{"statusLine":"~/sl.sh"}' ]
  [ ! -f "$HOME/.claude/usage-guard/inner-statusline.json" ]
  [ ! -d "$HOME/.claude/usage-guard/backups" ]
  [ -x "$HOME/.claude/usage-guard/bin/relay.sh" ]
}

@test "managed relay with managed disableAllHooks still blocks" {
  mkdir -p "$USAGE_GUARD_MANAGED_DIR"
  jq -n --arg c "\"$USAGE_GUARD_HOME/bin/relay.sh\"" '{statusLine: {type: "command", command: $c}, disableAllHooks: true}' \
    >"$USAGE_GUARD_MANAGED_DIR/managed-settings.json"
  run_setup install
  [ "$status" -eq 2 ]
  [[ $output == *"disableAllHooks is true"* ]]
  [[ $output != *"statusLine is set"* ]]
}

@test "backups taken within the same second don't overwrite each other" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  run_setup uninstall
  run_setup install
  [ "$(ls "$USAGE_GUARD_HOME"/backups/settings-"$NOW"-*.json | wc -l | tr -d ' ')" -eq 3 ]
}

@test "a failed chmod after a successful write is not reported as a failure" {
  echo '{}' >"$SETTINGS"
  mkdir -p "$TEST_TMP/fakebin"
  # chmod that fails only on settings.json.
  printf '#!/bin/sh\ncase "$2" in */settings.json) exit 1 ;; esac\nexec /bin/chmod "$@"\n' >"$TEST_TMP/fakebin/chmod"
  chmod +x "$TEST_TMP/fakebin/chmod"
  PATH="$TEST_TMP/fakebin:$PATH" run_setup install
  [ "$status" -eq 0 ]
  [[ $output == *"Installed"* ]]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
}
