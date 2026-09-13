// Unit tests for claude-code/managed-settings.json — the Claude Code managed
// policy the image copies to /etc/claude-code/managed-settings.json.
//
// The Dockerfile only proves the file parses. These tests pin the policy
// itself: every key is one the Claude Code settings reference documents, at
// the path it documents, and every value is the restrictive one. A key that
// silently loses its value (or a nesting level) would leave a worker session
// unsandboxed with no build failure, which is exactly the failure this file
// exists to catch.
//
// Doc anchors (code.claude.com/docs/en):
//   managed-settings.md  "Place the file on each machine" -> the Linux path
//   sandboxing.md        "Enforce sandboxing with managed settings"
//   settings-reference.md#sandbox-enabled / -failifunavailable /
//                        -enableweakernestedsandbox /
//                        -allowunsandboxedcommands / -filesystem-denyread /
//                        -filesystem-allowread / -filesystem-allowwrite /
//                        -filesystem-allowmanagedreadpathsonly /
//                        -credentials-envvars /
//                        permissions.blockReadsOutsideWorkingDirectories /
//                        allowManagedPermissionRulesOnly /
//                        disableClaudeAiConnectors / allowedMcpServers /
//                        allowManagedMcpServersOnly / autoupdateschannel

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const FILE = join(REPO, "claude-code", "managed-settings.json");
const raw = readFileSync(FILE, "utf8");

test("managed-settings.json parses as JSON", () => {
  assert.doesNotThrow(() => JSON.parse(raw));
  assert.equal(typeof JSON.parse(raw), "object");
});

const policy = JSON.parse(raw);

test("sandbox is on, hard-fails when unavailable, and has no unsandboxed escape hatch", () => {
  assert.equal(policy.sandbox.enabled, true);
  assert.equal(policy.sandbox.failIfUnavailable, true);
  assert.equal(policy.sandbox.allowUnsandboxedCommands, false);
});

test("the sandbox can actually start inside the unprivileged container", () => {
  // sandboxing.md, Troubleshooting: "in an unprivileged container, bubblewrap
  // can't mount a fresh /proc filesystem, so sandboxed commands fail with a
  // bwrap error such as `Can't mount proc on /newroot/proc: Operation not
  // permitted`. Set enableWeakerNestedSandbox to true so the inner sandbox
  // bind-mounts the container's existing /proc instead."
  //
  // Paired with failIfUnavailable: true this is load-bearing, not an
  // optimisation -- without it the sandbox cannot start and EVERY worker
  // session exits at startup. settings-reference#sandbox-enableweakernestedsandbox
  // states the cost: "which exposes process information that a fresh mount
  // would hide. This reduces security; use it only when the outer container
  // already provides the isolation you need."
  assert.equal(policy.sandbox.enableWeakerNestedSandbox, true);
  // The compensating control: /proc stays denied at the filesystem layer, so
  // the bind-mounted /proc the weaker sandbox exposes is still unreadable.
  assert.ok(policy.sandbox.filesystem.denyRead.includes("/proc"));
});

test("sandbox.filesystem.denyRead blocks the neighbour and host-state paths", () => {
  const expected = [
    "/data/.env",
    "/data/agents",
    "/data/.openclaw",
    "/etc/claude-code",
    "/proc",
  ];
  assert.deepEqual(policy.sandbox.filesystem.denyRead, expected);
});

test("allowRead re-opens each worker's OWN tool state inside the denied HOME", () => {
  // settings-reference#permissions-blockreadsoutsideworkingdirectories: "Files a
  // tool reads from your home directory, such as `~/.gitconfig`, are denied with
  // the rest; re-open a specific path with `sandbox.filesystem.allowRead` when a
  // tool needs it." sandboxing.md, Configure sandboxing: "re-allow specific paths
  // within a denied region using `sandbox.filesystem.allowRead`. When read rules
  // overlap, the more specific path wins" -- so these narrower entries re-open
  // exactly these directories inside the broad `/data/agents` deny, and nothing
  // else. `~/` is "Relative to home directory" (same doc, path-prefix table), and
  // every acpx alias sets its own HOME under `env -i`, so one managed list opens
  // each worker's OWN dirs and no sibling's: /data/agents/<other>/home stays denied.
  //
  // /root/.claude/skills/gstack is the image's single gstack checkout that each
  // worker's ~/.claude/skills/gstack symlink (and the sibling skill links beside
  // it) resolves to. A symlink is only as readable as its target, and /root is a
  // home directory outside the working directories, so it needs its own entry.
  const expected = [
    "~/.codex",
    "~/.gemini",
    "~/.gstack",
    "~/.claude/skills",
    "/root/.claude/skills/gstack",
  ];
  assert.deepEqual(policy.sandbox.filesystem.allowRead, expected);
  // The worker HOME itself must never be re-opened wholesale: it holds
  // ~/.claude.json and ~/.claude/.credentials.json.
  for (const p of policy.sandbox.filesystem.allowRead) {
    assert.notEqual(p, "~");
    assert.notEqual(p, "~/");
    assert.equal(p.includes("*"), false, `${p}: no wildcard in a read allow`);
  }
});

