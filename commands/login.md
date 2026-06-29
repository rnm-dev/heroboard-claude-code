---
description: Sign in to Heroboard via your browser (one approval authorizes MCP + effort hooks)
argument-hint: "[code]"
---
Sign the user in to Heroboard, then confirm the connection.

**If `$ARGUMENTS` is non-empty**, the user is pasting back a device code from the approval page —
exchange it directly (do NOT start a new browser flow):
- Run: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/login.sh" --code "$ARGUMENTS"` and relay its result.

**Otherwise**, run the browser flow:
1. Run and stream: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/login.sh"`
   It generates a one-time approval link, opens it in the browser (or prints it if it can't), and
   waits up to ~60s for the user to Approve. On success it stores the key so **both** the MCP tools
   and the effort heartbeats work from a single approval — no separate key-paste step.
2. **On success:** tell the user they're connected. If MCP tools aren't available yet this session,
   suggest `/reload-plugins` (or a new session). Then call the heroboard MCP tool `list_projects` to
   verify and list their projects, and mention effort heartbeats are now active and cost no tokens.
3. **On timeout / headless:** the script prints an approval link and asks for the **code** shown on
   the page. When the user pastes that code, re-invoke this command with it — i.e. run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/login.sh" --code "<the code>"`. Only the short **code** ever
   goes in chat — **never ask the user to paste their API key into this chat.**
