#!/usr/bin/env bats
#
# End-to-end regression test for the "invalid OpenClaw config" boot failure.
#
# Reproduces the real-world breakage seen after switching the alphaclaw
# dependency from the @chrysb npm package (installed at
# /app/node_modules/@chrysb/alphaclaw/...) to the garrytan git fork (installed
# at /app/node_modules/alphaclaw/...): the persistent disk's openclaw.json still
# references the OLD usage-tracker plugin path, which no longer exists, so
# OpenClaw rejects the whole config:
#
#   plugins.load.paths: plugin: plugin path not found:
#     /app/node_modules/@chrysb/alphaclaw/lib/plugin/usage-tracker
#
# Unlike docker.bats (empty /data), this seeds a REAL /data with the stale path
# baked into openclaw.json, boots the actual container, and asserts alphaclaw
# migrates the config on boot. Covers BOTH states, because the prune must not be
# gated behind onboarding:
#   - onboarded  (onboarded.json present  => runOnboardedBootSequence runs)
#   - NOT onboarded (no marker => only bin/alphaclaw.js's unconditional reconcile
#                    runs; this is the case that regressed in the field)
#
# Slow (builds an image). Run via `npm run test:e2e`. Skips if docker is absent.

IMAGE="openclaw-render-test:latest"
C_ONB="openclaw-render-stale-onboarded-e2e"
C_NOO="openclaw-render-stale-not-onboarded-e2e"
PORT_ONB=13001
PORT_NOO=13002
STALE_PATH="/app/node_modules/@chrysb/alphaclaw/lib/plugin/usage-tracker"
CANONICAL_PATH="/app/node_modules/alphaclaw/lib/plugin/usage-tracker"

_seed_data_dir() {
  # $1 = dir, $2 = "onboarded" | "not-onboarded"
  local dir="$1"
  mkdir -p "$dir/.openclaw"
  if [ "$2" = "onboarded" ]; then
    printf '{"onboarded":true}\n' >"$dir/onboarded.json"
  fi
  cat >"$dir/.openclaw/openclaw.json" <<JSON
{
  "plugins": {
    "allow": ["usage-tracker"],
    "load": { "paths": ["$STALE_PATH"] },
    "entries": { "usage-tracker": { "enabled": true } }
  }
}
JSON
}

_run_seeded() {
  # $1 = container name, $2 = host port, $3 = seed dir
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" \
    -v "$3:/data" \
    -p "$2:3000" \
    -e PORT=3000 \
    -e SETUP_PASSWORD="stale-config-test" \
    -e OPENCLAW_GATEWAY_TOKEN="stale-config-test" \
    -e WEBHOOK_TOKEN="stale-config-test" \
    "$IMAGE" >&2
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$2/health" >/dev/null 2>&1; then break; fi
    sleep 2
  done
  # Give bin/alphaclaw.js's on-boot config reconcile a moment to write.
  sleep 5
}

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO IMAGE C_ONB C_NOO PORT_ONB PORT_NOO STALE_PATH CANONICAL_PATH

  command -v docker >/dev/null || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"

  docker build -t "$IMAGE" "$REPO" >&2

  SEED_ONB="$(mktemp -d)"; SEED_NOO="$(mktemp -d)"
  export SEED_ONB SEED_NOO
  _seed_data_dir "$SEED_ONB" onboarded
  _seed_data_dir "$SEED_NOO" not-onboarded

  _run_seeded "$C_ONB" "$PORT_ONB" "$SEED_ONB"
  _run_seeded "$C_NOO" "$PORT_NOO" "$SEED_NOO"
}

teardown_file() {
  docker rm -f "$C_ONB" "$C_NOO" >/dev/null 2>&1 || true
  [ -n "$SEED_ONB" ] && rm -rf "$SEED_ONB" || true
  [ -n "$SEED_NOO" ] && rm -rf "$SEED_NOO" || true
}

# --- onboarded ---------------------------------------------------------------

@test "onboarded: container stays Live with seeded stale plugin path" {
  run curl -fsS "http://127.0.0.1:${PORT_ONB}/health"
  [ "$status" -eq 0 ]
}

@test "onboarded: boot pruned the stale @chrysb usage-tracker path" {
  run docker exec "$C_ONB" cat /data/.openclaw/openclaw.json
  [ "$status" -eq 0 ]
  echo "config: $output" >&2
  ! grep -qF "$STALE_PATH" <<<"$output"
  grep -qF "$CANONICAL_PATH" <<<"$output"
}

@test "onboarded: openclaw config validate no longer reports a missing plugin path" {
  run docker exec "$C_ONB" sh -c "openclaw config validate 2>&1 || true"
  echo "validate: $output" >&2
  ! grep -qF "$STALE_PATH" <<<"$output"
  ! grep -qiF "plugin path not found" <<<"$output"
}

# --- NOT onboarded (the field regression) ------------------------------------

@test "not-onboarded: container stays Live with seeded stale plugin path" {
  run curl -fsS "http://127.0.0.1:${PORT_NOO}/health"
  [ "$status" -eq 0 ]
}

@test "not-onboarded: boot pruned the stale @chrysb usage-tracker path" {
  run docker exec "$C_NOO" cat /data/.openclaw/openclaw.json
  [ "$status" -eq 0 ]
  echo "config: $output" >&2
  ! grep -qF "$STALE_PATH" <<<"$output"
  grep -qF "$CANONICAL_PATH" <<<"$output"
}

@test "not-onboarded: openclaw config validate no longer reports a missing plugin path" {
  run docker exec "$C_NOO" sh -c "openclaw config validate 2>&1 || true"
  echo "validate: $output" >&2
  ! grep -qF "$STALE_PATH" <<<"$output"
  ! grep -qiF "plugin path not found" <<<"$output"
}
