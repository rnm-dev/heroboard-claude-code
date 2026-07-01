#!/usr/bin/env bash
# Heroboard effort heartbeat (HB-220/221/222). Fire-and-forget: never blocks the prompt, never
# errors the hook, costs zero tokens (plain HTTP, no model call). Two modes on the one universal
# envelope (HB-367), selected by $1:
#   (no arg) — human-presence beat, fired by UserPromptSubmit. type:"presence", no initiator.
#   "agent"  — AI-work beat, fired by PostToolUse on every model tool-use. Adds initiator:"agent"
#              so the server credits the separate AI track (Phase 2 — restores what HB-368 dropped;
#              HB-356/HB-368 had made the plugin human-presence-only).
# The API key comes from the keyfile written by /heroboard:login (see _key.sh, HB-413/HB-468) — the
# plugin ships no userConfig, so nothing is prompted at install. No key → silent no-op here on
# purpose: this fires on every prompt/edit, so the loud "not signed in" nudge lives once at
# SessionStart (presence-ticker.sh) instead of spamming it per event (HB-248).
. "$(cd "$(dirname "$0")" && pwd)/_key.sh"
# Read the hook's stdin JSON once (see _key.sh): agent beats parse several fields out of it
# (session_id + tool + the file it touched) and a pipe can only be consumed once.
hb_capture_stdin
# Per-session id, used to namespace the activity marker and sent on every beat (HB-404) so the
# server can group a session. Concurrent sessions / shared-box OS users don't clobber each other.
HB_SID="$(hb_session_id)"
# Mode: "agent" (PostToolUse AI-work beat) vs human presence (UserPromptSubmit, the default).
case "${1:-}" in
  agent) MODE="agent"; HB_TAG="agent" ;;
  *)     MODE="presence"; HB_TAG="presence" ;;
esac
# Mark live human presence on every prompt — HUMAN beats only. The presence ticker reads this
# file's mtime and goes idle 5 min after the last human prompt (HB-269), so an open-but-idle
# session stops accruing. Agent beats must NOT touch it: an idle human with a working agent would
# otherwise keep accruing human presence via the ticker. Path matches presence-ticker.sh's ACTFILE.
[ "$MODE" = presence ] && touch "${TMPDIR:-/tmp}/heroboard${HB_SFX}-last-activity.${HB_SID}" 2>/dev/null
hb_log "fired (cwd=${CLAUDE_PROJECT_DIR:-$PWD} sid=${HB_SID})"
key="$(hb_resolve_key)"
[ -z "$key" ] && { hb_log "no-op: no key"; exit 0; }
# Repo of the working dir → the server maps it to a project so this time accrues to the right
# workspace (HB-250). git absent / not a repo → omit, server leaves the event unattributed.
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" config --get remote.origin.url 2>/dev/null)"
# host + plugin version drive the Settings "Claude Code connections" card (HB-302)
host="$(hb_host)"
ver="$(hb_plugin_version)"
# Contract (HB-385): every beat carries client="plugin" + clean-semver `v` (or `v` omitted).
# Logged explicitly so the lock is visible in the debug log; verified offline by scripts/smoke.sh.
hb_log "contract: client=plugin v=${ver:-<omitted>}"
# Agent beats describe the tool-use (HB-404): the tool name, the file it touched (entity_type=
# "file"), and whether it wrote. Parsed from the PostToolUse stdin captured above; file-path-only
# + sanitized so no command/URL text (where tokens live) and no JSON-breaking chars reach the wire.
# Presence beats carry none of this. is_write is true for the file-mutating tools.
tool=""; entity=""; is_write=""
if [ "$MODE" = agent ]; then
  tool="$(hb_json_str tool_name | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  entity="$(hb_json_str file_path)"; [ -z "$entity" ] && entity="$(hb_json_str notebook_path)"
  entity="$(hb_sanitize "$entity")"
  case "$tool" in Edit|Write|MultiEdit|NotebookEdit) is_write=true ;; *) is_write=false ;; esac
  hb_log "agent tool=${tool:-<none>} entity=${entity:-<none>} is_write=${is_write}"
fi
now="$(date +%s 2>/dev/null)"
# Universal heartbeat envelope (HB-367): type:"presence" bare ping, client="plugin", client-stamped
# time. Agent beats carry initiator:"agent" → server records them as the separate AI track ("code"),
# leaving humanMinutes untouched; human beats omit initiator (server defaults them to human).
payload="{\"type\":\"presence\",\"client\":\"plugin\""
[ -n "$HB_SID" ] && payload="${payload},\"session_id\":\"${HB_SID}\""
if [ "$MODE" = agent ]; then
  payload="${payload},\"initiator\":\"agent\""
  [ -n "$tool" ]     && payload="${payload},\"tool\":\"${tool}\""
  [ -n "$entity" ]   && payload="${payload},\"entity\":\"${entity}\",\"entity_type\":\"file\""
  [ -n "$is_write" ] && payload="${payload},\"is_write\":${is_write}"
fi
[ -n "$now" ]  && payload="${payload},\"time\":${now}"
[ -n "$repo" ] && payload="${payload},\"repo\":\"${repo}\""
[ -n "$host" ] && payload="${payload},\"host\":\"${host}\""
[ -n "$ver" ]  && payload="${payload},\"v\":\"${ver}\""
payload="${payload}}"
hb_log "POST ${MODE} repo=${repo:-<none>} host=${host:-<none>} v=${ver:-<none>}"
# Backgrounded so the hook never blocks the prompt; capture the HTTP status to the debug log.
( code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST "${HB_BASE}/api/heartbeat" \
    -H "X-Api-Key: ${key}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)
  hb_log "POST -> HTTP ${code:-000}" ) >/dev/null 2>&1 &
exit 0
