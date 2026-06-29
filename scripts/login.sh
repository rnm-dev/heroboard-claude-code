#!/usr/bin/env bash
# Browser login for the Heroboard plugin (HB-413). Mirrors the macOS desktop sign-in (HB-360):
# generate a desktop_hash, open the approval page in the browser, poll until the user approves,
# then store the minted key in the cache keyfile. Because the MCP server reads that same keyfile
# (scripts/mcp-headers.sh) and so do the effort hooks (hb_resolve_key), this single approval
# authorizes BOTH — no separate "paste key into /plugin" step.
#
# env-aware: HB_BASE comes from _key.sh (prod https://heroboard.app, or dev.heroboard.app for a dev
# copy via env.conf). Best-effort and chatty (unlike the silent heartbeat): login is user-initiated,
# so it reports clear success/failure. Never prints the key to stdout or the debug log.
HB_TAG="login"
. "$(cd "$(dirname "$0")" && pwd)/_key.sh"

POLL_MAX=60   # ~60s overall, 1s between polls (HB-360 contract)

# UUIDv4 desktop_hash. uuidgen (macOS + most Linux) → /proc (Linux) → /dev/urandom fallback.
hb_uuid() {
  local u
  if u="$(uuidgen 2>/dev/null)" && [ -n "$u" ]; then printf '%s' "$u" | tr 'A-Z' 'a-z'; return 0; fi
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; return 0; fi
  local h; h="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
  if [ "${#h}" -ge 32 ]; then
    printf '%s-%s-4%s-8%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"; return 0
  fi
  printf 'plugin-%s-%s\n' "$$" "$(date +%s 2>/dev/null)"   # last resort: still unique enough
}

hash="$(hb_uuid)"
confirm_url="${HB_BASE}/desktop/auth?desktop_hash=${hash}&client=plugin"
poll_url="${HB_BASE}/api/v1/desktop/auth_decisions/api_key?desktop_hash=${hash}"
hb_log "login start (base=${HB_BASE} hash=${hash})"

printf 'Heroboard login — approve this Claude Code session in your browser.\n'
if hb_open_url "$confirm_url"; then
  printf 'Opened: %s\n' "$confirm_url"
else
  printf 'Could not open a browser automatically. Open this URL to approve:\n  %s\n' "$confirm_url"
fi
printf 'Waiting for approval (up to %ss)…\n' "$POLL_MAX"

i=0
while [ "$i" -lt "$POLL_MAX" ]; do
  resp="$(curl -s -m 3 -w $'\n%{http_code}' "$poll_url" 2>/dev/null)"
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [ "$code" = "200" ] && printf '%s' "$body" | grep -q '"result"[[:space:]]*:[[:space:]]*"success"'; then
    key="$(printf '%s' "$body"   | grep -o '"api_key"[[:space:]]*:[[:space:]]*"[^"]*"'    | head -1 | cut -d'"' -f4)"
    email="$(printf '%s' "$body" | grep -o '"user_email"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
    if [ -z "$key" ]; then
      hb_log "approved but no api_key in body"
      printf '\n⚠️  Approved, but the server returned no API key. Try again, or paste a key manually (below).\n'
      break
    fi
    if hb_write_key "$key"; then
      hb_log "login ok (email=${email:-<none>}) key stored"
      printf '\n✅ Logged in%s. Key stored — MCP tools and effort heartbeats are now active.\n' \
        "${email:+ as $email}"
      printf 'If MCP tools are not connected yet, run  /reload-plugins  (or restart the session).\n'
      exit 0
    fi
    hb_log "login ok but keyfile write failed"
    printf '\n⚠️  Logged in, but could not write %s. Check permissions and retry.\n' "$HB_KEYFILE"
    exit 1
  fi
  i=$((i + 1)); sleep 1
done

# Timed out or could not finish → manual-paste fallback. Never ask for the key in chat.
hb_log "login timeout/refused after ${i}s"
printf '\n⏱  No approval received.\n'
printf 'Fallback — paste a key manually instead of the browser flow:\n'
printf '  1. Heroboard → Settings → MCP → “+ New key”.\n'
printf '  2. Set it via  /plugin → heroboard → Configure  (stored in your keychain; never paste it into this chat).\n'
exit 1
