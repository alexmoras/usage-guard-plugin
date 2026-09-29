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
