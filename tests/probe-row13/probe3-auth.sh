#!/usr/bin/env bash
# probe3-auth.sh — v4 §Measure 3: "Per-worker HOME auth: one turn; MCP list =
# one entry; no connector tool".
#
# The policy under test, from claude-code/managed-settings.json:
#   "disableClaudeAiConnectors": true
#   "allowManagedMcpServersOnly": true
#   "allowedMcpServers": [ { "serverUrl": "http://127.0.0.1:3131/*" } ]
# managed-settings sits above every other settings level (AGENTS.md "Worker
# executors"), so nothing in the worker HOME can add a server or a connector.
#
# What "one entry" means HERE: the probe container has NO brain client
# configured (no `.claude.json` paste block — v4 §C: the renderer never writes
# one, and no client is minted for a probe). So the correct expectation in THIS
# container is an EMPTY MCP list plus no claude.ai connector. A non-empty list
# is a finding; a claude.ai connector is a failure of the policy.
# The `whoami` = the client half of §Measure 3 is NOT measurable here — it needs
# a minted brain client (owner action O3) — and is reported BLOCKED, not passed.
#
# Command shapes:
#   * `claude -p "query"` — cli-reference.md:17.
#   * `claude mcp` — cli-reference.md:37 "Configure Model Context Protocol (MCP)
#     servers"; `list` is its read subcommand and its raw output is recorded.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

guard_container

hr "claude mcp list in $PROBE_HOME"
run_logged "$PROBE_OUT_DIR/p3-mcp-list.txt" \
  docker exec -w "$PROBE_CWD" -e HOME="$PROBE_HOME" -e TERM=dumb "$PROBE_CONTAINER" claude mcp list
list_rc="$(logged_rc "$PROBE_OUT_DIR/p3-mcp-list.txt")"
say "exit=$list_rc"

hr "the model's own view: one turn"
run_logged "$PROBE_OUT_DIR/p3-turn.txt" \
  docker exec -w "$PROBE_CWD" -e HOME="$PROBE_HOME" -e TERM=dumb "$PROBE_CONTAINER" \
  claude -p 'list your MCP servers and tools by name. Print one name per line, nothing else. If you have no MCP servers, print exactly NONE.'
turn_rc="$(logged_rc "$PROBE_OUT_DIR/p3-turn.txt")"
say "exit=$turn_rc"

hr "raw settings the worker HOME carries (names only, never values)"
pexec sh -c 'for f in '"$PROBE_HOME"'/.claude.json '"$PROBE_HOME"'/.claude/settings.json; do
  if [ -f "$f" ]; then echo "== $f"; node -e "const o=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));console.log(Object.keys(o).sort().join(\",\"))" "$f"; else echo "== $f (absent)"; fi
done' 2>&1 || true

connector=no
grep -qiE 'claude\.ai|connector' "$PROBE_OUT_DIR/p3-mcp-list.txt" "$PROBE_OUT_DIR/p3-turn.txt" && connector=yes
empty=no
grep -qiE 'no mcp servers|^NONE$|No servers configured' "$PROBE_OUT_DIR/p3-mcp-list.txt" && empty=yes
grep -qE '^NONE' "$PROBE_OUT_DIR/p3-turn.txt" && model_none=yes || model_none=no

hr "classification"
say "claude.ai connector visible : $connector"
say "mcp list reports empty      : $empty"
say "model says NONE             : $model_none"
say "whoami = its own brain client: NOT MEASURABLE here (no client minted; owner action O3)"

if [ "$turn_rc" != "0" ] && [ "$list_rc" != "0" ]; then
  verdict 3 "BLOCKED (neither the CLI list nor the turn ran — see out/p3-*.txt)"
elif [ "$connector" = yes ]; then
  verdict 3 "FAIL (a claude.ai connector is visible despite disableClaudeAiConnectors)"
elif [ "$empty" = yes ] || [ "$model_none" = yes ]; then
  verdict 3 "PASS (no connector, MCP surface empty as expected for a probe HOME with no minted client)"
else
  verdict 3 "FAIL (MCP surface is neither empty nor the single allowed server — read out/p3-mcp-list.txt)"
fi
