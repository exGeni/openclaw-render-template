// Minimal HTTP server that serves a status page after `alphaclaw start` has
// failed rapidly and repeatedly. The start.sh supervise loop runs it as a
// loop child, so it has two ways OUT of failure mode instead of being a dead
// end:
//
//   - POST /restart exits this process with code 0; the supervisor then
//     relaunches alphaclaw immediately.
//   - /health and /healthz answer 200 only for a grace period (default 5
//     minutes) so the Render Shell tab stays reachable for debugging, then
//     flip to 503 so the platform's health check restarts the container even
//     if no operator intervenes. The grace clock anchors to FAILURE_EPOCH
//     (unix seconds, supervisor-provided, surviving restart cycles) so
//     repeated /restart clicks or spam cannot keep a broken box "healthy"
//     forever; without the env it falls back to process start time.
//
// listen() retries on EADDRINUSE: a crashing alphaclaw can hold the port for
// a few seconds, and crashing here would silently cycle the supervisor.
//
// IMPORTANT: this server is publicly reachable on the service URL. It must
// NOT expose any logs, env vars, or file contents, and /restart must have no
// side effects beyond exiting this process (no shelling out, nothing read
// from the request). Direct the operator to the Render Shell tab to inspect
// /data/start.log there.

const http = require("http");

const HEALTH_GRACE_MS =
  parseInt(process.env.FAILURE_HEALTH_GRACE_MS, 10) > 0
    ? parseInt(process.env.FAILURE_HEALTH_GRACE_MS, 10)
    : 5 * 60 * 1000;

// Anchor for the grace clock: supervisor-provided epoch (seconds) if valid.
const epochSecs = parseInt(process.env.FAILURE_EPOCH, 10);
const GRACE_ANCHOR_MS =
  Number.isFinite(epochSecs) && epochSecs > 0 ? epochSecs * 1000 : Date.now();

// Restart "cooldown" is request dedupe within this process's short lifetime
// (an accepted restart exits ~250ms later); cross-cycle churn is bounded by
// the supervisor's own cycle length and health honesty by the epoch anchor.
const RESTART_COOLDOWN_MS = 30 * 1000;
let restartAccepted = false;
let healthFlipLogged = false;

const logFlip = () => {
  if (!healthFlipLogged) {
    healthFlipLogged = true;
    console.log(
      `[failure-server] health grace period expired (anchor ${new Date(GRACE_ANCHOR_MS).toISOString()}, grace ${HEALTH_GRACE_MS}ms); /health now returns 503 so the platform restarts the container`,
    );
  }
};
// Log the flip on schedule even if nothing polls /health.
const msUntilFlip = Math.max(0, GRACE_ANCHOR_MS + HEALTH_GRACE_MS - Date.now());
setTimeout(logFlip, msUntilFlip);

const html = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>AlphaClaw — startup failure</title>
  <style>
    body { font-family: ui-monospace, monospace; padding: 2em; max-width: 50em; line-height: 1.6; color: #222; }
    h1 { color: #c00; }
    code { background: #f5f5f5; padding: 0.1em 0.4em; border-radius: 3px; }
    .ok { color: #060; }
    ol li { margin-bottom: 0.5em; }
    button { font: inherit; padding: 0.5em 1.4em; border-radius: 6px; border: 1px solid #060; background: #e8f5e9; cursor: pointer; }
    button:hover { background: #d3ecd6; }
  </style>
</head>
<body>
  <h1>AlphaClaw failed to start</h1>
  <p><strong class="ok">The container is up</strong> — but <code>alphaclaw start</code> exited rapidly several times in a row, so the boot supervisor is holding here. This page is the failure-mode fallback so the deploy stays Live and you can debug from the Render Shell tab.</p>

  <form method="POST" action="/restart">
    <button type="submit">Restart AlphaClaw</button>
  </form>
  <p style="color: #666; font-size: 0.9em;">Restarting relaunches <code>alphaclaw start</code> under the supervisor. If it keeps failing fast you will land back on this page. If nobody intervenes before the grace period ends, <code>/health</code> flips to 503 and the platform restarts the container automatically.</p>

  <h2>Debug steps</h2>
  <ol>
    <li>Open the Render Shell tab for this service (reachable while the container is healthy).</li>
    <li>Inspect the boot log: <code>cat /data/start.log</code> — the supervisor logs every exit code, run duration, and restart decision.</li>
    <li>Check for a pending rollback marker: <code>ls /data/.openclaw/.alphaclaw/openclaw-rollback-pending.json</code>. <strong>If it exists, do NOT run alphaclaw by hand</strong> — a manual start replays the rollback and can wedge the install. Use the Restart button above (or wait for the health-check restart) so the supervisor handles it.</li>
    <li>Check that <code>openclaw</code> resolves on PATH: <code>which openclaw &amp;&amp; openclaw --version</code></li>
  </ol>

  <p style="margin-top: 3em; color: #888; font-size: 0.9em;">No log content is rendered on this page because the boot log can contain environment values. Use the Shell tab to inspect.</p>
</body>
</html>`;

const restartingHtml = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta http-equiv="refresh" content="8;url=/"><title>Restarting…</title></head>
<body style="font-family: ui-monospace, monospace; padding: 2em;">
  <h1>Restarting AlphaClaw…</h1>
  <p>The supervisor is relaunching <code>alphaclaw start</code>. This page reloads in a few seconds.</p>
</body></html>`;

const server = http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/restart") {
    if (restartAccepted) {
      res.writeHead(429, { "content-type": "text/plain" });
      res.end("restart already requested; try again in 30s");
      return;
    }
    restartAccepted = true;
    // Re-arm after the cooldown in the (unlikely) event the exit is delayed.
    setTimeout(() => {
      restartAccepted = false;
    }, RESTART_COOLDOWN_MS).unref();
    console.log(
      "[failure-server] restart requested; exiting so the supervisor relaunches alphaclaw",
    );
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(restartingHtml);
    // Unconditional: never gated on response flush — a client that
    // disconnects mid-POST must not strand the restart.
    setTimeout(() => process.exit(0), 250);
    return;
  }
  if (req.url === "/health" || req.url === "/healthz") {
    if (Date.now() - GRACE_ANCHOR_MS < HEALTH_GRACE_MS) {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok");
    } else {
      logFlip();
      res.writeHead(503, { "content-type": "text/plain" });
      res.end("failure grace period expired; awaiting platform restart");
    }
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(html);
});

const PORT = parseInt(process.env.PORT, 10) || 3000;

// A dying alphaclaw can hold the port briefly; retry instead of crashing.
let bindAttempts = 0;
const MAX_BIND_ATTEMPTS = 30;
server.on("error", (err) => {
  if (err.code === "EADDRINUSE" && bindAttempts < MAX_BIND_ATTEMPTS) {
    bindAttempts += 1;
    console.log(
      `[failure-server] port ${PORT} in use (attempt ${bindAttempts}/${MAX_BIND_ATTEMPTS}); retrying in 1s`,
    );
    setTimeout(() => server.listen(PORT, "0.0.0.0"), 1000);
    return;
  }
  console.error(`[failure-server] fatal: ${err.message}`);
  process.exit(1);
});

server.on("listening", () => {
  console.log(`[failure-server] listening on port ${PORT}`);
});

server.listen(PORT, "0.0.0.0");
