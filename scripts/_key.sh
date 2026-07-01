#!/usr/bin/env bash
# Shared Heroboard API-key resolver (HB-252/HB-413/HB-468). Sourced by every plugin script.
#
# The key's single source of truth is the keyfile ~/.config/heroboard-plugin/key, written by the
# browser login (/heroboard:login → login.sh via hb_write_key). Both the effort hooks (here) and
# the MCP server (scripts/mcp-headers.sh, a headersHelper) read it, so ONE sign-in authorizes both.
# The plugin ships NO userConfig, so install prompts for nothing (HB-468). CLAUDE_PLUGIN_OPTION_api_key
# is still honored as a manual/legacy env override, and when present is cached to the keyfile too.
# Plaintext key on disk (0600) is the deliberate trade-off. Best-effort throughout: a hook must
# never block or fail, so every fs op is guarded and silent.
# --- instance environment (one knob drives everything) ------------------------------------------
# `HB_ENV` is the single variable that distinguishes this install: it derives the backend URL, the
# /tmp + config namespace, and the key source. Default is prod, so the PUBLISHED plugin behaves
# exactly as before (no env.conf shipped → no dev anything). A local dev copy run via
# `claude --plugin-dir` drops a sibling `scripts/env.conf` (gitignored, never published) setting
# HB_ENV=dev + HB_BASE + HB_KEY_OVERRIDE — so prod and a dev copy can run side by side without
# clobbering each other's tickers, key cache, or config dir.
HB_ENV="prod"
HB_BASE="https://heroboard.app"
HB_KEY_OVERRIDE=""
# $0 is the sourcing script (heartbeat.sh / presence-ticker.sh), which lives in this same dir —
# the same pattern those scripts use to locate _key.sh, so env.conf sits right next to them.
__hb_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$__hb_dir" ] && [ -f "$__hb_dir/env.conf" ] && . "$__hb_dir/env.conf"
# Namespace suffix: empty for prod (paths unchanged), "-<env>" otherwise (isolated state + config).
HB_SFX=""; [ "$HB_ENV" != "prod" ] && HB_SFX="-${HB_ENV}"

HB_CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/heroboard-plugin${HB_SFX}"
HB_KEYFILE="$HB_CONFDIR/key"

# Opt-in debug log (HB-258): hooks are otherwise invisible — you can't tell if they fire,
# resolve a key, or what the server replies. Enable by `export HEROBOARD_DEBUG=1` OR by
# `touch ~/.config/heroboard-plugin/debug`, then tail ~/.config/heroboard-plugin/debug.log.
# Off by default, best-effort, never fails the hook. Logs never contain the key itself.
HB_LOGFILE="$HB_CONFDIR/debug.log"
HB_LOGMAX=1048576  # 1 MiB — rotate one generation so an always-on debug log can't grow unbounded
hb_log() {
  case "${HEROBOARD_DEBUG:-}" in
    1|true|on|yes) ;;
    *) [ -f "$HB_CONFDIR/debug" ] || return 0 ;;
  esac
  mkdir -p "$HB_CONFDIR" 2>/dev/null
  # Best-effort rotation: at >HB_LOGMAX roll debug.log → debug.log.1 (one kept) and start
  # fresh, so leaving debug on for days caps disk at ~2x HB_LOGMAX. stat is GNU/BSD-portable;
  # any failure (no stat, odd size) is swallowed so logging never breaks the hook.
  local sz; sz="$(stat -c %s "$HB_LOGFILE" 2>/dev/null || stat -f %z "$HB_LOGFILE" 2>/dev/null || echo 0)"
  [ "${sz:-0}" -gt "$HB_LOGMAX" ] 2>/dev/null && mv -f "$HB_LOGFILE" "$HB_LOGFILE.1" 2>/dev/null
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${HB_TAG:-hook}" "$*" >> "$HB_LOGFILE" 2>/dev/null
}

# Write the API key to the cache keyfile, 0600, only when changed (HB-413). One locked-write path,
# reused by hb_resolve_key (env → cache, for agent-mode hooks) and the browser login
# (scripts/login.sh). Best-effort + silent — never fail a caller. Returns nonzero on empty input.
hb_write_key() {
  [ -n "$1" ] || return 1
  [ "$(cat "$HB_KEYFILE" 2>/dev/null)" = "$1" ] && return 0
  mkdir -p "$(dirname "$HB_KEYFILE")" 2>/dev/null && ( umask 177; printf '%s' "$1" > "$HB_KEYFILE" ) 2>/dev/null
}

# Print the resolved key (empty if none). Side effect: when the env key is present, cache it.
# Resolution order: env.conf override (dev copy) → CLAUDE_PLUGIN_OPTION_api_key (legacy/manual env
# override) → the login-written keyfile (the normal path, HB-413). This same helper backs the MCP
# headersHelper (scripts/mcp-headers.sh), so MCP and the hooks authenticate from one source.
hb_resolve_key() {
  # Dev copies (run via --plugin-dir, which has no userConfig) pin the key in env.conf so the
  # scripts don't fall back to the prod-cached keyfile and 401 against the dev backend.
  if [ -n "$HB_KEY_OVERRIDE" ]; then hb_log "key from env.conf override (len=${#HB_KEY_OVERRIDE})"; printf '%s' "$HB_KEY_OVERRIDE"; return 0; fi
  local k="${CLAUDE_PLUGIN_OPTION_api_key:-}"
  if [ -n "$k" ]; then
    hb_write_key "$k"   # cache for env-less (agent-mode) sessions, only when changed, perms 0600
    hb_log "key resolved from env (len=${#k})"
    printf '%s' "$k"
    return 0
  fi
  local fk; fk="$(cat "$HB_KEYFILE" 2>/dev/null)"
  if [ -n "$fk" ]; then hb_log "key resolved from file (len=${#fk})"; else hb_log "NO key (env empty, no keyfile)"; fi
  printf '%s' "$fk"
}

