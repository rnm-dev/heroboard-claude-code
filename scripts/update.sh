#!/usr/bin/env bash
# /heroboard:update (HB-470) — report the installed vs latest published plugin version and how to
# upgrade. The actual update is Claude Code's own /plugin command; this only checks and points at it.
# Pure bash, best-effort (no node/jq); same GitHub-raw source as the presence-ticker daily nudge.
HB_TAG="update"
. "$(cd "$(dirname "$0")" && pwd)/_key.sh"

RAW_URL="${HEROBOARD_UPDATE_URL:-https://raw.githubusercontent.com/rnm-dev/heroboard-claude-code/main/.claude-plugin/plugin.json}"
installed="$(hb_plugin_version)"                       # local plugin.json, clean semver (_key.sh)
latest="$(curl -fsS -m 5 "$RAW_URL" 2>/dev/null | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
hb_log "update check installed=${installed:-?} latest=${latest:-?}"

printf 'Installed: %s\n' "${installed:-unknown}"
if [ -z "$latest" ]; then
  printf 'Latest:    unknown (could not reach GitHub)\n'
  printf 'To update anyway, run:\n  /plugin update heroboard@heroboard\n  /reload-plugins\n'
  exit 0
fi
printf 'Latest:    %s\n' "$latest"

if [ "$installed" = "$latest" ]; then
  printf '\n✅ Up to date.\n'; exit 0
fi
# sort -V picks the higher semver (same compare as the nudge); bails gracefully if unavailable.
hi="$(printf '%s\n%s\n' "$installed" "$latest" | sort -V 2>/dev/null | tail -n1)"
if [ "$hi" = "$latest" ] && [ "$installed" != "$latest" ]; then
  printf '\n⬆️  Update available (%s → %s). To upgrade, run:\n  /plugin update heroboard@heroboard\n  /reload-plugins\n' "$installed" "$latest"
else
  printf '\nℹ️  Installed version is ahead of published (dev build) — nothing to update.\n'
fi
exit 0
