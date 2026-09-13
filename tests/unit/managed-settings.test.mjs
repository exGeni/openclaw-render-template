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
//                        -allowunsandboxedcommands / -filesystem-denyread /
//                        -credentials-envvars /
//                        permissions.blockReadsOutsideWorkingDirectories /
//                        allowManagedPermissionRulesOnly /
//                        disableClaudeAiConnectors / allowedMcpServers /
//                        allowManagedMcpServersOnly

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

test("sandbox.credentials.envVars denies every worker-reachable brain variable", () => {
  const expected = [
    "GBRAIN_TOKEN",
    "GBRAIN_MAIN_TOKEN",
    "GBRAIN_TIFLIS_TOKEN",
    "GBRAIN_SIMLINKS_TOKEN",
    "GBRAIN_DISPATCHER_TIFLIS_TOKEN",
    "GBRAIN_DISPATCHER_SIMLINKS_TOKEN",
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

test("SECURITY: the policy carries variable NAMES only, never a value", () => {
  // A managed policy is a repo file and ships in the image. Anything that
  // looks like a credential value here would be baked into every layer.
  for (const e of policy.sandbox.credentials.envVars) {
    assert.equal("value" in e, false);
    assert.equal("injectHosts" in e, false);
  }
  assert.equal(/\b(sk-|ghp_|eyJ|Bearer )/.test(raw), false);
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

test("the policy declares no key outside the documented managed set", () => {
  // A typo'd or invented key is silently ignored by Claude Code, so the policy
  // would read as enforced while doing nothing.
  assert.deepEqual(Object.keys(policy).sort(), [
    "allowManagedMcpServersOnly",
    "allowManagedPermissionRulesOnly",
    "allowedMcpServers",
    "disableClaudeAiConnectors",
    "permissions",
    "sandbox",
  ]);
  assert.deepEqual(Object.keys(policy.sandbox).sort(), [
    "allowUnsandboxedCommands",
    "credentials",
    "enabled",
    "failIfUnavailable",
    "filesystem",
  ]);
  assert.deepEqual(Object.keys(policy.permissions), [
    "blockReadsOutsideWorkingDirectories",
  ]);
});
