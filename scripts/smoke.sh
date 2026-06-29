#!/usr/bin/env bash
# Heartbeat contract smoke check (HB-385 / HB-404). Offline, no network, no deps beyond bash + grep.
#
# Locks the "Apps & Integrations" + "effort 2.0" contract the backend consumes. Every envelope must
# carry type:"presence", client:"plugin", session_id, and a CLEAN-semver `v` (or omit `v` — never a
# malformed value, which would break the server's semverLt compare). Agent-track beats additionally
# carry initiator:"agent", the tool name, the file touched (entity + entity_type:"file"), and
# is_write. This exercises the real parse/sanitize helpers from _key.sh on sample PostToolUse stdin,
# then rebuilds the payload the way scripts/heartbeat.sh does and asserts the shape.
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

# 2. Parse/sanitize helpers (HB-404). HB_STDIN is what hb_capture_stdin populates from the pipe;
#    set it directly here to a sample PostToolUse Edit payload.
SAMPLE_SID="sess-abc123"
SAMPLE_FILE="/Users/x/proj/src/app.ts"
HB_STDIN="{\"session_id\":\"${SAMPLE_SID}\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${SAMPLE_FILE}\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
check "hb_json_str pulls session_id"            '[ "$(hb_json_str session_id)" = "$SAMPLE_SID" ]'
check "hb_json_str pulls tool_name"             '[ "$(hb_json_str tool_name)" = "Edit" ]'
check "hb_json_str pulls nested file_path"       '[ "$(hb_json_str file_path)" = "$SAMPLE_FILE" ]'
check "hb_session_id reads stdin (not uid)"      '[ "$(hb_session_id)" = "$SAMPLE_SID" ]'
check "hb_sanitize strips quote/backslash"       '[ "$(hb_sanitize "a\"b\\c")" = "abc" ]'

# 3. Rebuild the payload exactly as heartbeat.sh does, off the captured HB_STDIN.
build() { # $1 = MODE (presence|agent)
  local sid tool entity is_write p
  sid="$(hb_session_id)"
  p="{\"type\":\"presence\",\"client\":\"plugin\""
  [ -n "$sid" ] && p="${p},\"session_id\":\"${sid}\""
  if [ "$1" = agent ]; then
    tool="$(hb_json_str tool_name | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
    entity="$(hb_sanitize "$(hb_json_str file_path)")"
    [ -z "$entity" ] && entity="$(hb_sanitize "$(hb_json_str notebook_path)")"
    case "$tool" in Edit|Write|MultiEdit|NotebookEdit) is_write=true ;; *) is_write=false ;; esac
    p="${p},\"initiator\":\"agent\""
    [ -n "$tool" ]   && p="${p},\"tool\":\"${tool}\""
    [ -n "$entity" ] && p="${p},\"entity\":\"${entity}\",\"entity_type\":\"file\""
    p="${p},\"is_write\":${is_write}"
  fi
  p="${p},\"time\":1700000000"
  [ -n "$ver" ] && p="${p},\"v\":\"${ver}\""
  p="${p}}"; printf '%s' "$p"
}
presence="$(build presence)"
agent="$(build agent)"

# presence beat: core envelope + session_id, no agent-only fields.
check "presence: type=presence"     'printf "%s" "$presence" | grep -q "\"type\":\"presence\""'
check "presence: client=plugin"     'printf "%s" "$presence" | grep -q "\"client\":\"plugin\""'
check "presence: has session_id"    'printf "%s" "$presence" | grep -q "\"session_id\":\"$SAMPLE_SID\""'
check "presence: v is clean semver" 'printf "%s" "$presence" | grep -Eq "\"v\":\"[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?\""'
check "presence: no initiator"      '! printf "%s" "$presence" | grep -q "initiator"'
check "presence: no tool field"     '! printf "%s" "$presence" | grep -q "\"tool\""'

# agent beat: everything presence has, plus initiator + tool + entity + entity_type + is_write.
check "agent: has session_id"       'printf "%s" "$agent" | grep -q "\"session_id\":\"$SAMPLE_SID\""'
check "agent: initiator=agent"      'printf "%s" "$agent" | grep -q "\"initiator\":\"agent\""'
check "agent: tool=Edit"            'printf "%s" "$agent" | grep -q "\"tool\":\"Edit\""'
check "agent: entity=file path"     'printf "%s" "$agent" | grep -q "\"entity\":\"$SAMPLE_FILE\""'
check "agent: entity_type=file"     'printf "%s" "$agent" | grep -q "\"entity_type\":\"file\""'
check "agent: is_write=true (Edit)" 'printf "%s" "$agent" | grep -q "\"is_write\":true"'

# 4. A non-file tool (Bash) → no entity, is_write false.
HB_STDIN="{\"session_id\":\"${SAMPLE_SID}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}"
bash_beat="$(build agent)"
check "agent(Bash): tool=Bash"       'printf "%s" "$bash_beat" | grep -q "\"tool\":\"Bash\""'
check "agent(Bash): no entity"       '! printf "%s" "$bash_beat" | grep -q "\"entity\""'
check "agent(Bash): is_write=false"  'printf "%s" "$bash_beat" | grep -q "\"is_write\":false"'

# 5. MCP headersHelper / browser-login unification (HB-413). Both run in a temp HOME so the real
#    keyfile is never touched. mcp-headers.sh resolves the SAME key the hooks use.
TMPH="$(mktemp -d)"; mkdir -p "$TMPH/.config/heroboard-plugin"
printf 'hb_live_smoke' > "$TMPH/.config/heroboard-plugin/key"
hdr_with="$(HOME="$TMPH" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_OPTION_api_key= bash "$HERE/mcp-headers.sh"; )"
hdr_none="$(HOME="$(mktemp -d)" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_OPTION_api_key= bash "$HERE/mcp-headers.sh"; echo "exit=$?")"
check "mcp-headers: emits X-Api-Key from keyfile" 'printf "%s" "$hdr_with" | grep -q "{\"X-Api-Key\":\"hb_live_smoke\"}"'
check "mcp-headers: no key -> {} + nonzero"        'printf "%s" "$hdr_none" | grep -q "^{}" && printf "%s" "$hdr_none" | grep -q "exit=1"'

# Login response parse (HB-413): the same flat grep login.sh uses pulls api_key + user_email.
LOGIN_BODY='{"result":"success","data":{"api_key":"hb_live_GRANTED","user_email":"a@b.co"}}'
lkey="$(printf '%s' "$LOGIN_BODY"   | grep -o '"api_key"[[:space:]]*:[[:space:]]*"[^"]*"'    | head -1 | cut -d'"' -f4)"
lmail="$(printf '%s' "$LOGIN_BODY"  | grep -o '"user_email"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
check "login parse: api_key"    '[ "$lkey" = "hb_live_GRANTED" ]'
check "login parse: user_email" '[ "$lmail" = "a@b.co" ]'

echo
if [ "$fails" -eq 0 ]; then echo "smoke: OK (v=$ver)"; exit 0; fi
echo "smoke: $fails check(s) FAILED"; exit 1
