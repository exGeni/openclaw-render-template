#!/usr/bin/env bash
# up.sh — bring up the row-13 probe container and seed it. Idempotent.
#
# Answers plan step 2b's precondition: "a container from the candidate image on
# the laptop with a scratch volume and a test HOME (O4a)"
# (plans/intermediate-goal-phone-to-isolated-worker-2026-09-13.md, step 2b).
#
# Command shapes and their documents:
#   * container run shape — tests/e2e/docker.bats:36-52 (this repo's own e2e
#     harness): `docker run -d --name "$CONTAINER" --tmpfs /data -p ... -e PORT
#     -e SETUP_PASSWORD -e OPENCLAW_GATEWAY_TOKEN -e WEBHOOK_TOKEN "$IMAGE"`,
#     then poll /health. Three deliberate differences, all stated in the README:
#     a named volume instead of --tmpfs (the owner's login must survive a
#     restart), no published port (the live stack owns 3000/3131; every
#     call here is a docker exec), and the `openclaw` service's own
#     `security_opt` from docker-compose.yml — the custom seccomp profile plus
#     apparmor=unconfined, without which Claude Code's bubblewrap sandbox
#     cannot create a namespace and every sandbox probe measures the stand
#     rather than the image.
#   * config writes — docs/cli/config.md "Examples":
#       openclaw config set browser.profiles.work '{"cdpPort":18801,...}' \
#         --strict-json --merge
#     and "Prefer `agents.entries.<id>` paths for agent edits."
#   * acp baseline keys (acp.enabled / backend / allowedAgents) —
#     acp-agents-setup.md "Required config".
#   * acpx alias shape — acp-agents-setup.md: "`agents.<id>.command` is the
#     executable or existing command string for that ACP agent."
#     "`agents.<id>.args` is optional. Each item is passed unchanged ... Do not
#     add shell quoting inside the array."
#   * harness permissions — acp-agents-setup.md "Permission configuration":
#     `approve-all` = "Auto-approve all file writes and shell commands."
#     Set on purpose: it removes OpenClaw's own permission layer from the
#     experiment, so any denial probe 2 records comes from the Claude Code
#     sandbox / permission system, which is what row 13 is about.
#   * login check — code.claude.com/docs/en/cli-reference.md:27
#     "`claude auth status` | Show authentication status as JSON. Use `--text`
#     for human-readable output. Exits with code 0 if logged in, 1 if not".
#
# NEVER touches the live containers, the live volume, or ports 3000/3131.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_docker
guard_names

docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 \
  || die "candidate image $PROBE_IMAGE not found — build it first"

# ---------------------------------------------------------------- 1. env file
# Only what the gateway needs to start, per README.md:34-37 (SETUP_PASSWORD
# required; OPENCLAW_GATEWAY_TOKEN and WEBHOOK_TOKEN auto-generated on Render)
# and tests/e2e/docker.bats:40-44, which boots the image with exactly these.
# Values are freshly generated here; no value is ever copied from the live .env.
# No provider API key is set: the repo's own e2e boots the image credential-free
# and still gets /health 200 (docker.bats "container stays Live"). A model turn
# needs one; a gateway boot does not. If a probe needs a model turn it will say
# so in its own BLOCKED line rather than a key being smuggled in here.
if [ ! -f "$PROBE_ENV_FILE" ]; then
  umask 077
  {
    echo "PORT=3000"
    echo "SETUP_PASSWORD=$(openssl rand -hex 32)"
    echo "OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)"
    echo "WEBHOOK_TOKEN=$(openssl rand -hex 32)"
  } >"$PROBE_ENV_FILE"
  chmod 600 "$PROBE_ENV_FILE"
  say "created $PROBE_ENV_FILE (0600, freshly generated values, gitignored)"
else
  say "reusing $PROBE_ENV_FILE ($(stat -c '%a' "$PROBE_ENV_FILE"), $(wc -l <"$PROBE_ENV_FILE") keys)"
fi

# --------------------------------------------------------------- 2. container
if docker container inspect "$PROBE_CONTAINER" >/dev/null 2>&1; then
  if probe_running; then
    say "container $PROBE_CONTAINER already running"
  else
    say "container $PROBE_CONTAINER exists but is stopped — starting"
    docker start "$PROBE_CONTAINER" >/dev/null
  fi
