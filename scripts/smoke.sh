#!/usr/bin/env bash
# Heartbeat contract smoke check (HB-385). Offline, no network, no deps beyond bash + grep.
#
# Locks the "Apps & Integrations" contract the backend consumes: every heartbeat envelope must
# carry type:"presence", client:"plugin", and a CLEAN-semver `v` (or omit `v` entirely — never a
# malformed value, which would break the server's semverLt outdated-compare). The agent-track beat
# additionally carries initiator:"agent". This rebuilds the payload the way scripts/heartbeat.sh
# does and asserts the shape, plus checks hb_plugin_version's clean-semver guarantee directly.
#
# Run: bash scripts/smoke.sh   → prints PASS/FAIL per check; exit 0 all-green, exit 1 on any fail.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# hb_plugin_version resolves relative to CLAUDE_PLUGIN_ROOT (the hook env var), so point it at the repo.
export CLAUDE_PLUGIN_ROOT="$ROOT"
. "$HERE/_key.sh"

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$'
fails=0
ok()   { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# 1. hb_plugin_version returns clean semver matching plugin.json's version field.
ver="$(hb_plugin_version)"
pj="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$ROOT/.claude-plugin/plugin.json" | head -1 | cut -d'"' -f4)"
check "hb_plugin_version is clean semver"        'printf "%s" "$ver" | grep -Eq "$SEMVER_RE"'
check "hb_plugin_version == plugin.json version"  '[ "$ver" = "$pj" ]'

# 2. Build the presence (human) payload exactly as heartbeat.sh does and assert the contract fields.
build() { # $1 = MODE (presence|agent)
  local p="{\"type\":\"presence\",\"client\":\"plugin\""
  [ "$1" = agent ] && p="${p},\"initiator\":\"agent\""
  p="${p},\"time\":1700000000"
  [ -n "$ver" ] && p="${p},\"v\":\"${ver}\""
  p="${p}}"; printf '%s' "$p"
}
presence="$(build presence)"
agent="$(build agent)"

check "presence: type=presence"   'printf "%s" "$presence" | grep -q "\"type\":\"presence\""'
check "presence: client=plugin"   'printf "%s" "$presence" | grep -q "\"client\":\"plugin\""'
check "presence: v is clean semver" 'printf "%s" "$presence" | grep -Eq "\"v\":\"[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?\""'
check "presence: no initiator"    '! printf "%s" "$presence" | grep -q "initiator"'

# 3. The agent-track beat is identical plus initiator:"agent".
check "agent: client=plugin"      'printf "%s" "$agent" | grep -q "\"client\":\"plugin\""'
check "agent: initiator=agent"    'printf "%s" "$agent" | grep -q "\"initiator\":\"agent\""'

echo
if [ "$fails" -eq 0 ]; then echo "smoke: OK (v=$ver)"; exit 0; fi
echo "smoke: $fails check(s) FAILED"; exit 1
