#!/usr/bin/env bash
# Capability 2, run end to end: an agent working in a client repository reaches
# for the brain on an ordinary work question, without being told to, and answers
# from something that exists only there.
#
# Operator-run, not part of `npm test`: a run spends model time and writes a
# page into the brain.
#
#   ./acceptance/capability-2-brain-without-reminders.sh
#
# Exit 0 = pass, 1 = fail, 2 = refused to start (preconditions unmet).
#
# The design took five attempts to get right, and four of the failures were in
# the probe rather than the system. They are worth stating because each one
# looked like a real negative result:
#
#   1. The fixture was written in words the question did not use, so the
#      keyword tier could not connect them.
#   2. The fixture went into the repo's own code source, which is worktree
#      pinned and writes through — so the "brain-only" fact was also a file.
#   3. A fixture from an earlier run was still on disk answering the same
#      question.
#   4. The question was one the client repository genuinely answers, so
#      reading the repo was correct behaviour and told us nothing.
#   5. A later question ("is there anything to do before an external security
#      audit?") drew zero brain calls across four sessions — every one of them
#      inspected the repository instead, which is the right move for a question
#      about the repository's own state. The question has to be one whose
#      answer can only live in an agreement, or the agent correctly never asks.
#
# What this script does about each: the fixture goes in a PATH-LESS source
# (upstream's shape for agent-written memory — gbrain
# docs/integrations/qm-harness.md:156-158, "agent-written memory needs no git
# clone"), the marker is generated here and grepped for on disk before the
# verdict, and the fact is engagement knowledge with no possible home in a
# code repository.

set -uo pipefail

GATEWAY="${GATEWAY:-http://localhost:3000}"
CONTAINER="${CONTAINER:-openclaw-stack-openclaw-1}"
VOLUME="${VOLUME:-openclaw-stack_openclaw-data}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/openclaw-api-token}"
REPO_IN_CONTAINER="${REPO_IN_CONTAINER:-/data/simlinks}"
# Claude Code writes its own transcripts here, keyed by cwd. This is the only
# record that carries real tool_use blocks: the OpenClaw session records under
# .openclaw/workspace/state/sessions carry UI menu labels where tool names look
# like they should be, and judging from them produced four wrong readings in
# one session.
TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-/data/.claude/projects/-data-simlinks}"
TIMEOUT_SECS="${TIMEOUT_SECS:-2700}"

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
refuse() { printf 'REFUSED: %s\n' "$*"; exit 2; }

[ -r "$TOKEN_FILE" ] || refuse "no gateway token at $TOKEN_FILE"
TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"

HEALTH="$(curl -fsS -m 10 "$GATEWAY/health" 2>/dev/null)" \
  || refuse "gateway health endpoint unreachable at $GATEWAY"
case "$HEALTH" in *'"gateway":"running"'*) : ;; *) refuse "gateway not running: $HEALTH" ;; esac

# A config change schedules a restart that waits up to 300s for active runs to
# drain and then forces one. Dispatching into that loses the run.
if docker logs --tail 40 "$CONTAINER" 2>&1 | grep -q "requires gateway restart\|restart still deferred"; then
  refuse "a gateway restart is pending; wait for it to settle"
fi

MARKER="CAP2-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"
DISPATCH_EPOCH="$(date +%s)"
say "marker: $MARKER"

read -r -d '' TASK <<EOF
Проверка приёмки. Два шага, разными сессиями.

Шаг 1. Запиши в GBrain страницу в PATH-LESS источник — тот, у которого нет
локального пути, поэтому запись не материализуется файлом. Источник должен
быть достижим обычным поиском из сессии Claude Code с рабочим каталогом
$REPO_IN_CONTAINER, без явного --source в запросе.

