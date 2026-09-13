#!/usr/bin/env bash
# probe5-acpx.sh — v4 §Measure 5: "acpx 2026.9.3 on the volume via the main
# agent". Here: is the acpx plugin present in a FRESH volume at all, and does
# the pinned version install and report healthy?
#
# Why the question is real: the live volume carries acpx 2026.7.1 installed by
# hand, not by the image (finding acp-dispatch-unknown-agent-id-2026-09-13,
# "acpx 2026.7.1 under core 2026.9.3, installed on the volume, not by the
# image"). A fresh volume may carry nothing.
#
# Command shapes — acp-agents-setup.md "Plugin setup for acpx backend":
#     openclaw plugins install @openclaw/acpx
#     openclaw config set plugins.entries.acpx.enabled true
#   and "Start with: /acp doctor". `/acp doctor` is a CHAT slash command, not a
#   CLI subcommand (cli/index.md "Command tree" lists `plugins doctor`, and
#   `acp` only as the bridge-mode command — cli/acp.md). So the CLI evidence is
#   `openclaw plugins doctor`, and the slash form is attempted through
#   `openclaw agent` ("Run one agent turn through the Gateway", cli/agent.md:11)
#   and recorded whatever it answers.
#
# Idempotent: an already-installed 2026.9.3 is reported, not reinstalled.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACPX_PIN="2026.9.3"
guard_container

hr "plugins list (before)"
run_logged "$PROBE_OUT_DIR/p5-list-before.txt" occ plugins list
say "exit=$(logged_rc "$PROBE_OUT_DIR/p5-list-before.txt")"

present=no
version_ok=no
if grep -qi 'acpx' "$PROBE_OUT_DIR/p5-list-before.txt"; then
  present=yes
  grep -i 'acpx' "$PROBE_OUT_DIR/p5-list-before.txt" | grep -qF "$ACPX_PIN" && version_ok=yes
fi
say "acpx present before this run: $present ; at $ACPX_PIN: $version_ok"

if [ "$version_ok" != yes ]; then
  hr "installing @openclaw/acpx@$ACPX_PIN"
  run_logged "$PROBE_OUT_DIR/p5-install.txt" occ plugins install "@openclaw/acpx@$ACPX_PIN"
  say "exit=$(logged_rc "$PROBE_OUT_DIR/p5-install.txt")"
  run_logged "$PROBE_OUT_DIR/p5-enable.txt" occ config set plugins.entries.acpx.enabled true
  say "exit=$(logged_rc "$PROBE_OUT_DIR/p5-enable.txt")"
fi

hr "plugins list (after)"
run_logged "$PROBE_OUT_DIR/p5-list-after.txt" occ plugins list
say "exit=$(logged_rc "$PROBE_OUT_DIR/p5-list-after.txt")"

hr "plugins doctor"
run_logged "$PROBE_OUT_DIR/p5-doctor.txt" occ plugins doctor
say "exit=$(logged_rc "$PROBE_OUT_DIR/p5-doctor.txt")"

hr "/acp doctor through an agent turn (may need a model provider; recorded either way)"
run_logged "$PROBE_OUT_DIR/p5-acp-doctor.txt" \
  occ agent --agent main -m '/acp doctor' --timeout 60
say "exit=$(logged_rc "$PROBE_OUT_DIR/p5-acp-doctor.txt")"

installed=no
if grep -i 'acpx' "$PROBE_OUT_DIR/p5-list-after.txt" | grep -qF "$ACPX_PIN"; then installed=yes; fi
doctor_rc="$(logged_rc "$PROBE_OUT_DIR/p5-doctor.txt")"

hr "summary"
say "acpx present before this run          : $present"
say "acpx == $ACPX_PIN after this script    : $installed"
say "plugins doctor exit                    : $doctor_rc"

if [ "$installed" = yes ] && [ "$doctor_rc" = "0" ]; then
  verdict 5 "PASS"
elif [ "$installed" = yes ]; then
  verdict 5 "FAIL (installed at $ACPX_PIN but plugins doctor exited $doctor_rc — see out/p5-doctor.txt)"
else
  verdict 5 "FAIL (acpx $ACPX_PIN not present after install — see out/p5-install.txt)"
fi
