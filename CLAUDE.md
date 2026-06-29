# CLAUDE.md

Guidance for working on the **Heroboard Claude Code plugin** in this repo.

## What this is
A Claude Code [plugin](https://code.claude.com/docs/en/plugins) that wires a session to
[Heroboard](https://heroboard.app). The repo root **is** the plugin, and it doubles as its own
single-plugin marketplace. There is no build step and no runtime dependencies beyond `bash`,
`curl`, and `git` — the effort hooks are pure shell so they add **zero tokens** and never call the
model.

Installed via `/plugin marketplace add rnm-dev/heroboard-claude-code` →
`/plugin install heroboard@heroboard`.

## Layout
```
.claude-plugin/
  plugin.json        # plugin manifest: name, version, userConfig (api_key, presence_ticker)
  marketplace.json   # one-plugin marketplace pointing at "./"
.mcp.json            # HTTP MCP server → heroboard.app, auth via headersHelper (scripts/mcp-headers.sh, HB-413)
hooks/hooks.json     # UserPromptSubmit / PostToolUse / SessionStart / SessionEnd → scripts
commands/*.md        # slash commands (/heroboard:login, :tasks, :task, :create, :status, :ship)
scripts/
  _key.sh            # sourced helper: key resolution+write, host/version, debug logging, per-session id, stdin parse/sanitize, browser opener
  heartbeat.sh       # per-prompt presence heartbeat
  presence-ticker.sh # backgrounded ~60s presence loop + once-a-day update nudge
  login.sh           # /heroboard:login browser sign-in (HB-413): desktop_hash → open approval page → poll → write keyfile
  mcp-headers.sh     # MCP headersHelper (HB-413): prints {"X-Api-Key":…} from hb_resolve_key so MCP + hooks share one key
  smoke.sh           # offline contract self-check (HB-385/404/413); no network/deps
```

## How effort tracking works
Two meters on one **universal heartbeat envelope** (HB-367): **human presence** and a separate
**AI track**. HB-356/HB-368 had stripped the plugin to presence-only; the AI track is back (Phase 2)
— agent beats carry `initiator:"agent"` and the server records them as `code` time (incrementing
`today.minutes` while `humanMinutes` reflects only human prompts). No backend change was needed.
- **`heartbeat.sh [agent]`** — fired by two hooks. No arg (`UserPromptSubmit`) → one **human
  presence** beat. `agent` (`PostToolUse`, matcher `*`) → one **AI-work** beat per model tool-use,
  same envelope plus `initiator:"agent"`. Fire-and-forget: 3s `curl` timeout, backgrounded, always
  `exit 0` so it can never block or fail a prompt. POSTs a JSON envelope to
  `https://heroboard.app/api/heartbeat`: `type:"presence"`, `client:"plugin"`, `session_id`
  (HB-404 — present on every beat so the server can group a session), a client-stamped `time`
  (epoch seconds), the working dir's `remote.origin.url` (`repo` attribution), and `host` + `v`
  (plugin version) for the Settings "Claude Code connections" card (HB-302). **Agent beats** also
  describe the tool-use (HB-404): `tool` (the tool name), and for file tools `entity` (the file
  path) + `entity_type:"file"` + `is_write` (`true` for Edit/Write/MultiEdit/NotebookEdit). Those
  fields are parsed from the `PostToolUse` stdin — captured once via `hb_capture_stdin` (a pipe
  reads once, but agent beats need several fields), **file-path-only and sanitized** (`hb_sanitize`)
  so command/URL text — where tokens hide — never reaches the wire and the hand-built JSON can't be
  broken. Only the human beat touches the activity file — agent tool-use must not keep the presence
  ticker alive.
  **Contract (HB-385):** every beat carries `client:"plugin"` and a clean-semver `v` (or omits `v`
  — never a malformed value, since the backend compares it with `semverLt`). The clean-semver
  guarantee lives in `hb_plugin_version` (`_key.sh`); `scripts/smoke.sh` verifies the whole envelope
  offline.
- **`presence-ticker.sh start|stop`** — started at `SessionStart`, stopped at `SessionEnd` via a
  PID file. While running it pings every 60s **only if** a human prompted within the last 5 min
  (it reads the mtime of an activity file that `heartbeat.sh` touches on prompts only). Hard 12h
  cap so an orphaned loop dies on its own. Default-on; gated by the `presence_ticker` userConfig
  toggle.
- **`_key.sh`** — shared, sourced by every script. Resolves the API key (`hb_resolve_key`) from
  env.conf override → `CLAUDE_PLUGIN_OPTION_api_key` (terminal sessions) → cached
  `~/.config/heroboard-plugin/key`, and caches the env key `0600` via `hb_write_key` so **agent-mode**
  (Claude app) sessions, which don't get the env var, can still read it. Also provides `hb_log`
  (opt-in debug log), `hb_session_id` (namespaces the `/tmp` state files), and `hb_open_url`
  (cross-platform browser opener for login).

## Authentication — one key, one sign-in (HB-413)
`/heroboard:login` (`scripts/login.sh`) is the primary path: generate a UUID `desktop_hash`, open
`${HB_BASE}/desktop/auth?desktop_hash=…&client=plugin`, poll
`${HB_BASE}/api/v1/desktop/auth_decisions/api_key?desktop_hash=…` (1s × 60; `200`+`result:"success"`
→ `{api_key,user_email}`), and write the key to the keyfile with `hb_write_key`. Mirrors the macOS
desktop flow (backend HB-360, resolved); env-aware so a dev copy logs in to `dev.heroboard.app`.
The **keyfile is the single source of truth**: the hooks read it via `hb_resolve_key`, and the MCP
server reads it too — `.mcp.json` uses `headersHelper: scripts/mcp-headers.sh`, which prints
`{"X-Api-Key":"<key>"}` from the same `hb_resolve_key`. So one browser approval authorizes **both**
MCP and heartbeats (no `/plugin` paste). `userConfig.api_key` stays as the `required:false` fallback;
a pasted key is cached into the keyfile by the next terminal session. **Never print the key** to
stdout or the debug log; manual paste must go through `/plugin`, never the chat.

### State files (all best-effort, guarded, silent)
- `${TMPDIR:-/tmp}/heroboard-presence.<sid>.pid` — presence loop PID
- `${TMPDIR:-/tmp}/heroboard-last-activity.<sid>` — mtime = last human prompt
- `~/.config/heroboard-plugin/key` — cached API key (agent-mode bridge)
- `~/.config/heroboard-plugin/update-check` — `<epoch> <latest-version>` throttle cache
- `~/.config/heroboard-plugin/debug.log` — only when debug is on (see below)

## Conventions when editing
- **Hooks must never break a session.** Every fs/network op is guarded with `2>/dev/null`, runs
  best-effort, and scripts `exit 0`. Keep it that way — a heartbeat is not worth a failed prompt.
- **No new runtime deps.** Assume only POSIX-ish `bash` + `curl` + `git`. No `node`/`jq` on the
  user's box (`grep`/`cut`/`sort -V` parse the small JSON the scripts need). The `.mcp.json`
  server does the heavy lifting; the shell only sends heartbeats.
- **The single user-facing warning surface is `SessionStart`** (presence-ticker), so a missing key
  is reported once, not on every prompt/edit. Don't add warnings to `heartbeat.sh`.
- **Comments reference Heroboard issue keys** (`HB-NNN`) explaining *why* — preserve that context
  when touching a line.
- **Repo-coupled URLs.** The update-nudge URL in `presence-ticker.sh` and the install/repository
  fields in `plugin.json` / `marketplace.json` / `README.md` all point at
  `rnm-dev/heroboard-claude-code`. Keep them in sync if the repo ever moves.

## Releasing
1. Bump `version` in **both** `.claude-plugin/plugin.json` and the matching entry in
   `.claude-plugin/marketplace.json` (they should always match).
2. `claude plugin validate .`
3. Commit + push to `main`. The once-a-day `SessionStart` nudge compares the installed version
   against `main`'s `plugin.json` and tells users to run
   `/plugin update heroboard@heroboard` + `/reload-plugins`.

## Debugging the hooks
Hooks are otherwise invisible. Enable logging with `export HEROBOARD_DEBUG=1` **or**
`touch ~/.config/heroboard-plugin/debug`, then `tail -f ~/.config/heroboard-plugin/debug.log`.
The log never contains the key itself and self-rotates at ~1 MiB.
