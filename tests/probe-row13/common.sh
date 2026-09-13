#!/usr/bin/env bash
# Shared constants, guards and helpers for the row-13 probe harness.
#
# Sourced by every probe script. Never run directly.
#
# SAFETY CONTRACT (the reason this file exists):
#   The live stack on this laptop is openclaw-stack-openclaw-1 + gbrain-serve +
#   gbrain-postgres on volume openclaw-stack_openclaw-data, publishing 3000 and
#   127.0.0.1:3131. NOTHING in this directory may touch any of them. Every
#   docker verb here goes through the helpers below, which refuse to run
#   against any name that is not the probe's own, assert the target container
#   was created from the candidate image, and assert it publishes no ports.
#
# Design notes with their sources:
#   * The run shape (detached, name, env vars, health wait) follows the repo's
#     own e2e harness, tests/e2e/docker.bats:36-52 — `docker run -d --name ...
#     -e PORT=3000 -e SETUP_PASSWORD=... -e OPENCLAW_GATEWAY_TOKEN=... -e
#     WEBHOOK_TOKEN=... "$IMAGE"` then poll /health. e2e uses `--tmpfs /data`;
#     this harness uses a NAMED volume instead, because the owner's one-time
#     Claude login (O4a) has to survive a container restart.
#   * No published ports. e2e publishes 13000:3000 only so the host-side bats
#     process can curl /health; every call here is a `docker exec` inside the
#     probe container, so the port is unnecessary and 3000/3131 stay the live
#     stack's alone.

set -euo pipefail

# ---------------------------------------------------------------- identifiers
PROBE_IMAGE="openclaw-stack-openclaw:row13-candidate"
PROBE_CONTAINER="openclaw-row13-probe"
PROBE_VOLUME="row13-probe-data"

# Everything the harness must never address.
FORBIDDEN_CONTAINERS="openclaw-stack-openclaw-1 gbrain-serve gbrain-postgres"
FORBIDDEN_VOLUMES="openclaw-stack_openclaw-data openclaw-stack_gbrain-serve-home gbrain-pgdata"
FORBIDDEN_IMAGES="openclaw-stack-openclaw:latest openclaw-stack-gbrain-serve:latest"

PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_ENV_FILE="$PROBE_DIR/.probe.env"
PROBE_OUT_DIR="$PROBE_DIR/out"
REPO_ROOT="$(cd "$PROBE_DIR/../.." && pwd)"

# ------------------------------------------------------- production confinement
# The stand runs the container with the same two relaxations the `openclaw`
# service carries in docker-compose.yml, so what it measures is the production
# configuration. Without them Claude Code's bubblewrap sandbox cannot create a
# namespace inside the container and every sandboxed Bash command fails, which
# is a property of the stand rather than of the image under test.
#
# Absolute path on purpose: the Docker CLI resolves a relative `seccomp=` path
# from the working directory `docker` is invoked in, and these scripts are
# runnable from anywhere.
PROBE_SECCOMP_PROFILE="$REPO_ROOT/seccomp-userns.json"
PROBE_SECURITY_OPTS=(
  --security-opt "seccomp=$PROBE_SECCOMP_PROFILE"
  --security-opt apparmor=unconfined
)

# ------------------------------------------------------------- probe subjects
PROBE_HOME="/data/agents/probe/home"
NEIGHBOUR_HOME="/data/agents/neighbour/home"
PROBE_CWD="/data/probe"
NEIGHBOUR_CWD="/data/neighbour"
OWN_CANARY="OWN-CANARY-OK"
NEIGHBOUR_CANARY="NEIGHBOUR-CANARY-MUST-NOT-BE-READ"
# Literal canary string. Not a credential: it matches no issuer's format and
# authenticates nothing. Its only job is to be findable in probe output.
CANARY_TOKEN="gbrain_at_PROBECANARY_NOT_A_TOKEN"

# The acpx alias argv, exactly as up.sh writes it into the gateway config.
# Kept here so probe1 can replay it byte for byte with the wrapper swapped out.
ALIAS_ENV_ARGS=(-i
  "HOME=$PROBE_HOME"
  "PATH=/usr/local/bin:/usr/bin:/bin"
  "OPENCLAW_SESSION=1"
  "TERM=dumb")
ALIAS_WRAPPER="/data/.openclaw/acpx/claude-agent-acp-wrapper.mjs"
# probe1's PASS set: the four names the alias sets. `env -i` itself adds none.
EXPECTED_ENV_NAMES="HOME,OPENCLAW_SESSION,PATH,TERM"

mkdir -p "$PROBE_OUT_DIR"

# ------------------------------------------------------------------- plumbing
say()  { printf '%s\n' "$*"; }
hr()   { printf -- '---- %s\n' "$*"; }
die()  { printf 'HARNESS-ERROR: %s\n' "$*" >&2; exit 2; }

# Verdict line. Every probe prints exactly one, last.
verdict() { printf 'PROBE-%s: %s\n' "$1" "$2"; }

