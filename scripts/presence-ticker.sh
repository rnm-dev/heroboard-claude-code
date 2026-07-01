#!/usr/bin/env bash
# Continuous presence heartbeat (HB-235). Backgrounds a loop that pings Heroboard every
# ~60s while the session is ACTIVE — i.e. you submitted a prompt within the last 5 min
# (HB-269) — so effort tracks live human presence, not just an open window. Tool-use alone
# no longer keeps it alive, so an idle/overnight session stops accruing. 0 tokens.
#
# ON BY DEFAULT (HB-247/HB-468): the plugin ships with NO userConfig (zero prompts at install —
# auth is entirely /heroboard:login), so this is env-gated. Set HEROBOARD_PRESENCE_TICKER=0 to
# count only per-prompt events. A legacy CLAUDE_PLUGIN_OPTION_presence_ticker env is still honored
# if present. Default is on, so continuous time accrues with no setup.
#
# Lifecycle: SessionStart → start, SessionEnd → stop (via PID file). A hard 12h cap means
# even an orphaned loop dies on its own.
. "$(cd "$(dirname "$0")" && pwd)/_key.sh"  # hb_resolve_key (key, HB-252) + hb_log (HB-258) + hb_session_id
# Read the hook's stdin JSON once (see _key.sh) so hb_session_id can parse session_id from it.
hb_capture_stdin
# Per-session id: namespaces both state files (each concurrent session runs its own correctly-
# attributed ticker; OS users sharing /tmp never collide) and is sent on every beat (HB-404).
HB_SID="$(hb_session_id)"
PIDFILE="${TMPDIR:-/tmp}/heroboard${HB_SFX}-presence.${HB_SID}.pid"
ACTFILE="${TMPDIR:-/tmp}/heroboard${HB_SFX}-last-activity.${HB_SID}"  # mtime bumped by heartbeat.sh on prompts (HB-269); path must match heartbeat's
IDLE_MAX=300  # stop accruing 5 min after the last human prompt
HB_TAG="presence"

# --- update nudge (plugin-only, GitHub raw) ----------------------------------
# Updates are pull-based and there's no built-in "update available" alert for third-party
# marketplaces, so we surface one ourselves: once/day, compare the installed version against
# the version published on the marketplace repo and, if newer, print a one-line systemMessage
# at SessionStart with the upgrade commands. Pure bash (no node/jq on the user's box),
# best-effort, throttled — bounded by a 2s curl only on check days, instant (file read) otherwise.
UPD_CACHE="$HB_CONFDIR/update-check"            # one line: "<epoch> <latest-version>"
UPD_INTERVAL=86400                              # re-check at most once per day
UPD_RAW_URL="${HEROBOARD_UPDATE_URL:-https://raw.githubusercontent.com/rnm-dev/heroboard-claude-code/main/.claude-plugin/plugin.json}"

hb_pjson_version() { grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null | head -1 | cut -d'"' -f4; }

# true iff $1 is a strictly higher semver than $2 (via sort -V; bails quietly if unavailable,
# so a box without GNU/BSD sort -V just never nudges rather than nudging wrongly).
hb_version_gt() {
  [ "$1" = "$2" ] && return 1
  local hi; hi="$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | tail -n1)"
  [ -n "$hi" ] && [ "$hi" = "$1" ]
}

hb_update_nudge() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 0
  local installed; installed="$(hb_pjson_version "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")"
  [ -n "$installed" ] || return 0
  local now last latest; now="$(date +%s)"; last=0; latest=""
  [ -f "$UPD_CACHE" ] && read -r last latest < "$UPD_CACHE" 2>/dev/null
  case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac   # corrupt cache → force a re-check
  if [ "$(( now - last ))" -ge "$UPD_INTERVAL" ]; then
    local fetched; fetched="$(curl -fsS -m 2 "$UPD_RAW_URL" 2>/dev/null | hb_pjson_version /dev/stdin)"
    [ -n "$fetched" ] && latest="$fetched"
    mkdir -p "$HB_CONFDIR" 2>/dev/null && printf '%s %s\n' "$now" "$latest" > "$UPD_CACHE" 2>/dev/null
  fi
  [ -n "$latest" ] || return 0
  if hb_version_gt "$latest" "$installed"; then
    hb_log "update available ($installed -> $latest)"
    printf '{"systemMessage":"Heroboard: plugin update available (%s → %s). Run  /plugin marketplace update heroboard , then  /plugin update heroboard@heroboard , then  /reload-plugins  to upgrade."}\n' "$installed" "$latest"
  fi
}

