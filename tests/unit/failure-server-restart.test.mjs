// Unit tests for failure-server.js restart + health-honesty behavior — the
// escape hatches that keep the failure page from being a dead end:
//
//   - POST /restart exits the process (code 0) so the start.sh supervise loop
//     relaunches alphaclaw. Must exit even if the client disconnects mid-POST.
//   - /health flips 200 → 503 after FAILURE_HEALTH_GRACE_MS, anchored to the
//     supervisor-provided FAILURE_EPOCH (so restart cycles can't reset it).
//   - listen() retries on EADDRINUSE (a dying alphaclaw can hold the port).
//
// Strategy matches failure-server.test.mjs: spawn the real artifact per test.
// Every spawn registers a t.after() SIGKILL so a failing assertion can never
// leave a child alive holding stdio pipes (which hangs the test runner).

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { connect } from "node:net";
import path from "node:path";

const SERVER = path.resolve(import.meta.dirname, "../../failure-server.js");

const spawnServer = (t, port, extraEnv = {}) => {
  const child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, PORT: String(port), ...extraEnv },
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => {
    try {
      child.kill("SIGKILL");
    } catch {}
  });
  let stdout = "";
  child.stdout.on("data", (b) => (stdout += b.toString()));
  child.stderr.on("data", (b) => (stdout += b.toString()));
  const listening = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("server did not start in time")), 15000);
    timer.unref();
    child.stdout.on("data", (buf) => {
      if (buf.toString().includes("listening on port")) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`server exited early (code ${code})`));
    });
  });
  listening.catch(() => {}); // settled-late rejections must not be unhandled
  const exited = new Promise((resolve) => child.on("exit", (code) => resolve(code)));
  return { child, listening, exited, getStdout: () => stdout };
};

test("POST /restart responds 200 then the process exits 0", async (t) => {
  const PORT = 38301;
  const s = spawnServer(t, PORT);
  await s.listening;
  const res = await fetch(`http://127.0.0.1:${PORT}/restart`, { method: "POST" });
  assert.equal(res.status, 200);
  assert.match(await res.text(), /Restarting AlphaClaw/);
  const code = await Promise.race([
    s.exited,
    new Promise((_, rej) => setTimeout(() => rej(new Error("did not exit within 2s")), 2000).unref()),
  ]);
  assert.equal(code, 0);
});

test("second POST /restart within the cooldown gets 429", async (t) => {
  const PORT = 38302;
  const s = spawnServer(t, PORT);
  await s.listening;
  // Fire both before the ~250ms exit delay lands.
  const [r1, r2] = await Promise.all([
    fetch(`http://127.0.0.1:${PORT}/restart`, { method: "POST" }),
    fetch(`http://127.0.0.1:${PORT}/restart`, { method: "POST" }),
  ]);
  const statuses = [r1.status, r2.status].sort();
  assert.deepEqual(statuses, [200, 429]);
  assert.equal(await s.exited, 0);
});

test("GET /restart serves the status page and does NOT exit", async (t) => {
  const PORT = 38303;
  const s = spawnServer(t, PORT);
  await s.listening;
  const res = await fetch(`http://127.0.0.1:${PORT}/restart`);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /AlphaClaw failed to start/);
  // Still alive after the exit-delay window would have passed.
  await new Promise((r) => setTimeout(r, 500));
  assert.equal(s.child.exitCode, null, "server must not exit on GET /restart");
});

test("POST /restart exits even when the client disconnects mid-request", async (t) => {
  const PORT = 38304;
  const s = spawnServer(t, PORT);
  await s.listening;
  // Raw socket: send the POST, destroy immediately — no waiting for a response.
  await new Promise((resolve) => {
    const sock = connect(PORT, "127.0.0.1", () => {
      sock.write("POST /restart HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n");
      setTimeout(() => {
        sock.destroy();
        resolve();
      }, 50);
    });
  });
  const code = await Promise.race([
    s.exited,
    new Promise((_, rej) =>
      setTimeout(() => rej(new Error("did not exit within 2s of aborted restart")), 2000).unref(),
    ),
  ]);
  assert.equal(code, 0);
});

test("/health flips 200 -> 503 after the grace period, and logs the flip", async (t) => {
  const PORT = 38305;
  const s = spawnServer(t, PORT, { FAILURE_HEALTH_GRACE_MS: "500" });
  await s.listening;
  const early = await fetch(`http://127.0.0.1:${PORT}/health`);
  assert.equal(early.status, 200);
  await new Promise((r) => setTimeout(r, 800));
  const late = await fetch(`http://127.0.0.1:${PORT}/health`);
  assert.equal(late.status, 503);
  const lateZ = await fetch(`http://127.0.0.1:${PORT}/healthz`);
  assert.equal(lateZ.status, 503);
  assert.match(s.getStdout(), /health grace period expired/);
});

test("an old FAILURE_EPOCH makes /health 503 immediately on a fresh process", async (t) => {
  const PORT = 38306;
  const epoch = Math.floor(Date.now() / 1000) - 3600; // failure began an hour ago
  const s = spawnServer(t, PORT, { FAILURE_EPOCH: String(epoch) });
  await s.listening;
  const res = await fetch(`http://127.0.0.1:${PORT}/health`);
  assert.equal(res.status, 503, "grace must anchor to the supervisor epoch, not process start");
});

test("listen retries through EADDRINUSE until the port frees", async (t) => {
  const PORT = 38307;
  // Occupy the port on the wildcard address first, like a dying alphaclaw
  // holding :3000 (0.0.0.0 so the child's wildcard bind reliably collides).
  const blocker = createServer(() => {});
  await new Promise((r) => blocker.listen(PORT, "0.0.0.0", r));
  t.after(() => new Promise((r) => blocker.close(() => r())));
  const s = spawnServer(t, PORT);
  // Give it time to hit EADDRINUSE and start retrying.
  await new Promise((r) => setTimeout(r, 1500));
  assert.equal(s.child.exitCode, null, "server must not crash on EADDRINUSE");
  assert.match(s.getStdout(), /in use/i);
  await new Promise((r) => blocker.close(() => r()));
  await s.listening; // resolves once it finally binds
  const res = await fetch(`http://127.0.0.1:${PORT}/health`);
  assert.equal(res.status, 200);
});
