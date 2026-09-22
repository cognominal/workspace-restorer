#!/usr/bin/env bash
# omarchy_shell_aur_deps.sh: list AUR-origin packages that provide commands
# the Omarchy shell (quickshell config + plugins) shells out to.
#
# Copied from the standalone `omarchy-shell-aur-deps` command (unchanged
# logic) so the "Check Shell Packages" action in BarWidget.qml works as a
# self-contained part of this plugin rather than depending on something only
# present in one user's ~/bin.
#
# Method: statically grep the shell source and installed plugins for
# `command: [...]` process invocations and `bash -c "..."` strings, extract
# the first token (the binary), resolve each to the package that owns it,
# and report which of those packages are foreign to the official repos
# (pacman -Qm), which on an Omarchy/Arch system means AUR (or a manually
# built/installed package).
#
# Usage:
#   omarchy_shell_aur_deps.sh            # AUR packages only (the answer)
#   omarchy_shell_aur_deps.sh -v         # also show official-repo + unresolved commands
set -euo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: omarchy_shell_aur_deps.sh [-v]

List AUR-origin packages that provide commands the Omarchy shell
(quickshell config + plugins) shells out to.

Statically scans the shell source and installed plugins for
`command: [...]` process invocations and `bash -c "..."` strings,
resolves each command's owning package, and reports which of those
are foreign to the official repos (pacman -Qm) - i.e. AUR, on a
stock Omarchy/Arch system. Commands not currently installed are
best-effort guessed by matching the command name to a package name
via `pacman -Si` / an AUR helper's `-Si`; this is a name-match guess,
not real dependency resolution.

Options:
  -v          also print official-repo and unresolved commands
  -h, --help  show this help
EOF
    exit 0
    ;;
esac

verbose=0
[ "${1:-}" = "-v" ] && verbose=1

SCAN_DIRS=(/usr/share/omarchy/shell)
[ -d "$HOME/.config/omarchy/plugins" ] && SCAN_DIRS+=("$HOME/.config/omarchy/plugins")

tmp_cmds=$(mktemp)
trap 'rm -f "$tmp_cmds"' EXIT

# 1) command: ["binary", ...]
grep -rhoE 'command\s*:\s*\[\s*"[^"]+"' "${SCAN_DIRS[@]}" 2>/dev/null \
  | sed -E 's/command\s*:\s*\[\s*"([^"]+)"/\1/' >> "$tmp_cmds"

# 2) bash -c "binary ..." / bash -lc "binary ..."
grep -rhoE '"-c"\s*,\s*"[^"]+"|"-lc"\s*,\s*"[^"]+"' "${SCAN_DIRS[@]}" 2>/dev/null \
  | sed -E 's/.*,\s*"([^"]+)"/\1/' | awk '{print $1}' >> "$tmp_cmds"

# de-noise: drop shell keywords/operators/empty tokens picked up from -c strings
sort -u "$tmp_cmds" | grep -vE '^(if|then|else|elif|fi|do|done|while|for|case|esac|function|return|exit|:|\[\[|\]\]|\{|\}|\$\(.*|.*=.*)$' > "${tmp_cmds}.clean"

declare -A pkg_of_cmd=()
declare -a aur_pkgs=()
declare -a official_pkgs=()
declare -a unresolved_cmds=()

AUR_HELPER=$(command -v yay || command -v paru || true)

while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue

  # Installed and on PATH: definitive answer via the file that owns it.
  if path=$(command -v "$cmd" 2>/dev/null); then
    if pkg=$(pacman -Qoq "$path" 2>/dev/null); then
      pkg_of_cmd["$cmd"]="$pkg"
      if pacman -Qmq "$pkg" &>/dev/null; then
        aur_pkgs+=("$pkg ($cmd)")
      else
        official_pkgs+=("$pkg ($cmd)")
      fi
      continue
    fi
  fi

  # Not installed: best-effort guess by matching the command name to a
  # package name (works for the common case where binary == package name;
  # not a real dependency resolution).
  if pacman -Si "$cmd" &>/dev/null; then
    official_pkgs+=("$cmd (not installed, guessed by name)")
  elif [ -n "$AUR_HELPER" ] && "$AUR_HELPER" -Si "$cmd" &>/dev/null; then
    aur_pkgs+=("$cmd (not installed, guessed by name — AUR)")
  else
    unresolved_cmds+=("$cmd")
  fi
done < "${tmp_cmds}.clean"
rm -f "${tmp_cmds}.clean"

echo "AUR (foreign) packages providing commands the Omarchy shell launches:"
if [ "${#aur_pkgs[@]}" -eq 0 ]; then
  echo "  (none found — every resolvable command comes from an official repo)"
else
  printf '  %s\n' "${aur_pkgs[@]}" | sort -u
fi

if [ "$verbose" -eq 1 ]; then
  echo
  echo "Official-repo packages (for reference):"
  printf '  %s\n' "${official_pkgs[@]}" | sort -u
  echo
  echo "Unresolved (not on PATH right now, or a false positive from the scan):"
  printf '  %s\n' "${unresolved_cmds[@]}" | sort -u
fi