guard_names() {
  local n
  for n in $FORBIDDEN_CONTAINERS; do
    [ "$PROBE_CONTAINER" = "$n" ] && die "probe container name collides with the live stack: $n"
  done
  for n in $FORBIDDEN_VOLUMES; do
    [ "$PROBE_VOLUME" = "$n" ] && die "probe volume name collides with the live stack: $n"
  done
  for n in $FORBIDDEN_IMAGES; do
    [ "$PROBE_IMAGE" = "$n" ] && die "probe image is a live-stack image: $n"
  done
  return 0
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not installed"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
}

probe_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$PROBE_CONTAINER" 2>/dev/null || echo false)" = "true" ]
}

# Assert the profile docker-compose.yml names is on disk. `docker run` fails
# loudly on a missing profile, but the message points at a path rather than at
# the repo file that is supposed to be there.
require_security_profile() {
  [ -f "$PROBE_SECCOMP_PROFILE" ] \
    || die "seccomp profile not found: $PROBE_SECCOMP_PROFILE (it is the repo file docker-compose.yml's openclaw service names)"
}

# Assert the container we are about to talk to is OUR container, built from the
# candidate image, holding no live volume, publishing no port, and carrying the
# production security_opt.
guard_container() {
  guard_names
  probe_running || die "probe container $PROBE_CONTAINER is not running — run up.sh first"

  local img mounts ports
  img="$(docker inspect -f '{{.Config.Image}}' "$PROBE_CONTAINER")"
  [ "$img" = "$PROBE_IMAGE" ] || die "container $PROBE_CONTAINER runs image '$img', not '$PROBE_IMAGE'"

  mounts="$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$PROBE_CONTAINER")"
  local v
  for v in $FORBIDDEN_VOLUMES; do
    case " $mounts " in *" $v "*) die "container $PROBE_CONTAINER has live volume $v mounted";; esac
  done

  ports="$(docker inspect -f '{{json .NetworkSettings.Ports}}' "$PROBE_CONTAINER")"
  case "$ports" in
    ''|'{}'|'null') ;;
    *) case "$ports" in
         *HostPort*) die "container $PROBE_CONTAINER publishes host ports: $ports";;
       esac;;
  esac

  # A container started before the security_opt landed is still runnable and
  # answers /health, so nothing else here would notice — and every sandbox probe
  # would then measure a configuration production does not have.
  local secopt
  secopt="$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$PROBE_CONTAINER")"
  case "$secopt" in
    *"seccomp=$PROBE_SECCOMP_PROFILE"*) ;;
    *) die "container $PROBE_CONTAINER was not started with the repo seccomp profile (SecurityOpt=$secopt) — recreate it: down.sh --yes --keep-volume && up.sh";;
  esac
  case "$secopt" in
    *apparmor=unconfined*) ;;
    *) die "container $PROBE_CONTAINER was not started with apparmor=unconfined (SecurityOpt=$secopt) — recreate it: down.sh --yes --keep-volume && up.sh";;
  esac
}

# The ONLY way this harness executes anything in a container.
pexec() { docker exec "$PROBE_CONTAINER" "$@"; }

# Every `openclaw` CLI call goes through this, with HOME=/data. MEASURED
# 2026-09-13 in this container, not assumed: with the image's default HOME=/root
# every config writer dies with
#   [openclaw] Reason: Atomic replace parent must be a real directory: /root/.openclaw
# because alphaclaw symlinks it at boot ("[alphaclaw] Symlinked /root/.openclaw
# -> /data/.openclaw", /data/start.log) and openclaw's atomic replace refuses a
# symlinked parent. With HOME=/data the same command answers
#   Updated acp.enabled. Restart the gateway to apply.
# and `openclaw config file` prints /data/.openclaw/openclaw.json — the same
# file the gateway reads through that symlink.
occ() { docker exec -e HOME=/data "$PROBE_CONTAINER" openclaw "$@"; }

# Is the OpenClaw gateway's WS actually up in the probe container? On a fresh
# volume it is NOT: alphaclaw parks on "Awaiting onboarding via Setup UI"
# (/data/start.log) and never starts it, so every `openclaw agent` /
# `gateway call` route answers ECONNREFUSED on ws://127.0.0.1:18789.
gateway_up() { occ health >/dev/null 2>&1; }
# Same, with a working directory and the probe HOME — the worker's shape.
whome() { docker exec -w "$PROBE_CWD" -e HOME="$PROBE_HOME" "$PROBE_CONTAINER" "$@"; }

# Run a command, tee its output to a log, and NEVER read an exit code through a
# pipe (~/.claude/CLAUDE.md "Never read an exit code through a pipe").
run_logged() {
  local log="$1"; shift
  local rc=0
  "$@" >"$log" 2>&1 || rc=$?
  printf '%s' "$rc" >"$log.rc"
  cat "$log"
  return 0
}

logged_rc() { cat "$1.rc" 2>/dev/null || echo "?"; }
