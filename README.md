# Heroboard — Claude Code plugin

Connects your Claude Code session to [Heroboard](https://heroboard.app): task tools over
MCP, effort heartbeats that turn your terminal time into XP, and `/heroboard` commands.

This repository **is** the plugin and its own one-plugin
[marketplace](https://code.claude.com/docs/en/plugin-marketplaces) — install it directly from
GitHub, no separate marketplace repo needed.

## What you get
- **MCP task tools** — `list_projects`, `list_tasks`, `get_task`, `create_task`, `update_task`,
  `report_progress`, `create_epic`, `close_task`.
- **Effort heartbeats** (0 tokens — plain HTTP, no model call) — track your **human presence**:
  - every prompt → human time
  - a **continuous presence ticker** that keeps time accruing every ~60s while you're actively
    prompting (a prompt within the last 5 min), and goes idle automatically once you stop.
  - tracked time is **pure human hours**; a separate AI-effort track lands in a later phase.
- **Slash commands**: `/heroboard:login`, `/heroboard:tasks`, `/heroboard:task <KEY>`,
  `/heroboard:create <desc>`, `/heroboard:status`, `/heroboard:ship`.

## Install
```
/plugin marketplace add rnm-dev/heroboard-claude-code
/plugin install heroboard@heroboard
```
After install, sign in with **one browser approval**:
```
/heroboard:login
```
It opens a Heroboard approval page, waits for you to click **Approve**, and stores the key so a
**single** sign-in authorizes *both* the MCP tools and the effort hooks. No key to copy, no `export`,
no env var. (Requires Claude Code 2.1.143+.)

**Headless / SSH / another device?** If the browser can't open or the wait times out, the approval
page shows a short one-time **code** — copy it and run `/heroboard:login <code>` to finish. Only the
short code goes in chat, never your key. (Deepest fallback: paste a key via `/plugin` → heroboard →
Configure — get one in Heroboard → **Settings → MCP → "+ New key"**.)

One stored key powers both the MCP server and the effort hooks, the same on macOS / Linux / Windows
and in GUI editors (VSCode, JetBrains) — anywhere Claude Code runs.

### Updating
The plugin nudges you once a day at session start when a newer version is published. To update:
```
/plugin update heroboard@heroboard
/reload-plugins
```

### Auto-install for a whole team
Drop this in your repo's `.claude/settings.json` so anyone who trusts the project folder gets
prompted to install:
```json
{
  "extraKnownMarketplaces": {
    "heroboard": {
      "source": { "source": "github", "repo": "rnm-dev/heroboard-claude-code" }
    }
  },
  "enabledPlugins": {
    "heroboard@heroboard": true
  }
}
```

**How the key is stored.** `/heroboard:login` writes the key to `~/.config/heroboard-plugin/key`
(`0600`). Both the effort hooks and the MCP server read it from there — the MCP server via a
`headersHelper` script (`scripts/mcp-headers.sh`) that injects the `X-Api-Key` header at connect
time. That's why one sign-in covers everything. Delete that file to sign out.

**Agent-mode (Claude app) note.** Desktop/web *agent-mode* sessions don't export config into the
hook/MCP-helper shell env, so they rely on that keyfile. Run `/heroboard:login` (or the plugin) in a
terminal once after install; agent-mode sessions then read the cached key. A key pasted via `/plugin`
is likewise cached to the keyfile by your next terminal session.

To change the key later, run `/heroboard:login` again, or update the plugin's config via `/plugin`.

## Migrating from manual setup
If you previously added a `~/.claude/settings.json` heartbeat hook or `export HEROBOARD_API_KEY`,
remove them after installing — the plugin replaces both (and reads the key from the keychain).

## Notes
- Heartbeats are fire-and-forget (3s timeout, backgrounded) — never block or fail a prompt.
- No key set → heartbeats silently no-op; nothing breaks. The one-time "set your key" notice is
  surfaced at `SessionStart`.
- Continuous presence ticker is **on by default** — toggle it via the plugin's config (`/plugin`).
  It keeps effort accruing every ~60s while a session is **active** (you prompted within the last
  5 min), and goes idle automatically once you stop — so an open-but-idle session no longer accrues
  time.

## Local development
Test the plugin without the marketplace:
```
claude --plugin-dir .
```
Or test the marketplace end-to-end from a checkout:
```
/plugin marketplace add ./
/plugin install heroboard@heroboard
```
After editing while Claude Code is running: `/reload-plugins`.

Validate before pushing a release:
```
claude plugin validate .
```

## Versioning
Bump `version` in **both** [`.claude-plugin/plugin.json`](./.claude-plugin/plugin.json) and the
matching marketplace entry in [`.claude-plugin/marketplace.json`](./.claude-plugin/marketplace.json)
on every release, or users won't see the update. The plugin nudges users once a day at
`SessionStart` when the `version` published on `main` is newer than what they have installed.

## Reference
- [Claude Code plugins docs](https://code.claude.com/docs/en/plugins)
- [Plugin marketplaces docs](https://code.claude.com/docs/en/plugin-marketplaces)
- [Plugins reference](https://code.claude.com/docs/en/plugins-reference)
