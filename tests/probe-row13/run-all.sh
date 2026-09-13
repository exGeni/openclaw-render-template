#!/usr/bin/env bash
# run-all.sh — probes 1..5 in order, after up.sh reports the probe HOME logged
# in. Does not stop on a red probe: every verdict is collected and reprinted at
# the end, because a FAIL in one probe is evidence for the others, not a reason
# to stop measuring. Plan step 2b: "Nothing proceeds to step 3 on a red probe" —
# that decision is the orchestrator's, and this script only supplies the table.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_docker
guard_names

if ! probe_running; then
  say "probe container is not running — run ./up.sh first"
  verdict all "BLOCKED (container down)"
  exit 1
fi

rc=0
pexec env HOME="$PROBE_HOME" claude auth status --text >"$PROBE_OUT_DIR/auth-status.txt" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  cat "$PROBE_OUT_DIR/auth-status.txt"
  say ""
  say "LOGIN-NEEDED — probes 2, 2b and 3 need the owner's one-time login (O4a)."
  say "Run ./up.sh to print the exact command. Running the login-free probes only:"
  ORDER="probe1-env.sh probe5-acpx.sh"
else
  ORDER="probe1-env.sh probe2-sandbox.sh probe2b-broken-bwrap.sh probe3-auth.sh probe4-negatives.sh probe5-acpx.sh"
fi

: >"$PROBE_OUT_DIR/run-all-verdicts.txt"
for s in $ORDER; do
  hr "RUN $s"
  "$PROBE_DIR/$s" 2>&1 | tee "$PROBE_OUT_DIR/${s%.sh}.stdout" || true
  grep -hE '^PROBE-[0-9a-b]+: ' "$PROBE_OUT_DIR/${s%.sh}.stdout" >>"$PROBE_OUT_DIR/run-all-verdicts.txt" || \
    printf 'PROBE-?(%s): NO VERDICT LINE\n' "$s" >>"$PROBE_OUT_DIR/run-all-verdicts.txt"
done

hr "verdicts"
cat "$PROBE_OUT_DIR/run-all-verdicts.txt"