else
  require_security_profile
  docker volume create "$PROBE_VOLUME" >/dev/null
  say "starting $PROBE_CONTAINER from $PROBE_IMAGE on volume $PROBE_VOLUME (no published ports)"
  say "security_opt: ${PROBE_SECURITY_OPTS[*]}"
  docker run -d --name "$PROBE_CONTAINER" \
    --env-file "$PROBE_ENV_FILE" \
    "${PROBE_SECURITY_OPTS[@]}" \
    -v "$PROBE_VOLUME:/data" \
    "$PROBE_IMAGE" >/dev/null
fi

guard_container
hr "container identity"
docker inspect -f 'image={{.Config.Image}} ports={{json .NetworkSettings.Ports}} mounts={{range .Mounts}}{{.Name}}:{{.Destination}} {{end}} security_opt={{json .HostConfig.SecurityOpt}}' "$PROBE_CONTAINER"

# ------------------------------------------------------------ 3. health gate
hr "gateway health (docker exec curl 127.0.0.1:3000/health, inside the probe)"
healthy=no
for _ in $(seq 1 60); do
  if pexec curl -fsS -m 3 http://127.0.0.1:3000/health >"$PROBE_OUT_DIR/health.txt" 2>&1; then
    healthy=yes; break
  fi
  sleep 2
done
cat "$PROBE_OUT_DIR/health.txt" 2>/dev/null || true
echo
if [ "$healthy" != yes ]; then
  say "gateway never answered /health; last 40 log lines:"
  docker logs --tail 40 "$PROBE_CONTAINER" 2>&1 || true
  verdict 0 "BLOCKED (gateway health)"
  exit 1
fi
say "health: OK"
pexec openclaw --version 2>&1 || true

# --------------------------------------------------------------- 4. canaries
hr "canaries and directories"
pexec sh -c '
set -eu
mkdir -p /data/probe /data/neighbour /data/agents/probe/home /data/agents/neighbour/home /data/agents/probe/home/.claude/skills
printf "OWN-CANARY-OK\n"                     > /data/probe/own-canary.txt
printf "NEIGHBOUR-CANARY-MUST-NOT-BE-READ\n" > /data/neighbour/secret-canary.txt
printf "PROBE_FAKE_KEY=fake\n"               > /data/.env
printf "{\"probeToken\":\"gbrain_at_PROBECANARY_NOT_A_TOKEN\"}\n" > /data/agents/neighbour/home/.claude.json
chmod 700 /data/agents/probe/home
chmod 600 /data/agents/neighbour/home/.claude.json /data/.env
# The renderer gives each worker HOME the gstack tree by symlink (AGENTS.md
# "Worker executors": "It gets it through a symlink ~/.claude/skills/gstack ->
# /root/.claude/skills/gstack created by the renderer in each worker HOME. The
# image seeds no worker HOME."). Reproduced so the probe HOME matches a real one.
[ -e /data/agents/probe/home/.claude/skills/gstack ] || ln -s /root/.claude/skills/gstack /data/agents/probe/home/.claude/skills/gstack
ls -la /data/probe /data/neighbour /data/agents/probe /data/agents/neighbour/home
ls -ld /data/agents/probe/home
'

# --------------------------------------------- 4b. baseline gateway config
# A fresh volume has no openclaw.json at all ("[alphaclaw] No config yet --
# onboarding will run from the Setup UI", /data/start.log), and every
# `openclaw config set` below needs one. The documented non-interactive way to
# create it is cli/index.md:16 — "`openclaw setup --baseline` creates the
# baseline config and workspace without walking the guided onboarding flow."
hr "baseline config"
if occ config file >/dev/null 2>&1; then
  say "config already present: $(occ config file 2>&1)"
else
  run_logged "$PROBE_OUT_DIR/setup-baseline.txt" occ setup --baseline
  say "exit=$(logged_rc "$PROBE_OUT_DIR/setup-baseline.txt")"
fi

# ------------------------------------------------- 5. acpx plugin  (= probe 5)
hr "probe 5: acpx plugin"
"$PROBE_DIR/probe5-acpx.sh" || say "probe5 returned non-zero (see its own verdict line above)"

# ----------------------------------------------------------- 6. seed config
# Order matters: acp.allowedAgents LAST — plan step 1 says it "is written LAST
# (it restarts the gateway)".
hr "seeding gateway config"
cfg() { occ config set "$@"; }

cfg agents.entries.claude-probe '{
  "identity": {"name": "claude-probe"},
  "workspace": "/data/.openclaw/workspace-claude-probe",
  "tools": {"profile": "minimal"},
  "runtime": {"type": "acp", "acp": {"agent": "claude-probe", "backend": "acpx", "mode": "oneshot", "cwd": "/data/probe"}}
}' --strict-json --merge