test("allowWrite covers the tool state that is written, and not the skills tree", () => {
  // sandboxing.md, Filesystem isolation: "Default write behavior: read and write
  // access to the current working directory and its subdirectories, any
  // directories you've added ... plus the session temp directory". A worker's cwd
  // is /data/<client>, so nothing under its HOME is writable by default. codex
  // writes sessions and a refreshed auth under ~/.codex, agy under ~/.gemini, and
  // the gstack preamble writes ~/.gstack on EVERY skill run (sessions/, analytics/,
  // config.yaml, the artifacts git fetch).
  const expected = ["~/.codex", "~/.gemini", "~/.gstack"];
  assert.deepEqual(policy.sandbox.filesystem.allowWrite, expected);
  // The skills tree is read-only on purpose, and could not be made writable
  // anyway: sandboxing.md, Protected paths, covers "~/.claude, or the directory
  // CLAUDE_CONFIG_DIR points to" and states "There is no way to exempt one of
  // these paths: an allowWrite entry or an Edit allow rule that covers the path
  // doesn't lift the protection."
  assert.equal(policy.sandbox.filesystem.allowWrite.includes("~/.claude/skills"), false);
  assert.equal(
    policy.sandbox.filesystem.allowWrite.includes("/root/.claude/skills/gstack"),
    false,
  );
});

test("only managed settings may widen read access", () => {
  // sandboxing.md, Keep developers from widening the policy: "For array keys such
  // as excludedCommands and allowRead, Claude Code merges entries from every scope
  // the session loads, so a developer can append entries that widen the policy.
  // Set allowManagedReadPathsOnly to true in managed settings so that only
  // allowRead entries from managed settings are honored."
  //
  // Without it, a worker HOME's own .claude/settings.json could append
  // allowRead: ["/data/agents"] and undo the whole isolation posture.
  assert.equal(policy.sandbox.filesystem.allowManagedReadPathsOnly, true);
  // It locks allowRead ONLY. settings-reference#sandbox-filesystem-allowmanagedreadpathsonly:
  // "Claude Code still merges denyRead entries from every settings scope the
  // session loads." So the renderer's per-worker denyRead of the sibling client
  // roots keeps working, and sandbox.network.allowAllUnixSockets is a network key
  // this filesystem lock does not touch.
  assert.equal("allowManagedWritePathsOnly" in policy.sandbox.filesystem, false);
});

test("sandbox.credentials.envVars denies every worker-reachable brain variable", () => {
  // Generic names only. A per-client variable would be redundant -- the acpx alias
  // builds each worker's environment with `env -i`, so no GBRAIN_<CLIENT>_TOKEN is
  // in it to deny -- and it would carry client identities into a public image.
  const expected = [
    "GBRAIN_TOKEN",
    "GBRAIN_MAIN_TOKEN",
    "GBRAIN_REMOTE_TOKEN",
    "GBRAIN_HOME",
  ];
  const entries = policy.sandbox.credentials.envVars;
  assert.deepEqual(entries.map((e) => e.name), expected);
  for (const e of entries) {
    assert.equal(e.mode, "deny", `${e.name} must be denied, not masked`);
    // settings-reference: "The name must start with a letter or underscore and
    // contain only letters, digits, and underscores."
    assert.match(e.name, /^[A-Za-z_][A-Za-z0-9_]*$/);
    assert.deepEqual(Object.keys(e).sort(), ["mode", "name"]);
  }
});

test("the env-only scrub knob is deliberately NOT here", () => {
  // CLAUDE_CODE_SUBPROCESS_ENV_SCRUB would "strip credentials from all
  // subprocesses regardless of sandboxing" (sandboxing.md, Protect
  // credentials). It has NO entry in settings-reference.md -- it is an
  // environment variable (/docs/en/env-vars), not a settings key -- so it
  // cannot be delivered by this file. Its place is the acpx alias `env -i`
  // allowlist in the gateway config, and it carries a consequence that has to
  // be measured first: settings-reference#sandbox-autoallowbashifsandboxed
  // says it "turns auto-allow off", which would make every sandboxed Bash
  // command prompt -- fatal for an unattended oneshot worker.
  assert.equal("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB" in policy, false);
  assert.equal("env" in policy, false);
});

