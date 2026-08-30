#!/usr/bin/env bats
#
# Behavioral harness for start.sh's supervise loop — runs the REAL start.sh on
# the host (no Docker) via its env overrides, with a stub alphaclaw driven by a
# scenario file (one "exitcode sleep" line per invocation) and a stub failure
# server that exits shortly after starting.
#
# Safety: ORPHAN_SWEEP_PATTERN is always overridden with a unique per-test tag
# so the sweep can never touch real host processes, and LOGFILE points into the
# test tmpdir so nothing writes to /data.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  TAG="supervise-test-$$-${BATS_TEST_NUMBER}-tag"

  # Stub alphaclaw: consumes one scenario line per invocation.
  cat >"$T/stub-alphaclaw" <<'STUB'
#!/bin/bash
n=$(cat "$STUB_DIR/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$STUB_DIR/count"
line=$(sed -n "${n}p" "$STUB_DIR/scenario")
[ -z "$line" ] && line="0 300"
code=${line%% *}; slp=${line##* }
sleep "$slp"
exit "$code"
STUB
  chmod +x "$T/stub-alphaclaw"

  # Stub failure server: logs its env anchor (flush-confirmed), exits after ~300ms.
  cat >"$T/stub-failure-server.js" <<'STUB'
process.stdout.write("[stub-failure-server] up FAILURE_EPOCH=" + (process.env.FAILURE_EPOCH || "") + "\n", () => {
  setTimeout(() => process.exit(0), 300);
});
STUB

  export STUB_DIR="$T"
  : >"$T/scenario"
  rm -f "$T/count"
}

# Launch the real start.sh with harness-safe env. Extra VAR=val pairs pass
# through. NODE_BIN is absolute because start.sh exports the container PATH,
# which doesn't contain the host's node. fd3 is closed so backgrounded
# descendants can't make bats wait on it.
run_supervisor() {
  env STUB_DIR="$T" \
    ALPHACLAW_BIN="$T/stub-alphaclaw" \
    FAILURE_SERVER="$T/stub-failure-server.js" \
    NODE_BIN="$(command -v node)" \
    LOGFILE="$T/start.log" \
    ORPHAN_SWEEP_PATTERN="$TAG" \
    BACKOFF_STEP_SECS=0 SPIN_BRAKE_SECS=0 \
    "$@" \
    bash "$REPO/start.sh" >"$T/stdout.log" 2>&1 3>&- &
  SUP_PID=$!
}

teardown() {
  [ -n "${SUP_PID:-}" ] && kill "$SUP_PID" 2>/dev/null || true
  pkill -f "$T/stub-alphaclaw" 2>/dev/null || true
  pkill -f "$T/stub-failure-server.js" 2>/dev/null || true
  pkill -f "$TAG" 2>/dev/null || true
  wait 2>/dev/null || true
}

wait_for_count() { # target timeout_halfsecs
  local target=$1 tries=${2:-20}
  for _ in $(seq 1 "$tries"); do
    [ "$(cat "$T/count" 2>/dev/null || echo 0)" -ge "$target" ] && return 0
    sleep 0.5
  done
  echo "count never reached $target; log follows:" >&2
  cat "$T/start.log" >&2 || true
  return 1
}

wait_for_log() { # pattern timeout_halfsecs
  local pat=$1 tries=${2:-20}
  for _ in $(seq 1 "$tries"); do
    grep -q "$pat" "$T/start.log" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "log never matched: $pat" >&2
  cat "$T/start.log" >&2 || true
  return 1
}

@test "exit 75 relaunches immediately and never counts as a failure" {
  printf '75 0\n75 0\n0 300\n' >"$T/scenario"
  run_supervisor
  wait_for_count 3 20
  grep -c "intentional restart" "$T/start.log" | grep -q "^2$"
  ! grep -q "rapid failure" "$T/start.log"
  ! grep -q "failure-status server" "$T/start.log"
}

@test "10 consecutive sub-5s exit-75 runs log a possible-loop WARNING" {
  for _ in $(seq 1 11); do printf '75 0\n'; done >"$T/scenario"
  printf '0 300\n' >>"$T/scenario"
  run_supervisor
  wait_for_log "possible exit-75 loop" 30
  ! grep -q "rapid failure" "$T/start.log"
}

@test "a run longer than the rapid window resets the counter (old-alphaclaw restarts)" {
  printf '1 2\n1 2\n1 2\n0 300\n' >"$T/scenario"
  run_supervisor RAPID_WINDOW_SECS=1
  wait_for_count 4 40
  grep -c "counter reset" "$T/start.log" | grep -q "^3$"
  # 3 consecutive non-zero long-run exits → visibility warning, but no failure server
  wait_for_log "consecutive non-zero long-run exits" 10
  ! grep -q "failure-status server" "$T/start.log"
}

@test "5 rapid failures reach the failure server; its exit resets the counter" {
  printf '1 0\n1 0\n1 0\n1 0\n1 0\n0 300\n' >"$T/scenario"
  run_supervisor RAPID_WINDOW_SECS=5
  wait_for_count 6 30
  grep -q "rapid failure 1/5" "$T/start.log"
  grep -q "rapid failure 4/5" "$T/start.log"
  grep -q "threshold reached" "$T/start.log"
  grep -q "\[stub-failure-server\] up FAILURE_EPOCH=" "$T/start.log"
  # env anchor was non-empty when the server ran
  ! grep -q "up FAILURE_EPOCH=$" "$T/start.log"
  grep -q "failure server exited" "$T/start.log"
}

@test "FAILURE_EPOCH persists across failure-server cycles, clears after a healthy run" {
  {
    for _ in $(seq 1 5); do printf '1 0\n'; done
    for _ in $(seq 1 5); do printf '1 0\n'; done
    printf '0 3\n'
    for _ in $(seq 1 5); do printf '1 0\n'; done
    printf '0 300\n'
  } >"$T/scenario"
  run_supervisor RAPID_WINDOW_SECS=1
  wait_for_count 17 60
  # three threshold entries logged with their epoch
  [ "$(grep -c 'threshold reached' "$T/start.log")" -eq 3 ]
  e1=$(grep "threshold reached" "$T/start.log" | sed -n '1s/.*FAILURE_EPOCH=\([0-9]*\).*/\1/p')
  e2=$(grep "threshold reached" "$T/start.log" | sed -n '2s/.*FAILURE_EPOCH=\([0-9]*\).*/\1/p')
  e3=$(grep "threshold reached" "$T/start.log" | sed -n '3s/.*FAILURE_EPOCH=\([0-9]*\).*/\1/p')
  [ -n "$e1" ] && [ "$e1" = "$e2" ]
  [ "$e3" != "$e1" ]
}

@test "cumulative backoff is capped so the failure page stays reachable" {
  printf '1 0\n1 0\n1 0\n1 0\n1 0\n0 300\n' >"$T/scenario"
  run_supervisor RAPID_WINDOW_SECS=5 BACKOFF_STEP_SECS=1 CUM_BACKOFF_CAP_SECS=2
  wait_for_log "threshold reached" 40
  grep -q "cap 2s" "$T/start.log"
  # backoffs requested 1,2,3,4 but cap 2 → total slept <= 2
  total=$(grep -o "backing off [0-9]*s" "$T/start.log" | grep -o "[0-9]*" | awk '{s+=$1} END {print s+0}')
  [ "${total:-0}" -le 2 ]
}

@test "oversized LOGFILE rotates to .1 at loop top" {
  printf '0 300\n' >"$T/scenario"
  head -c 2048 /dev/zero >"$T/start.log"
  run_supervisor MAX_LOG_BYTES=1000
  wait_for_log "rotated oversized log" 20
  [ -f "$T/start.log.1" ]
}

@test "orphan sweep TERMs stragglers matching ORPHAN_SWEEP_PATTERN" {
  # Dedicated stub: first run spawns a tagged orphan, then exits 1.
  cat >"$T/orphan-helper.sh" <<EOF
#!/bin/bash
# argv carries the tag via this file's path
sleep 300
EOF
  chmod +x "$T/orphan-helper.sh"
  mv "$T/orphan-helper.sh" "$T/$TAG-orphan.sh"
  cat >"$T/stub-alphaclaw" <<STUB
#!/bin/bash
n=\$(cat "\$STUB_DIR/count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" >"\$STUB_DIR/count"
if [ "\$n" -eq 1 ]; then
  nohup bash "$T/$TAG-orphan.sh" >/dev/null 2>&1 &
  exit 1
fi
sleep 300
STUB
  chmod +x "$T/stub-alphaclaw"
  printf '' >"$T/scenario"
  run_supervisor
  wait_for_log "orphan sweep complete" 20
  sleep 0.5
  ! pgrep -f "$TAG-orphan.sh" >/dev/null
}

@test "invalid numeric env values fall back to defaults with a WARNING" {
  printf '0 300\n' >"$T/scenario"
  run_supervisor RAPID_WINDOW_SECS=bogus
  wait_for_log "invalid RAPID_WINDOW_SECS" 20
  grep -q "using default 60" "$T/start.log"
}
