#!/usr/bin/env bash
# probe4-negatives.sh — v4 §Measure 4: "Negatives: one client's worker agent
# spawned from another client's dispatcher, bare `claude`, foreign `cwd` and
# `resumeSessionId` → rejected, or accepted and sandbox-denied: record which."
#
# Here the neighbour stands in for the other client's worker: up.sh configures
# `claude-neighbour` as a full agent entry WITH its acpx alias, and deliberately
# leaves it out of `acp.allowedAgents`, which up.sh sets to ["claude-probe"].
# The gate under test is upstream's own: delivery.md, "OpenClaw still enforces
# ACP feature gates, allowed agents, session ownership, channel bindings, and
# Gateway delivery policy."
#
# Four negatives, each recorded verbatim:
#   N1 spawn claude-neighbour  -> not in acp.allowedAgents        -> expect reject
#   N2 spawn bare `claude`     -> not in acp.allowedAgents either -> expect reject
#   N3 spawn claude-probe --cwd /data/neighbour -> `cwd` is "validated by
#      backend/runtime policy" (sessions.md, param cwd) and that policy is
#      UNSPECIFIED upstream: accept-and-sandbox-deny is an allowed outcome, so
#      this one records WHICH.
#   N4 spawn with a bogus resumeSessionId -> delivery.md: "If the session id is
#      not found, the spawn fails with a clear error - no silent fallback to a
#      new session."
#
# Route: `/acp spawn ...` is a chat slash command (sessions.md "From /acp
# command"); the CLI path to a chat turn is `openclaw agent` (cli/agent.md:11
# "Run one agent turn through the Gateway"). resumeSessionId has no documented
# `/acp spawn` flag, so N4 goes through `sessions_spawn` phrased as a request —
# and if the gateway needs a model for that, the raw refusal is what gets
# recorded, not a guess.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REQUESTER_AGENT="${REQUESTER_AGENT:-main}"
guard_container

hr "allowedAgents as configured"
occ config get acp.allowedAgents 2>&1 || true

neg() { # neg <tag> <message>
  local tag="$1"; shift
  hr "$tag: $*"
  run_logged "$PROBE_OUT_DIR/p4-$tag.txt" occ agent --agent "$REQUESTER_AGENT" -m "$1" --timeout 120
  say "exit=$(logged_rc "$PROBE_OUT_DIR/p4-$tag.txt")"
}

neg n1 "/acp spawn claude-neighbour --mode oneshot --thread off --cwd $NEIGHBOUR_CWD"
neg n2 "/acp spawn claude --mode oneshot --thread off --cwd $PROBE_CWD"
neg n3 "/acp spawn claude-probe --mode oneshot --thread off --cwd $NEIGHBOUR_CWD"
neg n4 'Call sessions_spawn with exactly {"task":"print ok","runtime":"acp","agentId":"claude-probe","mode":"run","resumeSessionId":"row13-bogus-session-id-does-not-exist"} and print the tool result verbatim.'

classify() { # classify <tag> -> prints one line
  local tag="$1" f="$PROBE_OUT_DIR/p4-$1.txt" rc
  rc="$(logged_rc "$f")"
  if grep -qiE 'not allowed|not in .*allowedAgents|unknown agent|forbidden|denied|rejected|invalid|error|not found' "$f"; then
    printf '%s: REJECTED (exit %s) :: %s\n' "$tag" "$rc" "$(grep -m1 -iE 'not allowed|unknown agent|forbidden|denied|rejected|invalid|error|not found' "$f" | cut -c1-200)"
  elif [ "$rc" = "0" ]; then
    printf '%s: ACCEPTED (exit 0) :: %s\n' "$tag" "$(head -c 200 "$f" | tr '\n' ' ')"
  else
    printf '%s: UNCLEAR (exit %s) :: %s\n' "$tag" "$rc" "$(head -c 200 "$f" | tr '\n' ' ')"
  fi
}

hr "verdicts, verbatim first line of each"
v1="$(classify n1)"; say "$v1"
v2="$(classify n2)"; say "$v2"
v3="$(classify n3)"; say "$v3"
v4="$(classify n4)"; say "$v4"

case "$v1$v2" in
  *UNCLEAR*) verdict 4 "BLOCKED (the spawn route itself did not answer — read out/p4-n1.txt and out/p4-n2.txt verbatim before reading anything into these)";;
  *) if [ "${v1#n1: REJECTED}" != "$v1" ] && [ "${v2#n2: REJECTED}" != "$v2" ]; then
       if [ "${v3#n3: REJECTED}" != "$v3" ]; then
         verdict 4 "PASS (n1,n2 rejected; n3 rejected at the gateway — cwd policy refused the foreign directory)"
       else
         say "n3 was accepted; the sandbox is then the only thing between the worker and $NEIGHBOUR_CWD."
         say "Re-run probe2-sandbox.sh with PROBE_CWD=$NEIGHBOUR_CWD to say which layer denies it, and record THAT."
         verdict 4 "FAIL (n3 accepted with a foreign cwd and the denial was not measured in this run)"
       fi
     else
       verdict 4 "FAIL (an agent outside acp.allowedAgents was not rejected)"
     fi;;
esac