test("SECURITY: the policy carries variable NAMES only, never a value", () => {
  // A managed policy is a repo file and ships in the image. Anything that
  // looks like a credential value here would be baked into every layer.
  for (const e of policy.sandbox.credentials.envVars) {
    assert.equal("value" in e, false);
    assert.equal("injectHosts" in e, false);
  }
  assert.equal(/\b(sk-|ghp_|eyJ|Bearer )/.test(raw), false);
});

test("SECURITY: the policy names no client", () => {
  // The image is public. Every path and variable here is generic or resolved
  // per-session from `~`; a client slug in this file would publish the client
  // list, and would also be dead weight (a per-client env deny cannot fire under
  // the alias's `env -i`).
  for (const e of policy.sandbox.credentials.envVars) {
    assert.match(
      e.name,
      /^GBRAIN_(TOKEN|MAIN_TOKEN|REMOTE_TOKEN|HOME)$/,
      `${e.name}: only the generic brain variables belong in a public policy`,
    );
  }
  // Every /data path in the file is one of the three fleet-wide roots. A client
  // root is /data/<slug>, so anything else here would be a client name.
  const dataPaths = [...raw.matchAll(/"(\/data\/[^"]*)"/g)].map((m) => m[1]);
  assert.deepEqual(
    [...new Set(dataPaths)].sort(),
    ["/data/.env", "/data/.openclaw", "/data/agents"],
  );
});

test("reads outside the working directories are blocked", () => {
  assert.equal(policy.permissions.blockReadsOutsideWorkingDirectories, true);
});

test("managed settings are the only source of permission rules", () => {
  assert.equal(policy.allowManagedPermissionRulesOnly, true);
});

test("claude.ai connectors are off", () => {
  assert.equal(policy.disableClaudeAiConnectors, true);
});

test("only the loopback brain MCP endpoint is allowed, and only from managed settings", () => {
  assert.equal(policy.allowManagedMcpServersOnly, true);
  assert.deepEqual(policy.allowedMcpServers, [
    { serverUrl: "http://127.0.0.1:3131/*" },
  ]);
  // settings-reference#allowedmcpservers: each entry carries exactly one key.
  for (const entry of policy.allowedMcpServers) {
    assert.equal(Object.keys(entry).length, 1);
  }
});

test("background auto-updates follow the stable release channel", () => {
  // settings-reference.md#autoupdateschannel: "stable" trails "latest" by
  // about a week and skips releases with major regressions. Measured
  // 2026-09-13: Claude Code auto-updated itself past the image's pinned
  // version at first launch and a command that hit the update window failed
  // with `/usr/bin/claude: 2: exec: /usr/local/bin/claude: not found`.
  // Auto-updates stay ON (upstream-drift rule); this only bounds which
  // releases they can land on.
  assert.equal(policy.autoUpdatesChannel, "stable");
});

test("the policy declares no key outside the documented managed set", () => {
  // A typo'd or invented key is silently ignored by Claude Code, so the policy
  // would read as enforced while doing nothing.
  assert.deepEqual(Object.keys(policy).sort(), [
    "allowManagedMcpServersOnly",
    "allowManagedPermissionRulesOnly",
    "allowedMcpServers",
    "autoUpdatesChannel",
    "disableClaudeAiConnectors",
    "permissions",
    "sandbox",
  ]);
  assert.deepEqual(Object.keys(policy.sandbox).sort(), [
    "allowUnsandboxedCommands",
    "credentials",
    "enableWeakerNestedSandbox",
    "enabled",
    "failIfUnavailable",
    "filesystem",
  ]);
  assert.deepEqual(Object.keys(policy.permissions), [
    "blockReadsOutsideWorkingDirectories",
  ]);
  // settings-reference#sandbox-filesystem types the object as "allowWrite,
  // denyWrite, denyRead, and allowRead arrays, plus the allowManagedReadPathsOnly
  // and disabled Booleans" -- there is no write-side sibling of the managed lock.
  assert.deepEqual(Object.keys(policy.sandbox.filesystem).sort(), [
    "allowManagedReadPathsOnly",
    "allowRead",
    "allowWrite",
    "denyRead",
  ]);
  // `disabled` would switch filesystem isolation off entirely.
  assert.equal("disabled" in policy.sandbox.filesystem, false);
});
