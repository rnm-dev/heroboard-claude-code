#!/usr/bin/env bash
# Browser login for the Heroboard plugin (HB-413/HB-417). Two ways in, both ending in the same
# stored key (keyfile via hb_write_key) → MCP (headersHelper) + effort hooks live at once:
#   (no args)        auto path — generate a desktop_hash, open the approval page, poll until approved
#                    (mirrors the macOS desktop flow, backend HB-360).
#   --code <CODE>    paste-back path (HB-417) — exchange a one-time code shown on the approval page
#                    for the key. For headless/SSH, a poll timeout, or approving on another device.
#
# env-aware: HB_BASE comes from _key.sh (prod https://heroboard.app, or dev.heroboard.app for a dev
# copy via env.conf). Best-effort and chatty (login is user-initiated): clear success/failure. Never
# prints the key — and never the short code — to stdout or the debug log.
HB_TAG="login"
. "$(cd "$(dirname "$0")" && pwd)/_key.sh"

POLL_MAX=60   # ~60s overall, 1s between polls (HB-360 contract)

# Extract key+email from an exchange/poll response body (identical shape), store the key, report.
# Returns 0 when the key is stored, 1 otherwise. Shared by the auto-poll and --code paths so both
# land in the same authorized state with the same message. Never echoes the key.
hb_claim() {
  local body="$1" key email
  key="$(printf '%s' "$body"    | grep -o '"api_key"[[:space:]]*:[[:space:]]*"[^"]*"'    | head -1 | cut -d'"' -f4)"
  email="$(printf '%s' "$body"  | grep -o '"user_email"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
  if [ -z "$key" ]; then
    hb_log "approved but no api_key in body"
    printf '\n⚠️  Approved, but the server returned no API key. Try again.\n'
    return 1
  fi
  if hb_write_key "$key"; then
    hb_log "login ok (email=${email:-<none>}) key stored"
    printf '\n✅ Logged in%s. Key stored — MCP tools and effort heartbeats are now active.\n' \
      "${email:+ as $email}"
    printf 'If MCP tools are not connected yet, run  /reload-plugins  (or restart the session).\n'
    return 0
  fi
  hb_log "login ok but keyfile write failed"
  printf '\n⚠️  Logged in, but could not write %s. Check permissions and retry.\n' "$HB_KEYFILE"
  return 1
}

# --- paste-back: exchange a one-time code for the key (HB-417) ---------------------------------
if [ "${1:-}" = "--code" ] || [ "${1:-}" = "-c" ]; then
  # Sanitize: the code comes from chat — strip to the short-alphanumeric charset so it can't break
  # the hand-built JSON body or inject. Log only its length, never the code itself.
  code="$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9-')"
  if [ -z "$code" ]; then
    printf 'Usage: login.sh --code <CODE>   (the short code shown on the approval page)\n'
    exit 1
  fi
  hb_log "exchange code (len=${#code}) base=${HB_BASE}"
  resp="$(curl -s -m 5 -w $'\n%{http_code}' -X POST "${HB_BASE}/api/v1/desktop/auth_decisions/exchange" \
    -H 'Content-Type: application/json' -d "{\"code\":\"${code}\"}" 2>/dev/null)"
  status="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  hb_log "exchange -> HTTP ${status:-000}"
  case "$status" in
    200)
      if printf '%s' "$body" | grep -q '"result"[[:space:]]*:[[:space:]]*"success"'; then hb_claim "$body"; exit $?; fi
      printf '\n⚠️  Unexpected response from the server. Try  /heroboard:login  again.\n'; exit 1 ;;
    410) printf '\n⌛ That code was already used or has expired. Run  /heroboard:login  again for a fresh one.\n'; exit 1 ;;
    404) printf '\n⏳ Not approved yet. Approve on the page first, then re-run  /heroboard:login <code>.\n'; exit 1 ;;
    *)   printf '\n⚠️  Could not exchange the code (HTTP %s). Run  /heroboard:login  again.\n' "${status:-error}"; exit 1 ;;
  esac
fi

# --- auto path: desktop_hash → open approval page → poll --------------------------------------
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
  status="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [ "$status" = "200" ] && printf '%s' "$body" | grep -q '"result"[[:space:]]*:[[:space:]]*"success"'; then
    hb_claim "$body"; exit $?
  fi
  i=$((i + 1)); sleep 1
done

# Timed out → device-code paste-back fallback (HB-417). Approving the SAME confirm_url mints the
# code bound to this desktop_hash; the user copies it back. Never ask for the key itself in chat.
hb_log "login timeout after ${i}s — offering code paste-back"
printf '\n⏱  No approval received.\n'
printf 'Open this link on any device, sign in, and click Approve:\n  %s\n' "$confirm_url"
printf 'Then copy the code shown on the page and run:  /heroboard:login <code>\n'
printf '(Deepest fallback: set a key via  /plugin → heroboard → Configure  — never paste the key into this chat.)\n'
exit 1
