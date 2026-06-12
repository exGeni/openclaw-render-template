# Tests

This template is mostly infrastructure (a Dockerfile, a boot script, a fallback
HTTP server, and Render config), so the tests are split by how much they cost to
run. All test files live here and are excluded from the image via `.dockerignore`.

| Layer        | What it checks                                                                 | Needs            | Command               |
|--------------|--------------------------------------------------------------------------------|------------------|-----------------------|
| **unit**     | `failure-server.js` routing + the "no secret leaks" property                   | node             | `npm run test:unit`   |
| **contract** | Static invariants in `start.sh` / `debug-start.sh` / `Dockerfile` / `render.yaml` (the "don't remove" items in `CLAUDE.md`) | bash, `shellcheck`, `bats` | `npm run test:contract` |
| **e2e**      | Builds the image, runs it with an empty `/data` (like Render's disk), asserts it stays Live and every documented invariant holds at runtime | docker, `bats`, curl | `npm run test:e2e`    |

```sh
npm test          # unit + contract (fast, no docker)
npm run test:e2e  # full image build + run (slow; ~minutes)
npm run test:all  # everything
```

## Why these layers

- **Unit** exercises the real `failure-server.js` artifact in a subprocess (no
  mocks). The security test plants sentinel secrets in the env and asserts they
  never appear in any HTTP response — the regression guard for "don't leak
  `/data/start.log` on the public failure page."
- **Contract** locks in the load-bearing config that, if removed, restart-loops
  the container: the `PATH` prepend (alphaclaw spawns `openclaw` by bare name),
  the `TMPDIR=/data/tmp` routing, the sticky-bit `mkdir` on boot, the tini/CMD
  wiring, and the "never touch bare `/tmp`" rule.
- **e2e** has two suites:
  - `docker.bats` mounts a **tmpfs over `/data`** so the dir starts empty at
    runtime, reproducing how Render's disk mount shadows the Dockerfile's
    build-time `mkdir`. If `/data/tmp` exists with its sticky bit afterwards,
    `start.sh` recreated it — the exact behavior `CLAUDE.md` says must survive
    every boot.
  - `stale-config.bats` seeds a real `/data` with an `openclaw.json` that still
    references the **old `@chrysb/alphaclaw` usage-tracker plugin path** (the
    breakage from switching the dependency to the git fork), boots the real
    container, and asserts alphaclaw prunes the dead path so OpenClaw accepts
    the config. Covers **both** onboarded and not-onboarded `/data`, because the
    prune must run on every boot (in `bin/alphaclaw.js`), not only the onboarded
    boot sequence.

## Local prerequisites

```sh
brew install bats-core shellcheck   # macOS
```

Node's built-in test runner (`node --test`) needs no extra packages.
