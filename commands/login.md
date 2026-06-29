---
description: Sign in to Heroboard via your browser (one approval authorizes MCP + effort hooks)
---
Sign the user in to Heroboard with the browser flow, then confirm the connection.

1. Run the login script and stream its output to the user:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/login.sh"`
   It generates a one-time approval link, opens it in the browser (or prints it if it can't), and
   waits up to ~60s for the user to approve. On success it stores the key so **both** the MCP tools
   and the effort heartbeats work from a single approval — no separate key-paste step.
2. If the script reports success: tell the user they're connected. If MCP tools aren't available yet
   this session, suggest `/reload-plugins` (or starting a new session) so the MCP server picks up the
   key. Then call the heroboard MCP tool `list_projects` to verify and list their projects, and
   mention that effort heartbeats are now active and cost no tokens.
3. If the script times out or fails: relay its fallback message. The manual fallback is Heroboard →
   Settings → MCP → "+ New key", set via `/plugin` → heroboard → Configure (stored in the keychain).
   **Never ask the user to paste their key into this chat.**
