#!/usr/bin/env bash
# Shared helpers for usage-guard scripts. Sourced, never executed.
# Must stay compatible with bash 3.2 (macOS /bin/bash).

# shellcheck disable=SC2034
UG_WINDOWS="five_hour seven_day spend_limit"

ug_data_dir() {
  printf '%s' "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/usage-guard}"
}

ug_config_dir() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

ug_now() {
  printf '%s' "${USAGE_GUARD_NOW:-$(date +%s)}"
}

ug_have_jq() {
  command -v "${USAGE_GUARD_JQ:-jq}" >/dev/null 2>&1
}

# Write stdin to $1 atomically: temp file in the same directory, then rename.
ug_write_atomic() {
  local dest=$1 dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.ug.XXXXXX") || return 1
  if cat >"$tmp"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Seconds -> "2d 3h", "1h 12m" or "45m".
ug_fmt_duration() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  local d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  if [ "$d" -gt 0 ]; then
    printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh %dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

# Epoch -> "Thu 14:30" in local time. BSD date first, then GNU date.
ug_fmt_local_time() {
  date -r "$1" '+%a %H:%M' 2>/dev/null || date -d "@$1" '+%a %H:%M'
}

# "90m" / "6h" -> seconds. Returns 1 for anything else.
ug_parse_duration() {
  if [[ $1 =~ ^([0-9]+)([mh])$ ]]; then
    local n=$((10#${BASH_REMATCH[1]}))
    if [ "${BASH_REMATCH[2]}" = h ]; then
      echo $((n * 3600))
    else
      echo $((n * 60))
    fi
  else
    return 1
  fi
}

# Plugin option from CLAUDE_PLUGIN_OPTION_<KEY>, or $2 when unset/empty.
ug_option() {
  local var
  var="CLAUDE_PLUGIN_OPTION_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${!var:-}" ]; then
    printf '%s' "${!var}"
  else
    printf '%s' "$2"
  fi
}

ug_bool_option() {
  case $(ug_option "$1" "$2") in
    true | TRUE | True | 1 | yes) echo true ;;
    false | FALSE | False | 0 | no) echo false ;;
    *) echo "$2" ;;
  esac
}

# Make an id safe to use as a single path segment.
ug_safe_id() {
  if [ -z "$1" ]; then
    printf 'unknown'
  else
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
  fi
}

ug_default_threshold() {
  case "$1:$2" in
    five_hour:warn) echo 75 ;;
    five_hour:wind_down) echo 90 ;;
    seven_day:warn) echo 85 ;;
    seven_day:wind_down) echo 95 ;;
    spend_limit:warn) echo 75 ;;
    spend_limit:wind_down) echo 95 ;;
  esac
}

ug_is_number() {
  [[ $1 =~ ^(0|[1-9][0-9]*)([.][0-9]+)?$ ]]
}

# Effective thresholds per window. Invalid or inverted pairs fall back to defaults.
ug_thresholds_json() {
  local json='{}' w dw dd warn wind fb
  for w in $UG_WINDOWS; do
    dw=$(ug_default_threshold "$w" warn)
    dd=$(ug_default_threshold "$w" wind_down)
    warn=$(ug_option "${w}_warn" "$dw")
    wind=$(ug_option "${w}_wind_down" "$dd")
    fb=false
    if ! ug_is_number "$warn" || ! ug_is_number "$wind" ||
      awk -v a="$warn" -v b="$wind" 'BEGIN { exit !(a >= b) }'; then
      warn=$dw wind=$dd fb=true
    fi
    json=$(jq -c --arg w "$w" --argjson a "$warn" --argjson b "$wind" --argjson f "$fb" \
      '.[$w] = {warn: $a, wind_down: $b, fallback: $f}' <<<"$json")
  done
  printf '%s' "$json"
}

ug_window_label() {
  case $1 in
    five_hour) echo "5-hour" ;;
    seven_day) echo "weekly" ;;
    spend_limit) echo "spend limit" ;;
    *) echo "$1" ;;
  esac
}

# Whole-number percentage; spend at or over 100 reads "exceeded (N%)".
ug_fmt_pct() {
  local p=${2%%.*}
  if [ "$1" = spend_limit ] && [ "$p" -ge 100 ]; then
    printf 'exceeded (%s%%)' "$p"
  else
    printf '%s%%' "$p"
  fi
}

ug_resume_max_wait() {
  local v
  v=$(ug_option resume_max_wait 6h)
  if ug_parse_duration "$v" >/dev/null; then echo "$v"; else echo 6h; fi
}

# Replace {{key}} with each string value in $2 (a JSON object). jq gsub keeps
# replacement text literal, so values may contain &, \ or $.
ug_render_template() {
  jq -Rrs --argjson v "$2" \
    'reduce ($v | to_entries[]) as $e (.; gsub("\\{\\{" + $e.key + "\\}\\}"; $e.value)) | sub("\n$"; "")' "$1"
}

ug_template_path() {
  local custom
  custom=$(ug_option messages_dir "")
  if [ -n "$custom" ] && [ -f "$custom/$2" ]; then
    printf '%s' "$custom/$2"
  else
    printf '%s' "$1/messages/$2"
  fi
}

ug_plugin_version() {
  local v
  v=$(jq -r '.version // empty' "$1/.claude-plugin/plugin.json" 2>/dev/null)
  printf '%s' "${v:-0}"
}

ug_install_relay_files() {
  local root=$1 data=$2
  mkdir -p "$data/bin" || return 1
  cp "$root/scripts/relay.sh" "$root/scripts/lib.sh" "$data/bin/" || return 1
  chmod +x "$data/bin/relay.sh"
  ug_plugin_version "$root" >"$data/bin/VERSION"
}

ug_relay_command() {
  printf '"%s/bin/relay.sh"' "$1"
}

ug_statusline_command() {
  [ -f "$1" ] || return 0
  jq -r '.statusLine
    | if type == "object" then (.command // "")
      elif type == "string" then .
      else "" end' "$1" 2>/dev/null
}

# True when status line command $1 runs the installed relay in data dir $2, however
# it is spelled: quoted or bare, with a bash/sh prefix, or with a leading $HOME or ~.
ug_is_relay_command() {
  local cmd=$1 want="$2/bin/relay.sh"
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  cmd="${cmd%"${cmd##*[![:space:]]}"}"
  case $cmd in
    "bash "* | "sh "*)
      cmd=${cmd#* }
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      ;;
  esac
  case $cmd in
    \"*\") cmd=${cmd#\"} cmd=${cmd%\"} ;;
    \'*\') cmd=${cmd#\'} cmd=${cmd%\'} ;;
  esac
  # shellcheck disable=SC2016  # literal $HOME is what we match
  case $cmd in
    '$HOME'/*) cmd="$HOME/${cmd#'$HOME'/}" ;;
    '${HOME}'/*) cmd="$HOME/${cmd#'${HOME}'/}" ;;
    '~'/*) cmd="$HOME/${cmd#'~'/}" ;;
  esac
  [ "$cmd" = "$want" ]
}

# Octal permission bits of $1 on Linux or macOS/BSD; empty if unknown.
ug_file_mode() {
  local m
  m=$(stat -c %a "$1" 2>/dev/null) || m=$(stat -f %Lp "$1" 2>/dev/null) || m=
  case $m in
    '' | *[!0-7]*) m= ;;
  esac
  printf '%s' "$m"
}
