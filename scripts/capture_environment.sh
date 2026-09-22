#!/usr/bin/env bash
# capture_environment.sh: print a JSON object describing the current Omarchy
# theme and enabled third-party shell plugins, for BarWidget.qml's snapshot
# capture. Read-only; never modifies anything.
#
# Output:
#   {"theme": {"name": "...", "repoUrl": "..."} | null,
#    "plugins": [{"id": "...", "repoUrl": "..."}, ...]}
#
# - theme.repoUrl is the git origin of a user-installed theme (cloned via
#   `omarchy theme install <url>`, living under ~/.config/omarchy/themes);
#   "" for a built-in theme (nothing to reinstall - it ships with Omarchy).
# - plugins lists only currently-ENABLED third-party (non-first-party)
#   plugins, each with the git origin of its own clone under
#   ~/.config/omarchy/plugins (installed via `omarchy plugin add <url>`).
# - Either list element with no discoverable git origin (not a git clone, or
#   the remote lookup failed) just carries an empty repoUrl; restore then has
#   no source to install from and simply can't offer that fix.
set -euo pipefail

command -v omarchy >/dev/null 2>&1 || { echo '{"theme":null,"plugins":[]}'; exit 0; }

NAME=$(omarchy theme current 2>/dev/null) || NAME=
REPO=
if [ -n "$NAME" ]; then
  # `theme current` prints the display form (title-cased, spaces); `theme
  # dir` takes the slug it was derived from (lowercase, hyphenated) and does
  # not do this conversion itself - `theme set` does, internally, which is
  # why passing the display name to `theme dir` looks like it works (it
  # prints *a* path) but silently resolves the wrong, nonexistent one.
  SLUG=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  DIR=$(omarchy theme dir "$SLUG" 2>/dev/null) || DIR=
  case "$DIR" in
    "$HOME/.config/omarchy/themes/"*)
      REPO=$(git -C "$DIR" remote get-url origin 2>/dev/null) || REPO=
      ;;
  esac
fi

PLUGINS_JSON="[]"
IDS=$(omarchy plugin list --json 2>/dev/null \
  | jq -r '.[] | select(.firstParty==false and .enabled==true) | .id' 2>/dev/null) || IDS=
if [ -n "$IDS" ]; then
  PLUGINS_JSON=$(
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      dir="$HOME/.config/omarchy/plugins/$id"
      repo=$(git -C "$dir" remote get-url origin 2>/dev/null) || repo=
      jq -nc --arg id "$id" --arg repo "$repo" '{id: $id, repoUrl: $repo}'
    done <<< "$IDS" | jq -sc '.'
  )
fi

jq -nc --arg name "$NAME" --arg repo "$REPO" --argjson plugins "$PLUGINS_JSON" \
  '{theme: (if $name == "" then null else {name: $name, repoUrl: $repo} end), plugins: $plugins}'
