#!/usr/bin/env bats

load test_helper

setup() {
  setup_env
  SETTINGS="$HOME/.claude/settings.json"
  RELAY_CMD="\"$CLAUDE_PLUGIN_DATA/bin/relay.sh\""
  cd "$TEST_TMP"
}
teardown() { teardown_env; }

run_setup() { run "$UG_BASH" "$ROOT/scripts/setup.sh" "$@"; }

@test "fresh install creates settings with the relay" {
  run_setup install
  [ "$status" -eq 0 ]
  [ "$(jq -c .statusLine "$SETTINGS")" = "$(jq -nc --arg c "$RELAY_CMD" '{type: "command", command: $c}')" ]
  [ "$(cat "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = "null" ]
  [ -x "$CLAUDE_PLUGIN_DATA/bin/relay.sh" ]
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
  [ "$(jq -c . "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = '{"type":"command","command":"~/sl.sh","padding":2,"refreshInterval":5}' ]
  ls "$CLAUDE_PLUGIN_DATA"/backups/settings-*.json
}

@test "wraps a string-form statusLine" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  run_setup install
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
  [ "$(jq -c . "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = '"~/sl.sh"' ]
}

@test "reinstall is a no-op and keeps the saved inner status line" {
  echo '{"statusLine":{"type":"command","command":"~/sl.sh"}}' >"$SETTINGS"
  run_setup install
  run_setup install
  [ "$status" -eq 0 ]
  [[ $output == *"already installed"* ]]
  [ "$(jq -r .command "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = "~/sl.sh" ]
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
  export CLAUDE_PLUGIN_DATA="$TEST_TMP/data dir"
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
  [ ! -f "$CLAUDE_PLUGIN_DATA/inner-statusline.json" ]
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
  [ ! -f "$CLAUDE_PLUGIN_DATA/inner-statusline.json" ]
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
  [ "$(jq -c . "$CLAUDE_PLUGIN_DATA/inner-statusline.json")" = '"~/sl.sh"' ]
  [ "$(jq -r .statusLine.command "$SETTINGS")" = "$RELAY_CMD" ]
}

@test "install aborts when the backup can't be written" {
  echo '{"statusLine":"~/sl.sh"}' >"$SETTINGS"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  echo x >"$CLAUDE_PLUGIN_DATA/backups"
  run_setup install
  [ "$status" -eq 1 ]
  [[ $output == *"Couldn't back up"* ]]
  [ "$(cat "$SETTINGS")" = '{"statusLine":"~/sl.sh"}' ]
  [ ! -f "$CLAUDE_PLUGIN_DATA/inner-statusline.json" ]
}

@test "install recognises other spellings of the relay command as already installed" {
  export CLAUDE_PLUGIN_DATA="$HOME/ug-data"
  for cmd in '"$HOME/ug-data/bin/relay.sh"' "$HOME/ug-data/bin/relay.sh" "bash $HOME/ug-data/bin/relay.sh" "bash \"$HOME/ug-data/bin/relay.sh\"" '~/ug-data/bin/relay.sh'; do
    rm -rf "$CLAUDE_PLUGIN_DATA"
    jq -n --arg c "$cmd" '{statusLine: {type: "command", command: $c}}' >"$SETTINGS"
    cp "$SETTINGS" "$TEST_TMP/before.json"
    run_setup install
    [ "$status" -eq 0 ]
    [[ $output == *"already installed"* ]]
    [ ! -f "$CLAUDE_PLUGIN_DATA/inner-statusline.json" ]
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
