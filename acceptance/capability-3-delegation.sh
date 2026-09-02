#!/usr/bin/env bash
# Capability 3, run end to end: the head OpenClaw agent accepts a task, hands it
# to a real Claude Code process over ACP, and the result comes back.
#
# This is NOT part of `npm test`. It spends model time (a run takes minutes) and
# it mutates a client repository inside the container, so it is an operator-run
# acceptance script, not a unit or contract test.
#
#   ./acceptance/capability-3-delegation.sh
#
# The verdict is taken from evidence outside the agent's own account:
#   - the artifact exists on the container's disk, carrying a marker that was
#     generated here and never spoken aloud before the run started
#   - the gateway recorded a delegated runtime (acpx / subagent) during the run
# An agent that merely REPORTS success without either of those fails.
#
# Exit 0 = pass, 1 = fail, 2 = refused to start (preconditions unmet).

set -uo pipefail

GATEWAY="${GATEWAY:-http://localhost:3000}"
CONTAINER="${CONTAINER:-openclaw-stack-openclaw-1}"
VOLUME="${VOLUME:-openclaw-stack_openclaw-data}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/openclaw-api-token}"
# Where the artifact lands. Inside the client repo on purpose: a delegated
# Claude Code session works in the project, the head agent does not.
REPO_IN_CONTAINER="${REPO_IN_CONTAINER:-/data/simlinks}"
TIMEOUT_SECS="${TIMEOUT_SECS:-1500}"

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
refuse() { printf 'REFUSED: %s\n' "$*"; exit 2; }

# --- Preconditions -----------------------------------------------------------
# A healthy gateway is not the same as a gateway ready to take work. A config
# change schedules a restart that waits up to 300s for active runs to drain and
# then forces one, killing whatever is mid-flight. Three earlier runs were lost
# to exactly that before this check existed, so it is a hard gate, not a hint.

[ -r "$TOKEN_FILE" ] || refuse "no gateway token at $TOKEN_FILE"
TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"

HEALTH="$(curl -fsS -m 10 "$GATEWAY/health" 2>/dev/null)" \
  || refuse "gateway health endpoint unreachable at $GATEWAY"
case "$HEALTH" in
  *'"gateway":"running"'*) : ;;
  *) refuse "gateway not running: $HEALTH" ;;
esac

if docker logs --tail 40 "$CONTAINER" 2>&1 | grep -q "requires gateway restart\|restart still deferred"; then
  refuse "a gateway restart is pending; wait for it to settle or the run will be aborted mid-flight"
fi

# --- Marker ------------------------------------------------------------------
# Generated here, after the preconditions pass, so it cannot pre-exist anywhere
# and cannot have leaked into any agent's context before this run.
MARKER="cap3-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
ARTIFACT="acceptance/${MARKER}.md"
say "marker:   $MARKER"
say "artifact: $REPO_IN_CONTAINER/$ARTIFACT"

LOGPOS="$(docker logs "$CONTAINER" 2>&1 | wc -l)"

# --- The task ----------------------------------------------------------------
# Phrased as work, not as a test. It names the destination repository because a
# delegated session needs a working directory, and it asks for a fact that has
# to be read out of that repository, so a head agent answering from its own
# context would produce the wrong content.
read -r -d '' TASK <<EOF
Поручи работу над клиентским проектом SimLinks агенту Claude Code через ACP,
с рабочим каталогом $REPO_IN_CONTAINER.

Задача для него: создать файл $ARTIFACT со следующим содержимым —

  строка 1: $MARKER
  строка 2: относительный путь любого файла исходников продукта app-v2,
            прочитанный из этого репозитория
  строка 3: текущая ветка репозитория

Верни мне: путь созданного файла и идентификатор сессии, которая его создала.
EOF

PAYLOAD="$(python3 -c '
import json,sys
print(json.dumps({"model":"openclaw/main","messages":[{"role":"user","content":sys.stdin.read()}]}, ensure_ascii=False))
' <<< "$TASK")"

say "dispatching (timeout ${TIMEOUT_SECS}s) ..."
HTTP="$(curl -s -m "$TIMEOUT_SECS" -o /tmp/cap3-resp.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST "$GATEWAY/v1/chat/completions" --data-binary "$PAYLOAD")"
say "http: $HTTP"

# A non-200 is worth reporting but is NOT the verdict. Earlier runs returned 500
# because the gateway restarted underneath them while the delegated work had
# already completed. The disk and the log decide, not the status line.

# --- Evidence 1: the artifact exists, with the marker ------------------------
# Polled, not sampled once. The reply to the caller is a receipt: it returns
# when the head agent has finished ITS turn, which is before the delegated
# Claude Code process has finished writing. Measured: a run returned 200 and
# the artifact appeared on disk about a minute later. A single immediate check
# fails a run that in fact succeeded — which is the same class of mistake as
# reading a curl status as the verdict.
ARTIFACT_WAIT_SECS="${ARTIFACT_WAIT_SECS:-300}"
FOUND=""
waited=0
while [ "$waited" -lt "$ARTIFACT_WAIT_SECS" ]; do
  FOUND="$(docker run --rm -v "$VOLUME":/d:ro node:22-slim sh -c \
    "cat '/d/${REPO_IN_CONTAINER#/data/}/$ARTIFACT' 2>/dev/null" 2>/dev/null)"
  [ -n "$FOUND" ] && break
  sleep 15
  waited=$((waited + 15))
done
[ -n "$FOUND" ] || fail "artifact not on disk after ${ARTIFACT_WAIT_SECS}s: $REPO_IN_CONTAINER/$ARTIFACT"
say "waited ${waited}s for the artifact to land"
case "$FOUND" in
  *"$MARKER"*) say "evidence 1: artifact present and carries the marker" ;;
  *) fail "artifact exists but does not carry the marker" ;;
esac

LINES="$(printf '%s\n' "$FOUND" | grep -c .)"
[ "$LINES" -ge 3 ] || fail "artifact has $LINES non-empty lines, expected at least 3 (marker, source path, branch)"

# --- Evidence 2: the work was delegated, not done in the head agent ----------
NEW_LOG="$(docker logs "$CONTAINER" 2>&1 | tail -n +"$LOGPOS")"
if printf '%s' "$NEW_LOG" | grep -qE "acpx|runtime=subagent|runtime=cli"; then
  say "evidence 2: gateway recorded a delegated runtime during the run"
else
  fail "no delegated runtime in the gateway log for this run — the head agent may have done it itself"
fi

say ""
say "PASS — capability 3 held end to end."
say "  artifact: $REPO_IN_CONTAINER/$ARTIFACT"
printf '%s\n' "$FOUND" | sed 's/^/  | /'
exit 0
