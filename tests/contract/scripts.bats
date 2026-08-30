#!/usr/bin/env bats
#
# Contract tests for the shell scripts. These lock in the load-bearing
# invariants that CLAUDE.md / AGENTS.md call out under "don't remove" and
# "What NOT to do" — the things that, if dropped, restart-loop the container.
# They are static (no container needed) so they run fast in `npm test`.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "start.sh: valid bash syntax" {
  bash -n "$REPO/start.sh"
}

@test "debug-start.sh: valid bash syntax" {
  bash -n "$REPO/debug-start.sh"
}

@test "start.sh: passes shellcheck" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  shellcheck "$REPO/start.sh"
}

@test "debug-start.sh: passes shellcheck" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  shellcheck "$REPO/debug-start.sh"
}

# --- PATH fix (load-bearing: alphaclaw spawns openclaw by bare name) ----------

@test "start.sh: prepends /app/node_modules/.bin to PATH" {
  grep -Eq 'export PATH="/app/node_modules/\.bin:' "$REPO/start.sh"
}

# --- TMPDIR onto the persistent disk ------------------------------------------

@test "start.sh: exports the TMPDIR/TEMP/TMP trio to /data/tmp" {
  grep -q 'TMPDIR=/data/tmp' "$REPO/start.sh"
  grep -q 'TEMP=/data/tmp'   "$REPO/start.sh"
  grep -q 'TMP=/data/tmp'    "$REPO/start.sh"
}

@test "start.sh: creates /data/tmp with the sticky bit on boot" {
  # /data is a runtime-mounted disk, so the dir must be (re)created at boot.
  grep -Eq 'mkdir -p "\$TMPDIR"' "$REPO/start.sh"
  grep -q 'chmod 1777 "\$TMPDIR"' "$REPO/start.sh"
}

@test "start.sh: never operates on bare /tmp (mentions only in comments)" {
  # CLAUDE.md rule: leave /tmp alone — no symlink, bind-mount, or move. We allow
  # /tmp to appear in explanatory comments, but every such line must be a comment.
  while IFS= read -r line; do
    [[ "$line" =~ ^[0-9]+:[[:space:]]*# ]] || { echo "non-comment /tmp use: $line"; false; }
  done < <(grep -nw '/tmp' "$REPO/start.sh")
}

# --- Resilience: supervise loop, not one-shot + dead-end fallback -------------

@test "start.sh: runs alphaclaw via \$ALPHACLAW_BIN with the standard default" {
  grep -q '"\$ALPHACLAW_BIN" start' "$REPO/start.sh"
  grep -q 'ALPHACLAW_BIN="\${ALPHACLAW_BIN:-/app/node_modules/\.bin/alphaclaw}"' "$REPO/start.sh"
}

@test "start.sh: preserves the PIPESTATUS-through-tee exit-code pattern" {
  grep -q 'CODE=\${PIPESTATUS\[0\]}' "$REPO/start.sh"
}

@test "start.sh: honors the exit-75 intentional-restart contract" {
  grep -Eq '\-eq 75' "$REPO/start.sh"
}

@test "start.sh: supervises the failure server as a loop child (never exec)" {
  grep -q '"\$NODE_BIN" "\$FAILURE_SERVER"' "$REPO/start.sh"
  ! grep -q 'exec node' "$REPO/start.sh"
}

@test "start.sh: ships the documented policy defaults (60s window, 5 fails, 5s step)" {
  grep -q 'RAPID_WINDOW_SECS="\${RAPID_WINDOW_SECS:-60}"' "$REPO/start.sh"
  grep -q 'MAX_RAPID_FAILS="\${MAX_RAPID_FAILS:-5}"' "$REPO/start.sh"
  grep -q 'BACKOFF_STEP_SECS="\${BACKOFF_STEP_SECS:-5}"' "$REPO/start.sh"
}

@test "start.sh: anchors the failure server's grace clock with FAILURE_EPOCH" {
  grep -q 'FAILURE_EPOCH="\$FAILURE_EPOCH" "\$NODE_BIN" "\$FAILURE_SERVER"' "$REPO/start.sh"
}

@test "start.sh: rotates an oversized boot log" {
  grep -q 'MAX_LOG_BYTES' "$REPO/start.sh"
  grep -q "\.1" "$REPO/start.sh"
}
