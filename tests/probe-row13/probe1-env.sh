#!/usr/bin/env bash
# probe1-env.sh — v4 §Measure 1: "Alias with `env -i`: adapter starts; child env
# names == allowlist."
#
# This half measures the ENV NAMES the alias hands the adapter. It replays the
# alias argv exactly as up.sh wrote it into
# plugins.entries.acpx.config.agents.claude-probe, with the adapter wrapper
# swapped for a printer. Nothing here needs a login, a model, or a spawn.
#
# The alias is `command: "env"`, `args: ["-i","HOME=…","PATH=…",
# "OPENCLAW_SESSION=1","TERM=dumb","/usr/local/bin/node","<wrapper>"]` —
# acp-agents-setup.md: "`agents.<id>.args` is optional. Each item is passed
# unchanged, including empty strings, spaces, quotes, and backslashes. Do not
# add shell quoting inside the array."
#
# PASS iff the child's env name set is exactly HOME, PATH, OPENCLAW_SESSION,
# TERM. `env -i` adds nothing of its own; if this run shows otherwise, the
# actual set is printed verbatim and the probe FAILs rather than widening the
# expectation.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

guard_container

hr "alias argv replayed with the wrapper replaced by /usr/bin/env"
say "docker exec $PROBE_CONTAINER env ${ALIAS_ENV_ARGS[*]} /usr/bin/env"
run_logged "$PROBE_OUT_DIR/p1-env.txt" pexec env "${ALIAS_ENV_ARGS[@]}" /usr/bin/env
say "exit=$(logged_rc "$PROBE_OUT_DIR/p1-env.txt")"

hr "alias argv replayed with the wrapper replaced by node -e (the real interpreter)"
run_logged "$PROBE_OUT_DIR/p1-node.txt" pexec env "${ALIAS_ENV_ARGS[@]}" \
  /usr/local/bin/node -e 'console.log(Object.keys(process.env).sort().join(","))'
say "exit=$(logged_rc "$PROBE_OUT_DIR/p1-node.txt")"

hr "control: the same node WITHOUT env -i (what a naked spawn would inherit)"
run_logged "$PROBE_OUT_DIR/p1-control.txt" pexec \
  /usr/local/bin/node -e 'console.log(Object.keys(process.env).sort().join(","))'
say "exit=$(logged_rc "$PROBE_OUT_DIR/p1-control.txt")"

actual="$(tr -d '\r' <"$PROBE_OUT_DIR/p1-node.txt" | head -1)"
env_actual_sorted="$(tr -d '\r' <"$PROBE_OUT_DIR/p1-env.txt" | cut -d= -f1 | sort | paste -sd, -)"

hr "comparison"
say "expected (allowlist)   : $EXPECTED_ENV_NAMES"
say "actual  (node keys)    : $actual"
say "actual  (env(1) names) : $env_actual_sorted"

if [ "$actual" = "$EXPECTED_ENV_NAMES" ] && [ "$env_actual_sorted" = "$EXPECTED_ENV_NAMES" ]; then
  verdict 1 "PASS"
else
  verdict 1 "FAIL (child env name set differs from the allowlist — see the two actual lines above)"
fi
