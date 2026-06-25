#!/usr/bin/env bash
# Heroboard presence heartbeat (HB-220/221/222; presence-only since HB-368). Fire-and-forget:
# never blocks the prompt, never errors the hook, costs zero tokens (plain HTTP, no model call).
# Fired by the UserPromptSubmit hook; emits one human-presence beat (universal envelope, HB-367).
# The API key comes from the plugin's userConfig → keychain (HB-244), exported to hooks as
# CLAUDE_PLUGIN_OPTION_api_key in terminal sessions; agent-mode (app) sessions fall back to the
# cached ~/.config/heroboard-plugin/key (see _key.sh, HB-252). No key → silent no-op here on
# purpose: this fires on every prompt/edit, so the loud "required config missing" warning lives
# once at SessionStart (presence-ticker.sh) instead of spamming it per event (HB-248).
. "$(cd "$(dirname "$0")" && pwd)/_key.sh"
# Per-session id (reads the hook's stdin JSON once, see _key.sh) so the activity marker is
# namespaced — concurrent sessions and shared-box OS users don't clobber each other's file.
HB_SID="$(hb_session_id)"
# Mark live human presence on every prompt. The presence ticker reads this file's mtime and goes
# idle 5 min after the last human prompt (HB-269), so an open-but-idle session stops accruing.
# Path must match presence-ticker.sh's ACTFILE for this session.
touch "${TMPDIR:-/tmp}/heroboard-last-activity.${HB_SID}" 2>/dev/null
HB_TAG="presence"
hb_log "fired (cwd=${CLAUDE_PROJECT_DIR:-$PWD} sid=${HB_SID})"
key="$(hb_resolve_key)"
[ -z "$key" ] && { hb_log "no-op: no key"; exit 0; }
# Repo of the working dir → the server maps it to a project so this time accrues to the right
# workspace (HB-250). git absent / not a repo → omit, server leaves the event unattributed.
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" config --get remote.origin.url 2>/dev/null)"
# host + plugin version drive the Settings "Claude Code connections" card (HB-302)
host="$(hb_host)"
ver="$(hb_plugin_version)"
now="$(date +%s 2>/dev/null)"
# Universal heartbeat envelope (HB-367/HB-368): presence-only, client="plugin", client-stamped time.
payload="{\"type\":\"presence\",\"client\":\"plugin\""
[ -n "$now" ]  && payload="${payload},\"time\":${now}"
[ -n "$repo" ] && payload="${payload},\"repo\":\"${repo}\""
[ -n "$host" ] && payload="${payload},\"host\":\"${host}\""
[ -n "$ver" ]  && payload="${payload},\"v\":\"${ver}\""
payload="${payload}}"
hb_log "POST presence repo=${repo:-<none>} host=${host:-<none>} v=${ver:-<none>}"
# Backgrounded so the hook never blocks the prompt; capture the HTTP status to the debug log.
( code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST "https://heroboard.app/api/heartbeat" \
    -H "X-Api-Key: ${key}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)
  hb_log "POST -> HTTP ${code:-000}" ) >/dev/null 2>&1 &
exit 0
