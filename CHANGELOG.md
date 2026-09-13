# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.1.2] - 2026-09-13

### Changed
- Bumped the pinned global `@anthropic-ai/claude-code` install (`Dockerfile:148`) from `2.1.252` to `2.1.270` — the version Claude Code's own auto-updater had already moved the live container to (see the `2.0.1.1` entry above for the failure that surfaced the drift). Same deliberate-bump-and-record discipline as the alphaclaw SHA pin; `tests/contract/dockerfile.bats` locks the pin format (`npm install -g @anthropic-ai/claude-code@X.Y.Z`) rather than the exact version, so no test expectation needed updating.

## [2.0.1.1] - 2026-09-13

### Changed
- `claude-code/managed-settings.json` now sets `autoUpdatesChannel: "stable"` (settings-reference.md#autoupdateschannel), so background auto-updates and `claude update` follow the roughly-week-old stable release rather than latest. Measured today in the live container: Claude Code auto-updated itself past the image's pinned version at first launch, and a command that hit the update window failed with `/usr/bin/claude: 2: exec: /usr/local/bin/claude: not found`. Auto-updates stay ON — per the upstream-drift rule, being behind upstream is itself a divergence — this only bounds which releases the updater can land the container on. `tests/unit/managed-settings.test.mjs` asserts the key, its value, and the new 7-key top-level set.

## [2.0.1.0] - 2026-09-13

### Added
- The image is now also the runtime for ACP-spawned Claude Code **workers**. Four additions, each pinned and contract-tested the way `@anthropic-ai/claude-code` already was:
  - `bubblewrap` and `socat` on the first apt line — Claude Code's Linux sandbox dependencies. With `sandbox.failIfUnavailable: true` in the managed policy, a worker session exits at startup without them.
  - `@openai/codex@0.154.0`, a pinned global npm install; its platform binary resolves through `optionalDependencies`, so one spec covers amd64 and arm64.
  - `agy` 1.2.2 (Antigravity CLI) as a baked static binary: `AGY_VERSION`, the immutable `AGY_BUILD` release path and the vendor's own SHA-512 per arch go in `baked-tools.env`, and the `tools` stage verifies them like Caddy and Bun. The vendor's `curl | bash` installer is not used — it pipes into a shell (contract-forbidden here) and resolves a moving manifest. `ENV AGY_CLI_DISABLE_AUTO_UPDATE=true` stops the 15-minute self-updater from replacing the verified binary.
  - gstack at commit `71f6048e` (VERSION 1.84.1.0), cloned into `/root/.claude/skills/gstack` and built with its own `./setup`, per gstack `docs/OPENCLAW.md` "Installation" step 1. Only step 1 is image state; the ClawHub native skills and the dispatch block are gateway/volume state.
- `/etc/claude-code/managed-settings.json`, copied from the new repo file `claude-code/managed-settings.json` (root-owned `0644`, parsed by `node` at build). Sandbox on with no unsandboxed retry, `sandbox.enableWeakerNestedSandbox: true`, `denyRead` over `/data/.env`, `/data/agents`, `/data/.openclaw`, `/etc/claude-code` and `/proc`, `credentials.envVars` `deny` for every `GBRAIN_*` variable (names only), reads outside the working directories blocked, permission rules and the MCP allowlist managed-only, claude.ai connectors off, and one allowed MCP endpoint at `http://127.0.0.1:3131/*`. A new unit test parses the file and asserts every key; new contract tests cover the pins, the COPY path and ownership, and the absence of any `hooks/` directory or launcher script in the image.

### Notes
- Measured size of this image on amd64: **7.00 GB disk / 1.78 GB content** (`docker images`), against 3.28 GB / 773 MB for the previous image and 1.78 GB / 405 MB for the closest artifact to 2.0.0.2. The README soft budget now reads `+300 MB over the 2.0.1.0 image`: the baseline it names includes the gbrain CLI layer (added 2026-09-03, itself already past the old 2.0.0.2 ceiling) and the worker executor toolchain. Largest layers, byte-sorted: gstack + `./setup` 2.18 GB, app `npm install` 570 MB, apt line 506 MB, baked binaries 418 MB, gbrain CLI 355 MB, playwright deps 351 MB, codex 339 MB, claude-code 217 MB. Note that `sort -h` mis-orders `docker history` sizes and hid the largest layer; sort numerically.
- Both bun layers now purge bun's download cache in their own RUN (`bun pm cache rm`), the counterpart of the `npm cache clean --force` every npm layer already ran, with `test ! -d /root/.bun/install/cache` asserting it and a contract test requiring it of every bun layer. Measured effect: inside the container `/root/.bun` falls from 1.4 GB to 339 MB, but the image moves only ~60 MB (gstack layer 2.21 → 2.18 GB, gbrain layer 383 → 355 MB, image 7.06 → 7.00 GB). The two metrics disagree by ~1 GB and the probes available here did not explain the gap; treat `docker history` per-layer numbers as indicative and measure a real push with `docker save` before tuning size further.
- The bundled browser is kept deliberately. gstack ships a documented opt-out (`GSTACK_SKIP_PLAYWRIGHT=1`, 656 MB) and OpenClaw's own `docs/OPENCLAW.md` "Installation" names no browser, but the browser skills (`/browse`, `/qa`, `/scrape`, `/design-review`, `/make-pdf`, `/diagram`) are load-bearing for website work, which is what the `playwright install-deps chromium` layer was added for.
- `sandbox.enableWeakerNestedSandbox: true` is load-bearing in this topology, not a relaxation taken for convenience. sandboxing.md, Troubleshooting: *"in an unprivileged container, bubblewrap can't mount a fresh `/proc` filesystem, so sandboxed commands fail with a `bwrap` error such as `Can't mount proc on /newroot/proc: Operation not permitted`. Set `enableWeakerNestedSandbox` to `true` so the inner sandbox bind-mounts the container's existing `/proc` instead."* The openclaw container is unprivileged, so with `failIfUnavailable: true` and this key absent, every worker session would exit at startup. The vendor states the cost — *"exposes process information that a fresh mount would hide … use it only when the outer container already provides the isolation you need"* — and `/proc` stays in `denyRead` as the compensating control.
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` was considered and left out: it has no entry in settings-reference.md (it is an env var, not a settings key), so this file cannot deliver it, and it "turns auto-allow off", which would make every sandboxed Bash command prompt an unattended worker. Its place is the acpx alias `env -i` allowlist in the gateway config.
- gstack stays at `/root/.claude/skills/gstack` rather than a shared `/opt` root: `setup:65,2119,2126` gate the Claude install branch on the parent directory being named `skills`, and from anywhere else `setup:2166-2168` symlinks the tree into `~/.claude/skills/gstack` regardless. Workers reach it through a renderer-created symlink in each worker HOME; the image seeds no HOME.
- Not verified by a build in this change: `npm test` (unit + contract, no Docker) is green apart from a failure that predates it (`Dockerfile: declares no ARG` vs the `ARG GBRAIN_REF` line added with the gbrain CLI layer). `npm run test:e2e` builds the image and was not run.

## [2.0.0.6] - 2026-09-09

### Changed
- Updated the bundled alphaclaw from 0.9.81 to 0.9.82: accurate gateway memory reporting — per-process attribution (PSS-based), container-level memory monitoring and alerts, a memory-details view in the Watchdog tab, and a doctor card for container memory. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.5] - 2026-09-08

### Changed
- Updated the bundled alphaclaw from 0.9.80 to 0.9.81: Upgrade tab fixes — live release catalog, declared apply intent, a bounded backup rung, and a "Back up now" action. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.4] - 2026-09-07

### Changed
- Migrated the image runtime from `node:22-slim` to `node:24-slim` (all three node stages: `pins`, `tools`, and the final image). Required by the new alphaclaw pin: alphaclaw 0.9.80 and its exactly-pinned OpenClaw 2026.9.3 both gate installs on Node `>=24.16.0 <25 || >=26.1.0` (enforced by OpenClaw's preinstall check, which fails the Docker build loudly on an old base). `package.json` `engines` now mirrors that range, CI runs unit/contract on Node 24, and the contract greps lock the `node:24-slim` stages in.
- Updated the bundled alphaclaw from 0.9.77 to 0.9.80, picking up three upstream releases: the live-tier downgrade re-stamp (0.9.78), hardened upgrade recovery / chat delivery / status reporting (0.9.79), and the Node 24.16 runtime + OpenClaw 2026.9.3 pin (0.9.80).

## [2.0.0.3] - 2026-09-06

### Added
- Baked a fixed toolset into the image so operators and the agent no longer hand-install it into the ephemeral container layer after every deploy: Caddy 2.11.4 (GitHub release tarball, SHA-512 verified against the upstream `checksums.txt`), Tailscale 1.102.3 `tailscale` + `tailscaled` (pkgs.tailscale.com static tarball, SHA-256 verified against the `.sha256` sidecar), Bun 1.4.2 `bun` + `bunx` (GitHub release zip, SHA-256 verified against `SHASUMS256.txt`), monolith 2.10.1 built from source at git rev `47affd5f9070eb01a94045ce31923e577f9a9162` with `cargo install --locked` in a digest-pinned `rust:1.98.0-slim-bookworm` stage (the upstream aarch64 prebuilt links `libssl1.1`, which bookworm lacks), PostgreSQL client 17 (`psql`, `pg_dump`, `pg_restore` from the signed PGDG apt repo, key verified by fingerprint `B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`; installs to `/usr/lib/postgresql/17/bin` with the Debian `pg_wrapper` layout; no server package), `git-lfs`, `jq`, plus the support packages `ca-certificates`, `openssl`, `util-linux` (`flock`) and `psmisc` (`fuser`). Nothing is started: the image launches no `tailscaled` or `caddy`, opens no new port, and a fresh deploy reaches the setup UI exactly as before.
- New `baked-tools.env` pin manifest at the repo root — the single source of versions, checksums, `MONOLITH_REV` and `PG_MAJOR` for every build stage, shipped verbatim in the image at `/etc/baked-tools.env` so a live box can `cat` its exact pins.
- New tests. `tests/contract/tools.bats` (runs in `npm test`) statically locks in the manifest format and that every pin is referenced, the `pins`/`tools`/`monolith-build` stages and the load-bearing layer order, the no-`ARG` rule, downloads == checksum checks, the PGDG fingerprint/`signed-by`/client-only/purge-`gpg` discipline, a no-daemon guard over the Dockerfile and `start.sh` (with positive and negative controls), the `EXPOSE`/`CMD`/`COPY`-source surface, the `.dockerignore` allowlist, CI `timeout-minutes`, and `AGENTS.md == CLAUDE.md`. `tests/e2e/tools.bats` (runs in `npm run test:e2e`) checks every baked binary offline with `docker run --network none` (version == pin, `ldd` shared-library resolution, arch consistency, PATH/shim precedence), proves the checksum gate fails the build on a mutated manifest, boots the image credential-free and asserts `/health` 200 with no `tailscaled`/`caddy`/`monolith` process and no tool port listening, boots against a reused `/data` volume, asserts prompt shutdown, and exercises the tools functionally (a `git lfs` commit lands an object in `.git/lfs/objects`, `caddy validate`, `jq`, `openssl`, `flock`).

### Changed
- `.dockerignore` is now an allowlist: `*` followed by a `!` line for each Dockerfile `COPY` source (plus `debug-start.sh` for the documented debug detour). Nothing unlisted can enter the build context, and a future `COPY` of an unlisted file fails the build loudly (contract-tested against the Dockerfile's actual `COPY` sources).
- The new apt/PGDG layer sits directly below the original apt line and above both npm layers, so alphaclaw pin bumps never re-fetch apt indexes or move the PostgreSQL minor; the pinned claude-code install and the app `npm install` are unchanged.
- `git lfs install --system` runs at build time: the LFS filter lives in `/etc/gitconfig` and is inert for any repo whose `.gitattributes` has no `filter=lfs` entries (alphaclaw's workspace repo has none).
- CI jobs gained `timeout-minutes` (20 for unit + contract, 60 for docker e2e) so a stalled download or build is bounded instead of running to GitHub's cap.
- Converted the latent no-op bare `!` assertions in `tests/e2e/stale-config.bats` and `tests/e2e/supervise-e2e.bats` to enforcing `run` + status checks, capturing `docker logs`/`docker exec` output into a variable first so the nested `run grep` cannot clobber `$output` (closes the `TODOS.md` P1 item ledgered in 2.0.0.2).
- Image size grows by about 236 MB: 1,375,861,315 → 1,611,978,214 bytes (+17%), measured on linux/amd64 with Docker 25 — inside the +300 MB soft budget over the 2.0.0.2 image (see the README's maintenance policy).
- Updated the bundled alphaclaw from 0.9.56 to 0.9.76 (pin 3f9b27b → 01d3b66), which landed on main as six pin-bump commits after 2.0.0.2 (0.9.66, 0.9.67, 0.9.68, 0.9.69, 0.9.75, 0.9.76); OpenClaw moves to the 2026.9.2 stable line. This release was built and e2e-tested against 01d3b66.

### Security
- Pins live in a plain file (`baked-tools.env`), never Dockerfile `ARG`: Render turns every service env var into a `--build-arg`, so an `ARG` default would be a dashboard-overridable pin.
- Every download is checksum-verified before it is unpacked (`sha512sum -c` / `sha256sum -c`, always as the last pipeline stage because dash has no `pipefail`), and every apt source is signed — the PGDG key must contain exactly one primary key with the pinned fingerprint before apt ever sees it. Any upstream change fails the build by design and is bumped deliberately.
- The image starts no daemon, opens no new port, adds no cron job, and requires no credentials to reach the setup UI; installing a tool does not enable it.
- Build tooling (`unzip`, `gpg`, the Rust toolchain) never lands in the runtime image: downloads and the monolith compile happen in throwaway stages, and `gpg` is purged (`apt-get purge --auto-remove`) in the same `RUN` once the PGDG client package is installed, so it never reaches a committed layer.

## [2.0.0.2] - 2026-09-01

### Changed
- Tightened the default `ORPHAN_SWEEP_PATTERN` from `openclaw[^ ]* gateway` to `(^|[ /])openclaw[^ ]* gateway run( |$)`: the post-exit orphan sweep matches full process argv, and rescue panes are exactly where operators type commands mentioning the gateway mid-incident — the old pattern could kill the operator's own debugging commands. Both real gateway argv shapes stay matched (contract-tested, including rescue-pane argv that merely mentions the gateway).
- Pinned the global `@anthropic-ai/claude-code` install to an exact version (2.1.252) so image rebuilds can no longer silently float it to latest — the same deliberate-bump discipline as the alphaclaw SHA pin (contract-tested). Hardened test enforcement along the way: converted silent no-op `! command` assertions (exempt from bats errexit when non-final) to enforcing `run` + status checks across the contract suites and the Docker e2e suite (the remaining e2e occurrences are ledgered in `TODOS.md`), including the public-page secret-leak check's intermediate responses, and made the supervise harness leak-free (stub and decoy processes now forward TERM to their children).

### Added
- Install `tmux` in the image so alphaclaw's local Claude Code rescue sessions (shipped in 2.0.0.1) use tmux hosting and survive alphaclaw restarts, instead of the degraded `script(1)` hosting that dies with the process ("tmux is not installed — sessions use script(1) hosting and die with AlphaClaw"). Sessions still end on a full container restart/redeploy — tmux servers are in-memory by nature. Guarded at three layers: contract tests pin `tmux` in the apt line (image and CI) and prove the default `ORPHAN_SWEEP_PATTERN` cannot match a rescue session's typical tmux argv (payload argv that itself contains "openclaw … gateway", and runtime pattern overrides, remain a documented accepted risk), a supervise-harness test proves a tmux session (same pane PID) survives an exit-75 supervisor relaunch while a sweep-tagged decoy dies, and the Docker e2e executes `tmux -V` inside the built image. CI installs tmux explicitly so the survival test can never silently skip.

## [2.0.0.1] - 2026-08-31

### Changed
- Updated the bundled alphaclaw from 0.9.49 to 0.9.56, picking up seven upstream releases: chat reliability rework (protocol v2 bridge, durable run outcomes, resumable streams), gateway memory-leak detection with opt-in pre-OOM auto-restart, one-click authenticated OpenClaw dashboards (appears once the bundled OpenClaw is upgraded to 2026.8.1+ from the Upgrade tab — this release still pins OpenClaw 2026.7.1-2), local Claude Code rescue sessions, Drift Doctor delivery fixes, actionable error messages, and a verbose notification toggle.
