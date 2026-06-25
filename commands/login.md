---
description: Verify this session is connected to Heroboard
---
Verify the Heroboard connection.

1. Call the heroboard MCP tool `list_projects`.
2. If it returns projects → confirm "✅ Connected to Heroboard" and list them. Mention that effort heartbeats (Monkey on prompts, Agent on edits) are active and cost no tokens.
3. If it returns 401 / auth error → the API key is missing, wrong, or revoked. Tell me to set it: the plugin asks for the key when enabled (Claude Code stores it securely in the keychain — no env var, no file). To (re)enter it, re-enable the plugin or update its config via `/plugin`. Get a key in Heroboard → Settings → MCP → "+ New key". Never paste the key into the chat.