# Open a URL in the user's default browser, cross-platform (HB-413/HB-469). Returns nonzero when a
# browser can't reach THIS user — an SSH session (a browser opened on the far end is useless) or a
# headless Linux box/container with no display — so the caller falls back to the link + paste-back
# code instead of falsely reporting "Opened". Key fix (HB-469): gate on the ENVIRONMENT, not merely
# on an opener binary existing (xdg-open is often present with no display). Backgrounded + silenced
# so a slow/hanging opener can't block the login.
hb_open_url() {
  [ -n "$1" ] || return 1
  # Remote shell → opening a browser here won't reach the user. Treat as headless.
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ] && return 1
  # WSL / Windows reach the Windows browser with no X server needed.
  if command -v cmd.exe        >/dev/null 2>&1; then ( cmd.exe /c start "" "$1" >/dev/null 2>&1 & ); return 0; fi
  if command -v powershell.exe >/dev/null 2>&1; then ( powershell.exe -NoProfile Start-Process "$1" >/dev/null 2>&1 & ); return 0; fi
  # macOS.
  if [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v open >/dev/null 2>&1; then ( open "$1" >/dev/null 2>&1 & ); return 0; fi
  # Linux/BSD need a display server; without one it's headless.
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then ( xdg-open "$1" >/dev/null 2>&1 & ); return 0; fi
  return 1
}

# --- hook stdin JSON, read ONCE (HB-404) -------------------------------------------------------
# A pipe can only be consumed once, but agent beats need SEVERAL fields out of the PostToolUse
# payload (session_id + tool_name + the file it touched). So we capture the whole stdin JSON into
# HB_STDIN one time and parse fields from that string. Skipped on a TTY so a manual run can't hang.
# Call hb_capture_stdin in the TOP-LEVEL shell (not a subshell) before anything that needs a field
# — command substitutions then inherit HB_STDIN. hb_session_id / hb_json_str read HB_STDIN, never
# stdin, so they can be called as many times as needed.
HB_STDIN=""
hb_capture_stdin() {
  [ -t 0 ] && return 0
  HB_STDIN="$(cat 2>/dev/null)"
}

# Flat best-effort extract of a JSON string field by key from HB_STDIN — no jq on the user's box.
# Returns the FIRST match's value: Claude Code emits tool_name/file_path ahead of the bulky string
# fields (old_string/content), so the first hit is the real top-level one even on a flat scan.
hb_json_str() {
  printf '%s' "$HB_STDIN" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# Sanitize a value before it goes into the hand-built JSON payload (HB-404): strip control chars
# and the two characters that would break the JSON or inject into it (" and \), then truncate. We
# only ever send file PATHS as `entity` (never command/URL text, where tokens hide), so this plus
# the file-path-only rule keeps secrets off the wire while guaranteeing the payload stays valid JSON.
hb_sanitize() {
  printf '%s' "$1" | tr -d '\000-\037"\\' | cut -c1-256
}

# Stable per-session id, sent on every beat (HB-404, groups a session server-side) and used to
# namespace the /tmp state files (presence pid + activity marker). Without it those paths are
# machine-global and collide: two concurrent sessions fight over one pid file — each SessionStart
# kills the other's ticker, so continuous time collapses onto whichever started last — and on a
# shared Linux box where /tmp is world-shared, one OS user's idle ticker reads another's activity
# mtime and accrues time off their presence. Claude Code exposes NO session env var, so we parse
# session_id out of the hook's stdin JSON (captured by hb_capture_stdin); it's present on every
# hook event and constant for the session. Floor to the OS uid so even with no stdin we never
# share a path across users.
hb_session_id() {
  local sid; sid="$(hb_json_str session_id)"
  [ -z "$sid" ] && sid="u$(id -u 2>/dev/null || echo 0)"
  printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-'
}

# Machine name — identifies this Claude Code in the Settings connections card (HB-302).
hb_host() {
  printf '%s' "$(hostname 2>/dev/null || echo unknown)" | tr -cd 'A-Za-z0-9._-' | cut -c1-80
}

# Installed plugin version, parsed from the plugin's own plugin.json (HB-302). Reported on
# heartbeat as `v` so the server can flag machines running an outdated plugin.
#
# CONTRACT (HB-385): this function is the single guarantee that `v` is a CLEAN semver string
# or nothing at all — never garbage. The backend's `semverLt` outdated-compare breaks on a
# malformed value, so we validate the parsed field and emit empty (callers then omit `v`) if
# it isn't plain semver. Clean > wrong: an omitted `v` just skips the compare; a poisoned one
# would mis-flag the machine.
hb_plugin_version() {
  local f="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
  [ -f "$f" ] || return 0
  local v; v="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | cut -d'"' -f4)"
  # Strict semver: MAJOR.MINOR.PATCH with an optional pre-release/build suffix. Anything else
  # (empty, "vX.y", trailing junk) → log once and emit nothing so `v` is omitted, not poisoned.
  if printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$'; then
    printf '%s' "$v"
  else
    [ -n "$v" ] && hb_log "plugin version '$v' is not clean semver — omitting v (HB-385)"
  fi
}
