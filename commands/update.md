---
description: Check for a newer Heroboard plugin version and show how to update
---
Check whether the Heroboard plugin is up to date.

1. Run and relay: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/update.sh"`
   It prints the installed vs latest published version and whether an update is available.
2. If an update is available, tell the user to run `/plugin update heroboard@heroboard` then
   `/reload-plugins` — Claude Code performs the actual update; this command only checks and points
   the way. If already up to date, say so.