cfg agents.entries.claude-neighbour '{
  "identity": {"name": "claude-neighbour"},
  "workspace": "/data/.openclaw/workspace-claude-neighbour",
  "tools": {"profile": "minimal"},
  "runtime": {"type": "acp", "acp": {"agent": "claude-neighbour", "backend": "acpx", "mode": "oneshot", "cwd": "/data/neighbour"}}
}' --strict-json --merge

# Entry id MUST equal the acpx alias id (finding
# acp-dispatch-unknown-agent-id-2026-09-13; openclaw/openclaw#126539).
cfg plugins.entries.acpx.enabled true
cfg plugins.entries.acpx.config.agents.claude-probe '{
  "command": "env",
  "args": ["-i","HOME=/data/agents/probe/home","PATH=/usr/local/bin:/usr/bin:/bin","OPENCLAW_SESSION=1","TERM=dumb","/usr/local/bin/node","/data/.openclaw/acpx/claude-agent-acp-wrapper.mjs"]
}' --strict-json --merge
cfg plugins.entries.acpx.config.agents.claude-neighbour '{
  "command": "env",
  "args": ["-i","HOME=/data/agents/neighbour/home","PATH=/usr/local/bin:/usr/bin:/bin","OPENCLAW_SESSION=1","TERM=dumb","/usr/local/bin/node","/data/.openclaw/acpx/claude-agent-acp-wrapper.mjs"]
}' --strict-json --merge

# approve-all: see the header. deny (not fail) so a blocked prompt degrades
# instead of aborting the session — acp-agents-setup.md "nonInteractivePermissions".
cfg plugins.entries.acpx.config.permissionMode approve-all
cfg plugins.entries.acpx.config.nonInteractivePermissions deny

cfg acp.enabled true
cfg acp.backend '"acpx"' --strict-json
# LAST.
cfg acp.allowedAgents '["claude-probe"]' --strict-json

hr "config readback"
occ config get acp 2>&1 || true
occ config get agents.entries 2>&1 || true
occ config get plugins.entries.acpx 2>&1 || true

hr "is the OpenClaw gateway WS reachable? (the ACP-spawn probes need it)"
if gateway_up; then
  say "gateway: reachable"
else
  say "gateway: NOT reachable — ws://127.0.0.1:18789 ECONNREFUSED."
  say "alphaclaw gates it behind its own Setup UI onboarding, which is an HTTP"
  say "flow on :3000 that also picks a model provider (README.md:163-165: the"
  say "server 'runs openclaw onboard, configures channels...'). Verbatim from"
  say "/data/start.log in this container:"
  pexec sh -c 'grep -n "onboarding\|Awaiting" /data/start.log | tail -3' 2>&1 || true
  say "Consequence: probes 1, 2A, 2b, 3 and 5 run; the ACP-spawn halves"
  say "(probe 2B and probe 4) report BLOCKED with that reason, not PASS."
fi

hr "adapter wrapper present?"
pexec sh -c "ls -la '$ALIAS_WRAPPER' 2>&1 || echo 'ABSENT: $ALIAS_WRAPPER (acpx auto-downloads adapters via npx on first use — acp-agents-setup.md \"Automatic adapter download\")'"

# ------------------------------------------------------------ 7. login gate
hr "claude auth status in the probe HOME"
rc=0
pexec env HOME="$PROBE_HOME" claude auth status --text >"$PROBE_OUT_DIR/auth-status.txt" 2>&1 || rc=$?
cat "$PROBE_OUT_DIR/auth-status.txt"
say "exit code: $rc  (cli-reference.md:27 — 0 if logged in, 1 if not)"

if [ "$rc" -ne 0 ]; then
  cat <<EOF

LOGIN-NEEDED
The probe HOME $PROBE_HOME is not logged in. This is owner action O4a and the
only manual step in this harness. Run, in a terminal on this laptop:

  docker exec -it $PROBE_CONTAINER env HOME=$PROBE_HOME TERM=xterm claude

then type /login and complete the browser flow. (cli-reference.md:25 documents
the non-interactive equivalent \`claude auth login\`; either finishes the same
credential store under \$HOME.) Re-run this script afterwards; it is idempotent
and will stop reporting LOGIN-NEEDED.

Probes 1 and 5 need no login and have already run above.
EOF
  verdict 0 "BLOCKED (LOGIN-NEEDED — owner action O4a)"
  exit 0
fi

verdict 0 "PASS (container up, seeded, probe HOME logged in)"
