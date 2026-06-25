#!/usr/bin/env bash
# Shared Heroboard API-key resolver (HB-252). Sourced by heartbeat.sh / presence-ticker.sh.
#
# The key lives in the plugin's userConfig → system keychain (HB-244). Claude Code exports
# it to hooks as CLAUDE_PLUGIN_OPTION_api_key — but ONLY in terminal CLI sessions. In
# agent-mode (the Claude desktop/web app) the userConfig key reaches the MCP server (via
# ${user_config.api_key} substitution) yet is NOT exported into hook env, so the shell hooks
# would silently no-op and Agent time wouldn't accrue.
#
# Bridge: a terminal session (which HAS the key in env) caches it to a dedicated config file
# (0600); agent-mode sessions, lacking the env var, fall back to reading that file. The
# plaintext key on disk is the deliberate trade-off for app-session effort tracking. Best-effort
# throughout: a hook must never block or fail, so every fs op is guarded and silent.
HB_CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/heroboard-plugin"
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

# Print the resolved key (empty if none). Side effect: when the env key is present, cache it.
hb_resolve_key() {
  local k="${CLAUDE_PLUGIN_OPTION_api_key:-}"
  if [ -n "$k" ]; then
    # cache for env-less (agent-mode) sessions, only when changed, perms locked to the user
    if [ "$(cat "$HB_KEYFILE" 2>/dev/null)" != "$k" ]; then
      mkdir -p "$(dirname "$HB_KEYFILE")" 2>/dev/null && ( umask 177; printf '%s' "$k" > "$HB_KEYFILE" ) 2>/dev/null
    fi
    hb_log "key resolved from env (len=${#k})"
    printf '%s' "$k"
    return 0
  fi
  local fk; fk="$(cat "$HB_KEYFILE" 2>/dev/null)"
  if [ -n "$fk" ]; then hb_log "key resolved from file (len=${#fk})"; else hb_log "NO key (env empty, no keyfile)"; fi
  printf '%s' "$fk"
}

# Stable per-session id, for namespacing the /tmp state files (presence pid + activity
# marker). Without it those paths are machine-global and collide: two concurrent sessions
# fight over one pid file — each SessionStart kills the other's ticker, so continuous time
# collapses onto whichever started last — and on a shared Linux box where /tmp is world-shared,
# one OS user's idle ticker reads another's activity mtime and accrues time off their presence.
# Claude Code exposes NO session env var, so we parse session_id out of the hook's stdin JSON;
# it's present on every hook event and constant for the life of a session. Floor to the OS uid
# so that even with no stdin we still never share a path across users. Consumes stdin AT MOST
# ONCE (skipped on a TTY so a manual run can't hang) — call it before anything else reads stdin.
hb_session_id() {
  local sid=""
  if [ ! -t 0 ]; then
    sid="$(cat 2>/dev/null | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
  fi
  [ -z "$sid" ] && sid="u$(id -u 2>/dev/null || echo 0)"
  printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-'
}