Содержание: договорённость с клиентом SimLinks о том, что нужно выполнить
перед тем, как изменение топливного коэффициента в app-v2 уйдёт в релиз.
Это знание о договорённостях, а не о коде. Включи в текст идентификатор
$MARKER так, чтобы он назывался в ответе на вопрос ниже.

Шаг 2. ОТДЕЛЬНОЙ, свежей ACP-сессией Claude Code с рабочим каталогом
$REPO_IN_CONTAINER задай ровно этот вопрос, ничего к нему не добавляя:

«Что нужно согласовать перед релизом изменения топливного коэффициента
в app-v2?»

Не подсказывай пробной сессии — ни про мозг, ни про поиск, ни про страницы.
Верни путь транскрипта пробной сессии.
EOF

PAYLOAD="$(python3 -c '
import json,sys
print(json.dumps({"model":"openclaw/main","messages":[{"role":"user","content":sys.stdin.read()}]}, ensure_ascii=False))
' <<< "$TASK")"

say "dispatching (timeout ${TIMEOUT_SECS}s) ..."
HTTP="$(curl -s -m "$TIMEOUT_SECS" -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST "$GATEWAY/v1/chat/completions" --data-binary "$PAYLOAD")"
say "http: $HTTP"
# Reported, not the verdict: a dispatch has returned 000 on the caller's own
# timeout while the delegated work completed and was recorded.

# --- Gate: the fact must not be reachable on disk -----------------------------
# Runs first. If the marker is in the repository, no later evidence means
# anything, because the answer could have been read rather than retrieved.
ON_DISK="$(docker run --rm -v "$VOLUME":/d:ro node:22-slim sh -c \
  "grep -rl '$MARKER' '/d/${REPO_IN_CONTAINER#/data/}' 2>/dev/null | head -5" 2>/dev/null)"
if [ -n "$ON_DISK" ]; then
  fail "the marker is on disk, so the probe cannot discriminate:
$ON_DISK"
fi
say "gate: marker is nowhere in $REPO_IN_CONTAINER"

# --- Verdict, from Claude Code's own transcripts ------------------------------
VERDICT="$(docker run --rm -v "$VOLUME":/d:ro \
  -e MARKER="$MARKER" -e SINCE="$DISPATCH_EPOCH" -e TDIR="${TRANSCRIPT_DIR#/data/}" \
  node:22-slim node -e '
  const fs = require("fs"), path = require("path");
  const dir = "/d/" + process.env.TDIR;
  const since = Number(process.env.SINCE) * 1000;
  const marker = process.env.MARKER;
  let best = null;
  for (const f of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
    if (!f.endsWith(".jsonl")) continue;
    const p = path.join(dir, f);
    if (fs.statSync(p).mtimeMs < since) continue;
    let brain = 0, marked = false;
    for (const line of fs.readFileSync(p, "utf8").split("\n")) {
      if (!line) continue;
      let o; try { o = JSON.parse(line); } catch { continue; }
      const c = o.message && o.message.content;
      if (!Array.isArray(c)) continue;
      for (const b of c) {
        if (b.type === "tool_use") {
          const s = JSON.stringify(b.input || {});
          if (b.name.startsWith("mcp__gbrain") || /gbrain (search|query|recall|get)/.test(s)) brain++;
        }
        if (b.type === "text" && b.text.includes(marker)) marked = true;
      }
    }
    if (marked && brain > 0) { best = { f, brain }; break; }
  }
  console.log(best ? "PASS " + best.f + " " + best.brain : "NONE");
' 2>/dev/null)"

case "$VERDICT" in
  PASS*)
    set -- $VERDICT
    say "evidence: transcript $2 — $3 brain call(s), marker present in the answer"
    say ""
    say "PASS — the agent reached for the brain unprompted and answered from it."
    exit 0 ;;
  *)
    fail "no transcript in $TRANSCRIPT_DIR since dispatch carries BOTH a brain call and the marker.
The marker is not on disk, so an answer without a brain call means the fact never reached the agent." ;;
esac
