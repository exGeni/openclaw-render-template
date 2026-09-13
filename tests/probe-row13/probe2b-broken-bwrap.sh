#!/usr/bin/env bash
# probe2b-broken-bwrap.sh — v4 §Measure 2, last clause: "`bwrap` removed →
# session refuses to start."
#
# The property under test is the managed policy's hard gate:
#   sandboxing.md, "Set up Linux and WSL2" note: "By default, if the sandbox
#   cannot start because dependencies are missing or the platform is
#   unsupported, Claude Code shows a warning and runs commands without
#   sandboxing. To make this a hard failure instead, set
#   `sandbox.failIfUnavailable` to `true`. This is intended for managed
#   deployments that require sandboxing as a security gate."
#   bubblewrap is named as the dependency: "the unprivileged sandboxing tool
#   that enforces filesystem isolation" (same page).
# claude-code/managed-settings.json sets `failIfUnavailable: true`, so with
# bwrap gone a worker session must refuse to start rather than run unsandboxed.
#
# The test has a PRECONDITION and asserts it: the baseline turn, with bwrap
# present, must exit 0. "Removing X makes it refuse" says nothing about X if it
# was already refusing. The assertion runs before the rename, so a failed
# precondition leaves the container untouched.
#
# This renames /usr/bin/bwrap INSIDE THE PROBE CONTAINER ONLY and restores it
# in a trap that fires on every exit path, including a failure or a Ctrl-C.
# Nothing outside the probe container is touched.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

guard_container

restore_bwrap() {
  pexec sh -c '[ -e /usr/bin/bwrap.off ] && mv -f /usr/bin/bwrap.off /usr/bin/bwrap || true' >/dev/null 2>&1 || true
  say "restored: $(pexec sh -c 'ls -la /usr/bin/bwrap /usr/bin/bwrap.off 2>&1' || true)"
}
trap restore_bwrap EXIT

hr "baseline: bwrap present, one cheap turn"
run_logged "$PROBE_OUT_DIR/p2b2-before.txt" \
  docker exec -w "$PROBE_CWD" -e HOME="$PROBE_HOME" -e TERM=dumb "$PROBE_CONTAINER" \
  claude -p 'echo hi'
before_rc="$(logged_rc "$PROBE_OUT_DIR/p2b2-before.txt")"
say "exit=$before_rc"

# PRECONDITION, asserted before anything is broken. The property under test is
# "with bwrap ABSENT the session refuses to start", and that is only meaningful
# against a session that WORKS with bwrap present. If the baseline already
# failed, the bwrap-removed half fails for the reason it already had and the
# classification below reports PASS off an exit code that proves nothing.
if [ "$before_rc" != "0" ]; then
  hr "precondition failed"
  say "baseline exit: $before_rc, with bwrap PRESENT. Nothing was removed."
  say "Read out/p2b2-before.txt. A sandbox that cannot start before the test"
  say "begins makes the bwrap-removed half unreadable."
  verdict 2b "FAIL (baseline exit=$before_rc with bwrap present — a working sandbox is the precondition of this test)"
  exit 1
fi

hr "removing bwrap (rename, inside the probe container only)"
pexec sh -c 'mv /usr/bin/bwrap /usr/bin/bwrap.off'
pexec sh -c 'ls -la /usr/bin/bwrap 2>&1 || true; ls -la /usr/bin/bwrap.off'

hr "same turn with bwrap gone — expected: refusal to start"
run_logged "$PROBE_OUT_DIR/p2b2-broken.txt" \
  docker exec -w "$PROBE_CWD" -e HOME="$PROBE_HOME" -e TERM=dumb "$PROBE_CONTAINER" \
  claude -p 'echo hi'
broken_rc="$(logged_rc "$PROBE_OUT_DIR/p2b2-broken.txt")"
say "exit=$broken_rc"

refused=no
[ "$broken_rc" != "0" ] && refused=yes
grep -qiE 'sandbox|bwrap|bubblewrap|unavailable' "$PROBE_OUT_DIR/p2b2-broken.txt" && named_sandbox=yes || named_sandbox=no

hr "classification"
say "baseline exit           : $before_rc  (asserted 0 above — the precondition)"
say "bwrap-removed exit      : $broken_rc"
say "refused to start        : $refused"
say "error names the sandbox : $named_sandbox"

if [ "$refused" = yes ] && [ "$named_sandbox" = yes ]; then
  verdict 2b "PASS"
elif [ "$refused" = yes ]; then
  verdict 2b "FAIL (it refused, but the error does not name the sandbox — read out/p2b2-broken.txt before believing failIfUnavailable is what stopped it)"
else
  verdict 2b "FAIL (turn still succeeded without bwrap — the managed failIfUnavailable gate did not fire)"
fi
