#!/usr/bin/env bash
# MCP auth headers helper (HB-413). Wired into .mcp.json as `headersHelper`: Claude Code runs this
# at MCP connect time and merges the JSON it prints to stdout into the request headers.
#
# Why this exists: a plugin can't set its userConfig programmatically, so a browser login
# (/heroboard:login → scripts/login.sh) can only write the key to the cache keyfile. By resolving
# the key here through the SAME hb_resolve_key (env → keyfile) the hooks use, one login authorizes
# both the effort hooks AND the MCP server — a single auth action — and agent-mode MCP no longer
# depends on userConfig reaching the server env.
#
# Contract (per CC docs): print a JSON object of string header pairs to stdout. No key → print an
# empty object and exit nonzero so the connection carries no bogus header (server then 401s cleanly).
HB_TAG="mcp-headers"
. "$(cd "$(dirname "$0")" && pwd)/_key.sh"
key="$(hb_resolve_key)"
if [ -z "$key" ]; then
  hb_log "no key — emitting empty headers"
  printf '{}\n'
  exit 1
fi
# key is an hb_… token (no quotes/backslashes), safe to inline in the hand-built JSON.
hb_log "emitting X-Api-Key header (len=${#key})"
printf '{"X-Api-Key":"%s"}\n' "$key"
exit 0