stop() {
  if [ -f "$PIDFILE" ]; then hb_log "stop (pid=$(cat "$PIDFILE" 2>/dev/null))"; kill "$(cat "$PIDFILE")" >/dev/null 2>&1; fi
  rm -f "$PIDFILE"
}

start() {
  key="$(hb_resolve_key)"
  # Required config: with no api_key NOTHING accrues — this ticker AND the per-prompt/-edit
  # heartbeat hooks all silently no-op. Claude Code lets the plugin be enabled without the
  # required key, so instead of doing nothing we surface a loud, non-blocking warning once
  # per session via the SessionStart hook's `systemMessage` (shown to the user; exit 0 never
  # blocks startup). SessionStart is the single warning surface — the heartbeat hook stays
  # quiet so the same notice isn't repeated on every prompt/edit (HB-248).
  if [ -z "$key" ]; then
    hb_log "no key — surfacing warning, ticker not started"
    printf '%s\n' '{"systemMessage":"Heroboard: not signed in — effort tracking & task tools are OFF. Run  /heroboard:login  to sign in with one browser approval (authorizes both the MCP tools and the effort hooks); headless/SSH falls back to a paste-back code. In the Claude app, run /heroboard:login in a terminal once so the hooks can read the key."}'
    exit 0
  fi
  # Nudge once/day if a newer version is published (best-effort; runs before the toggle gate so
  # the reminder still surfaces even when the continuous ticker is turned off).
  hb_update_nudge
  # presence ticker is default-on unless the toggle is explicitly falsey (HB-247)
  toggle="${CLAUDE_PLUGIN_OPTION_presence_ticker:-${CLAUDE_PLUGIN_OPTION_PRESENCE_TICKER:-${HEROBOARD_PRESENCE_TICKER:-1}}}"
  case "$(printf '%s' "$toggle" | tr '[:upper:]' '[:lower:]')" in
    0|false|off|no|"") hb_log "disabled by toggle ($toggle)"; exit 0 ;;
  esac
  # Repo of the session's working dir, captured once → the server maps it to a project so
  # presence time accrues to the right workspace (HB-250). Not a repo → unattributed.
  repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" config --get remote.origin.url 2>/dev/null)"
  # host + plugin version → Settings "Claude Code connections" card (HB-302)
  host="$(hb_host)"
  ver="$(hb_plugin_version)"
  # Universal heartbeat envelope (HB-367/HB-368): presence-only, client="plugin". The per-beat
  # `time` is stamped inside the loop below so each ~60s beat carries its own timestamp.
  payload_base="{\"type\":\"presence\",\"client\":\"plugin\""
  [ -n "$HB_SID" ] && payload_base="${payload_base},\"session_id\":\"${HB_SID}\""
  [ -n "$repo" ] && payload_base="${payload_base},\"repo\":\"${repo}\""
  [ -n "$host" ] && payload_base="${payload_base},\"host\":\"${host}\""
  [ -n "$ver" ]  && payload_base="${payload_base},\"v\":\"${ver}\""
  stop  # avoid duplicate loops
  hb_log "start (repo=${repo:-<none>})"
  ( i=0
    while [ "$i" -lt 720 ]; do            # 720 * 60s = 12h safety cap
      # Idle gate (HB-269): only accrue while a human prompted within IDLE_MAX. The activity
      # file's mtime is bumped by heartbeat.sh on UserPromptSubmit only; stat is GNU/BSD-portable.
      last="$(stat -c %Y "$ACTFILE" 2>/dev/null || stat -f %m "$ACTFILE" 2>/dev/null || echo 0)"
      if [ "$(( $(date +%s) - last ))" -gt "$IDLE_MAX" ]; then
        hb_log "tick $i -> idle, skip"
      else
        # stamp this beat's own time (HB-368); base envelope built once above
        code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST "${HB_BASE}/api/heartbeat" \
          -H "X-Api-Key: ${key}" -H "Content-Type: application/json" \
          -d "${payload_base},\"time\":$(date +%s)}")
        hb_log "tick $i -> HTTP ${code:-000}"
      fi
      i=$((i + 1)); sleep 60
    done
    rm -f "$PIDFILE" ) >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
esac
exit 0
