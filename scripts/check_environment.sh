#!/usr/bin/env bash
# check_environment.sh <profile-theme-name>: report the current Omarchy
# theme, whether <profile-theme-name> is available locally, and the current
# third-party plugin list (id + enabled), for BarWidget.qml's restore-time
# environment check. Read-only; never modifies anything.
#
# <profile-theme-name> may be empty (an older profile that predates theme
# capture) - the availability check then trivially reports false and is
# ignored by the caller, since there's no theme to restore either way.
#
# Output:
#   {"currentTheme": "...", "themeAvailable": bool,
#    "plugins": [{"id": "...", "enabled": bool}, ...]}
set -euo pipefail

command -v omarchy >/dev/null 2>&1 || { echo '{"currentTheme":"","themeAvailable":false,"plugins":[]}'; exit 0; }

WANT_THEME="${1:-}"
CURRENT=$(omarchy theme current 2>/dev/null) || CURRENT=

AVAILABLE=false
if [ -n "$WANT_THEME" ]; then
  # See capture_environment.sh: `theme dir` wants the slug (lowercase,
  # hyphenated), not the display name a profile's theme.name carries.
  SLUG=$(printf '%s' "$WANT_THEME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  DIR=$(omarchy theme dir "$SLUG" 2>/dev/null) || DIR=
  [ -n "$DIR" ] && [ -d "$DIR" ] && AVAILABLE=true
fi

PLUGINS_JSON=$(omarchy plugin list --json 2>/dev/null \
  | jq -c '[.[] | {id: .id, enabled: .enabled}]' 2>/dev/null) || PLUGINS_JSON="[]"

jq -nc --arg cur "$CURRENT" --argjson avail "$AVAILABLE" --argjson plugins "$PLUGINS_JSON" \
  '{currentTheme: $cur, themeAvailable: $avail, plugins: $plugins}'
