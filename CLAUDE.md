# Agent notes for openclaw-render-template

This is a Docker-based one-click Render deploy of [`alphaclaw`](https://github.com/garrytan/alphaclaw) (the `garrytan/alphaclaw` fork), which wraps OpenClaw to run as a 24/7 service. Notes here are for AI agents (or future humans) who need to understand non-obvious behavior fast.

## Layout

- `Dockerfile` — multi-stage image build: stages `pins`, `tools`, `monolith-build`, then the final `node:24-slim` stage (the header comment is the pipeline diagram — see "Baked tools" below). `CMD` is `/start.sh`; `tini -g` is PID 1 (`-g` signals the whole process group — load-bearing for prompt shutdown, see "Boot supervisor"). The final stage has **two apt `RUN`s**: the original line (git, curl, procps, python3, make, g++, cron, tini, vim, screen, tmux — `tmux` is on purpose: alphaclaw's local Claude Code rescue sessions probe for it (`tmux -V`), and without it they degrade to `script(1)` hosting that dies with every alphaclaw restart; still contract-tested) and, directly below it, the apt/PGDG `RUN` (support packages `ca-certificates openssl jq git-lfs psmisc util-linux` plus the PostgreSQL *client* from the signed PGDG repo; `gpg` is purged afterwards). Both sit *above* the npm layers so alphaclaw pin bumps never re-fetch apt; editing either rebuilds the pinned claude-code layer and the bounded app `npm install` on the next deploy: the global `@anthropic-ai/claude-code` install is **version-pinned** (bump it deliberately and record it in `CHANGELOG.md` + `VERSION`, same discipline as the alphaclaw SHA — contract-tested), and the app `npm install` re-resolves its unlocked ranges (bounded — alphaclaw is SHA-pinned and pins `openclaw` exactly). Verify the alphaclaw version post-deploy.
- `baked-tools.env` — the pin manifest for the baked tools (versions, checksums, `MONOLITH_REV`, `PG_MAJOR`). Plain shell-sourceable `KEY=value`, consumed by every Dockerfile stage (`pins` splits it; `tools` and the final smoke source it whole; `monolith-build` and the apt/PGDG RUN source the split-out `/monolith.env` / `/pg.env`) and shipped verbatim in the image at `/etc/baked-tools.env`. Bump discipline is the alphaclaw-SHA one: edit the value, run `npm test` + `npm run test:e2e`, record it in `CHANGELOG.md` + `VERSION`. Never `ARG` (see "Baked tools").
- `.dockerignore` — an **allowlist**: `*` first, then one `!` line per Dockerfile `COPY` source (plus `debug-start.sh` for the debug detour). Adding a `COPY` of a new repo file means adding a `!` line, or the build fails loudly; the set is contract-tested against the Dockerfile's actual `COPY` sources.
- `render.yaml` — Render Blueprint config. Service is web, plan starter, port 3000, health check `/health`, `/data` 10 GB persistent disk.
- `package.json` — pins `alphaclaw` as a **git dependency** (`git+https://github.com/garrytan/alphaclaw.git#<commit-sha>`), not an npm-registry package. `openclaw` arrives as a transitive dep. Four non-obvious details, all load-bearing:
  - **Pin a full commit SHA, never `#main`.** The Dockerfile copies only `package.json` into a layer and runs `npm install` there. With a moving ref like `#main`, that layer's cache key never changes, so Docker (locally *and* on Render) keeps reusing the npm-install layer built when the ref was first resolved — alphaclaw updates silently never land in new images. This actually happened in the field: a config-migration fix was merged to the fork but deploys kept shipping the old alphaclaw. Pinning the SHA makes every alphaclaw update an explicit `package.json` edit, which changes the layer hash and forces a real reinstall. To update: `git ls-remote https://github.com/garrytan/alphaclaw.git main`, paste the new SHA, reinstall, run tests, and record the bump in `CHANGELOG.md` + `VERSION`.
  - **Explicit `git+https://`, not the `github:` shorthand.** npm's `hosted-git-info` canonicalizes GitHub deps to `git+ssh://git@github.com/…` (you'll see that in `package-lock.json`'s `resolved` — that's cosmetic). The `node:24-slim` Docker build has no SSH key, so the spec in `package.json` must force HTTPS or the build fails fetching the dep. (The Dockerfile does a fresh `npm install` from `package.json` and never copies the lockfile, so the `package.json` spec is what drives the fetch.)
  - **The dep key is `alphaclaw`.** npm uses the key as the install-folder alias, so it lands at `node_modules/alphaclaw/` even though the fork's internal `name` is still `@chrysb/alphaclaw`. The template only ever invokes the `alphaclaw`/`openclaw` *binaries* by name, never `require("@chrysb/alphaclaw")`, so the name mismatch is harmless.
  - **The fork carries a `prepare` script.** It builds the gitignored UI artifacts (`lib/public/dist/`, generated Tailwind CSS) at install time. npm skips `prepack` for git installs but *does* run `prepare`, so without it the setup UI ships blank.
- `start.sh` — boot **supervisor** (see "Boot supervisor" below). Not a one-shot launcher.
- `failure-server.js` — public failure-status page with a `POST /restart` escape hatch and a health-grace flip (see "Boot supervisor").
- `debug-start.sh` — diagnostic boot script (see "Debug path" below).
- `VERSION` + `CHANGELOG.md` — template release metadata; every alphaclaw pin bump gets a VERSION bump and a CHANGELOG entry.
- `TODOS.md` — deferred-work ledger (mostly items surfaced by ship reviews, with effort/priority and the context to pick them up cold); when a ship completes one, move it to the Completed section with the shipping version.

## Critical PATH detail (don't remove)

`alphaclaw start` spawns `openclaw` by **bare name** in two places inside `node_modules/alphaclaw/lib/server/gateway.js`:

- A preflight `execSync("openclaw plugins list --json", ...)`
- The gateway run: `spawn("openclaw", ["gateway", "run"], ...)`

Both inherit `process.env.PATH` from the alphaclaw process. The default `node:24-slim` PATH is `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` — `/app/node_modules/.bin` is **not** on it, and that's where `openclaw` lives. If PATH isn't fixed, alphaclaw crashes with `Error: spawn openclaw ENOENT` and the container restart-loops.

The Dockerfile addresses this two ways (both intentional, keep both):

1. `ENV PATH="/app/node_modules/.bin:$PATH"` — primary fix
2. `RUN ln -sf /app/node_modules/.bin/{openclaw,alphaclaw} /usr/local/bin/...` — belt-and-suspenders so even a future refactor that drops the ENV line still works

## Temp dir on the persistent disk (`/data/tmp`)

Temp is routed to `/data/tmp` (the persistent disk) instead of the container's ephemeral `/tmp`, so a 24/7 service doesn't churn/fill the ephemeral layer. OpenClaw is mid-migration from hardcoded `/tmp` callsites to `TMPDIR`-aware APIs ([openclaw#11587](https://github.com/openclaw/openclaw/issues/11587)); the env-var route covers everything that respects the standard temp APIs.

Set in **two** places (same belt-and-suspenders reasoning as PATH — keep both):

1. `ENV TMPDIR/TEMP/TMP=/data/tmp` in the Dockerfile — primary.
2. `export TMPDIR=… ` + `mkdir -p /data/tmp && chmod 1777` in `start.sh` — load-bearing. `/data` is a **runtime-mounted disk**, so the Dockerfile's build-time `mkdir /data/tmp` is shadowed at runtime; `start.sh` must (re)create the dir on every boot. The re-export also survives Render runtime env munging.

**`/tmp` itself is deliberately left untouched** — never symlinked, bind-mounted, or moved. We only *add* `/data/tmp` as the `TMPDIR` preference; that's the whole mechanism. Any code that still hardcodes `/tmp` keeps using the container's ephemeral `/tmp`, which is fine and intended. Do **not** redirect `/tmp` wholesale: Render containers aren't privileged (`mount --bind` fails anyway), and pointing all of `/tmp` at the 10 GB disk risks filling it and adds disk I/O for every process's scratch. Leave `/tmp` be.

## Baked tools (Dockerfile stages)

The image bakes Caddy, Tailscale, Bun, monolith, the PostgreSQL client, git-lfs, jq and a few support packages so they survive redeploys (versions, paths and licenses are in the README's "Baked-in tools" table). The Dockerfile's header comment is the pipeline diagram — **keep it in sync with the stages** whenever you touch them. The load-bearing rules:

- **Stages.** `pins` (`FROM node:24-slim`) copies `baked-tools.env` and splits it into `/monolith.env` (the `MONOLITH_*` lines) and `/pg.env` (`PG_MAJOR`). It exists purely to isolate cache keys: BuildKit keys `COPY --from` on file content, so a Caddy or Bun bump never recompiles monolith or re-runs the apt/PGDG layer. `tools` (`FROM node:24-slim`) installs `ca-certificates`/`curl`/`unzip` build-only, downloads and checksum-verifies the static Caddy/Tailscale/Bun release artifacts into `/out/usr/local/bin/`, and stages the manifest at `/out/etc/baked-tools.env` — none of that tooling reaches the runtime image. `monolith-build` compiles monolith from the pinned git rev with `cargo install --locked` because the upstream aarch64 prebuilt links `libssl1.1`, which bookworm lacks; its base `rust:1.98.0-slim-bookworm@sha256:…` is digest-pinned to the **multi-arch index** (the digest resolves to per-arch images on amd64 and arm64 alike). The final stage copies binaries from `tools` and `monolith-build` and smokes every `--version` against `/etc/baked-tools.env`, so a mismatch fails the build.
- **Never `ARG`.** Render turns every service env var into a `--build-arg`, so an `ARG` default would be a dashboard-overridable pin. Pins live only in `baked-tools.env` (a plain file, `COPY`ed and sourced); there must be no `ARG` instruction anywhere in the Dockerfile (contract-tested).
- **Checksum / fingerprint discipline.** Every download is verified before it is unpacked (`echo "<sum>  file" | sha512sum -c -` / `sha256sum -c -`). The PGDG key is parsed with `gpg --show-keys --with-colons` and must contain **exactly one** primary key whose fingerprint equals the literal in the RUN (`B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`); only then is it installed under `/usr/share/keyrings` and referenced via `signed-by=`. Any upstream change (re-tagged asset, rotated key) fails the build by design and is bumped deliberately, like the claude-code pin.
- **dash has no `pipefail`.** `RUN` lines execute under `/bin/sh` (dash), where `set -e` only sees the *last* command of a pipeline. So the verifying command must be the final pipeline stage (`… | sha256sum -c -`), or the value is captured with `$(…)` and tested under `set -eu` (as the fingerprint checks do). Never write `curl … | tar` where the download's failure matters.
- **No literal `/tmp` in Dockerfile `RUN`s** (the existing contract test rejects any non-comment `/tmp`); scratch dirs come from `mktemp -d`. That is also why the apt/PGDG RUN sits *above* `ENV TMPDIR=/data/tmp`: at that point in the build the `RUN mkdir -p /data/tmp` further down has not run yet, so `mktemp` under that `TMPDIR` would fail.
- **No daemons.** The image never *launches* `tailscaled` or `caddy`: at build the Dockerfile only runs `caddy version` and `test -x /usr/local/bin/tailscaled` (`tailscaled --version` is exercised by the e2e suite), and `start.sh` touches neither. A static contract guard greps the comment-stripped Dockerfile and `start.sh` for command-position `tailscaled`, `tailscale up|serve|funnel|set|login` and `caddy run|start|reverse-proxy|file-server` — it only catches straightforward additions; the e2e process/port checks on the booted container are the real property.
- **`git lfs install --system`** at build (decision 3A): the LFS filter is in `/etc/gitconfig`, no service. It is inert for repos without `filter=lfs` attributes (alphaclaw's workspace repo has none) and activates for any repo that has them, including operator-cloned ones — the README points operators at `git lfs install --local --skip-smudge` (per repo; without `--local` it writes the ephemeral `~/.gitconfig`).
- **agy is a baked tool, not an npm install.** Its pins (`AGY_VERSION`, `AGY_BUILD`, `AGY_SHA512_*`) live in `baked-tools.env` with everything else, and `AGY_BUILD` is the immutable release path segment read out of the vendor's per-platform manifest. Bumping it means re-reading that manifest for BOTH arches, not editing the version alone.
- **PostgreSQL major, not minor.** The package is `postgresql-client-${PG_MAJOR}` with `PG_MAJOR` from `baked-tools.env`; the minor floats inside the signed PGDG repo. Exact-minor pins expire when PGDG rotates its pool (time-bomb build failures), which is why they are not used. Never hardcode the major — every package name, path and smoke derives from `${PG_MAJOR}` (contract-tested).
- **Placement.** The apt/PGDG RUN goes directly below the original apt line and above `npm install -g @anthropic-ai/claude-code`, so alphaclaw pin bumps never re-fetch apt. The tool `COPY --from` lines and their smoke go below the shim RUN (a tool bump never re-resolves app deps) and above `COPY start.sh` (a start.sh hotfix never re-downloads tools). Both orderings are contract-tested by line number.

## Worker executors and the managed Claude Code policy

The image is also the runtime for **ACP-spawned Claude Code workers** — OpenClaw's `sessions_spawn(runtime: "acp")` starts `claude` inside this container, under a per-client `HOME` on `/data`, with a per-client working directory. Everything a worker needs at the *binary* level is image-owned and pinned; everything per-client (the HOME, the login, the brain client block, the gateway aliases) is volume/gateway state and is deliberately NOT baked here.

- **`bubblewrap` + `socat`** are on the first apt line. They are Claude Code's Linux sandbox dependencies — bubblewrap is "the unprivileged sandboxing tool that enforces filesystem isolation" and socat "the relay used to route network traffic through the sandbox proxy" (`code.claude.com/docs/en/sandboxing`, "Set up Linux and WSL2"). They are not optional: the managed policy sets `sandbox.failIfUnavailable: true`, so a worker session **exits at startup** if either is missing. Debian-versioned rather than exact-pinned, for the same reason the PostgreSQL minor floats — an exact apt pin is a time-bomb when the pool rotates. Contract-tested like `tmux`.

  Known limitation, not yet measured here: bubblewrap cannot mount a fresh `/proc` in an unprivileged container, and the vendor's fix is `sandbox.enableWeakerNestedSandbox` (`sandboxing.md` → Troubleshooting). That key is **not** in the policy, so if the sandbox turns out to be unavailable in an ACP session the worker refuses to start, loudly, instead of silently running unsandboxed. Measure before changing it: the setting "exposes process information to sandboxed commands that a fresh `/proc` mount would hide."
- **`codex`** — `@openai/codex`, a pinned global npm install, exactly like the `claude-code` pin (`npm install -g @openai/codex@<x.y.z>`; contract-tested). The package resolves its platform binary through `optionalDependencies` (`@openai/codex-linux-{x64,arm64}`), so one spec covers both arches.
- **`agy`** — the Antigravity CLI (Gemini family), a baked static binary like Caddy/Bun rather than an npm install. The vendor's documented install pipes a script into a shell and resolves a moving per-platform manifest; both are unusable here (pipe-to-shell is contract-forbidden, and a moving manifest is not a pin). `baked-tools.env` instead pins `AGY_VERSION`, the immutable `AGY_BUILD` release path out of that manifest, and the vendor's own SHA-512 per arch — so the `tools` stage fetches exactly what the installer would have fetched and verifies it the same way. The tarball holds one file named `antigravity`; it is installed as `agy`, as the vendor installer does. `ENV AGY_CLI_DISABLE_AUTO_UPDATE=true` is load-bearing: agy self-updates on a 15-minute debounce and would otherwise replace the verified binary at runtime.
- **`gstack`** — cloned into `/root/.claude/skills/gstack` and installed with its own `./setup`, per gstack `docs/OPENCLAW.md` "Installation" step 1 and `README.md` "Step 1: Install on your machine". `garrytan/gstack` ships no tags, so the pin is the commit, and the build asserts the resulting `VERSION` file. Only step 1 of that section is image state: the four ClawHub native skills, the AGENTS.md dispatch block and the verification spawn are gateway/volume state. `./setup` needs the Chromium shared libraries the `playwright install-deps` layer already installs — that layer exists for exactly this.

  **`./setup` installs under `$HOME`, and `HOME` is `/root` at build time.** A worker running under a per-client HOME on `/data` does not see `/root/.claude/skills/gstack`. Seeding that HOME is the renderer's job on the volume, not the image's; this layer only guarantees a pinned, built tree exists in the image to seed from.
- **`/etc/claude-code/managed-settings.json`** — the managed Claude Code policy, `COPY`ed from the repo file `claude-code/managed-settings.json`, root-owned `0644`, and parsed by `node` at build so malformed JSON can never reach a worker. `managed-settings.md` ("Place the file on each machine") gives that path for Linux and WSL. Managed settings sit above every other settings level, so nothing in a worker HOME or on `/data` can weaken it. The policy: sandbox on, hard-fail if unavailable, no unsandboxed retry; `denyRead` over `/data/.env`, `/data/agents`, `/data/.openclaw`, `/etc/claude-code`, `/proc`; `credentials.envVars` `deny` for every `GBRAIN_*` variable a worker could otherwise read out of its environment (**names only — never a value; the file ships in the image**); reads outside the working directories blocked; permission rules and the MCP allowlist managed-only; claude.ai connectors off; one allowed MCP endpoint, `http://127.0.0.1:3131/*`. `tests/unit/managed-settings.test.mjs` asserts each of those and rejects any key outside the documented set — a typo'd key is silently ignored by Claude Code, so the policy would read as enforced while doing nothing.

  **No `hooks/` directory and no launcher script are baked in.** The acpx alias supplies `HOME`, `PATH` and `OPENCLAW_SESSION` through `env -i` in the gateway config; the image stays out of the spawn path. Contract-tested.

## Boot supervisor (`start.sh` → `failure-server.js`)

`start.sh` supervises `alphaclaw start` in a loop; it is NOT a one-shot launcher (the old one-shot + `exec failure-server` turned every alphaclaw exit — including intentional restarts — into a permanent outage parked on a forever-200 failure page; alphaclaw #22).

Restart policy (env-overridable knobs in parentheses; numerics are validated with logged fallback):

- **exit 75** (EX_TEMPFAIL — newer alphaclaw's `restartProcess()` contract) → relaunch immediately; never counts toward the failure threshold. Sub-5s runs get a 1s spin brake (`SPIN_BRAKE_SECS`); 10 consecutive sub-5s 75s log a possible-loop WARNING.
- **any exit after a run > 60s** (`RAPID_WINDOW_SECS`) → healthy-enough: counter and `FAILURE_EPOCH` reset, relaunch. Covers older alphaclaw that exits 1 to request a restart. Repeated non-zero long-run exits log a WARNING streak.
- **exit within 60s** → rapid failure: `fails*5s` backoff (`BACKOFF_STEP_SECS`), cumulative backoff capped at 30s (`CUM_BACKOFF_CAP_SECS`) — Render restarts an instance after ~60s of failed health checks, so the failure page must be reachable well before that.
- **5 consecutive rapid failures** (`MAX_RAPID_FAILS`) → run `failure-server.js` as a **loop child** (never `exec`). Its exit (Restart button) resets the counter and retries alphaclaw.

Other load-bearing details:

- **`FAILURE_EPOCH`** (unix seconds) is set on first entry into failure mode and passed to the failure server; it survives Restart-button cycles and clears only on a >60s run. The failure server anchors its health-grace clock to it — `/health` 200s for `FAILURE_HEALTH_GRACE_MS` (default 5 min, Shell-tab debugging window) then 503s so Render restarts the container. The epoch anchor is what stops `/restart` spam from keeping a broken box "healthy" forever.
- **`POST /restart`** on the failure page exits the server (code 0) so the supervisor relaunches alphaclaw. It reads nothing from the request and shells out to nothing; repeat requests within 30s get 429 (dedupe, not cross-cycle rate limiting). The failure server also retries `listen()` on `EADDRINUSE` — a dying alphaclaw can hold :3000 for a few seconds.
- **Orphan sweep**: after every alphaclaw exit the supervisor TERM→wait→KILLs stragglers matching `ORPHAN_SWEEP_PATTERN` (default ERE `(^|[ /])openclaw[^ ]* gateway run( |$)` — matches `openclaw gateway run` and `node .../openclaw.mjs gateway run`). The pattern is deliberately tight: `pkill -f` matches anywhere in any argv, and rescue panes are where operators type things like `grep "openclaw gateway" start.log` mid-incident — requiring the anchored full "gateway run" phrase keeps the sweep off them (contract-tested in `scripts.bats`; argv containing the literal "…openclaw … gateway run" phrase remains a documented accepted risk). The env knob exists so the test harness can use a tagged stub and never touch real host processes. Surviving the sweep is how tmux rescue sessions outlive alphaclaw restarts (not container restarts/redeploys — tmux servers are in-memory).
- **Log hygiene**: `/data/start.log` rotates to `.1` above ~50MB (`MAX_LOG_BYTES`); every exit code, duration, and decision is logged there.
- **Signals**: the Dockerfile's `tini -g` TERMs the whole process group, so the supervisor needs no traps/job control and `docker stop` stays prompt. Don't drop `-g`.

## Render-specific gotchas

- **`dockerCommand` in `render.yaml` may not be honored** on this service. Blueprint sync has been unreliable — runtime behavior must come from Dockerfile `CMD`/`ENTRYPOINT`, not `render.yaml` overrides.
- **Shell tab requires a healthy container.** If PID 1 is crashing, the Shell tab is unavailable. Use the debug path below to break the loop.
- **No output for >2 min after `Setting WEB_CONCURRENCY=8`** in deploy logs almost always means the container crashed before producing stdout, or Render is still pulling the image. Don't assume "stuck" means "hanging."
- **Health check is `/health`** — must return 2xx on port 3000.

## Debug path

When the container won't stay up, swap `CMD` to use `debug-start.sh`:

```dockerfile
COPY debug-start.sh /debug-start.sh
RUN chmod +x /debug-start.sh
CMD ["/debug-start.sh"]
```

What it does:
- Binds port 3000 with a tiny Node HTTP server → Render goes Live → Shell tab unlocks
- `tail -f /dev/null` keeps PID 1 alive forever → no restart loop
- `set -x`, full env dump, listings of all candidate `openclaw` binary locations
- Tees everything to `/data/debug.log` so the record survives even if Render drops log lines

Once Live, in the Shell tab:
```sh
cat /data/debug.log
echo $PATH
ls /app/node_modules/.bin | grep -i claw
alphaclaw start          # reproduce the real failure
```

Restore `CMD ["/start.sh"]` after diagnosis.

## Tests

Three layers (details in `tests/README.md`); CI runs all three on push via `.github/workflows/test.yml`.

- `npm test` — fast unit + contract, no Docker. Unit exercises `failure-server.js` routing, the no-secret-leak property, and the restart/health-grace behavior; contract statically locks in the load-bearing invariants in this doc (PATH prepend, `TMPDIR=/data/tmp`, sticky-bit `mkdir` on boot, tini `-g`/CMD wiring, tmux in the apt lines (image and CI workflow), the exact `@anthropic-ai/claude-code` version pin, the sweep-pattern-vs-rescue-argv safety, the supervisor policy knobs, and "never operate on bare `/tmp`") and runs the **supervise harness** — the real `start.sh` on the host with a stub alphaclaw, covering exit-75, the 60s reset heuristic, backoff + threshold, epoch persistence, rotation, orphan sweep, tmux rescue-session survival across an exit-75 relaunch, and env validation. Unit also parses `claude-code/managed-settings.json` and asserts the whole managed policy key by key. `tests/contract/tools.bats` adds the baked-tools contracts: `baked-tools.env` parses and every pin is referenced, the `pins`/`tools`/`monolith-build` stages and the layer ordering (apt/PGDG above npm, tool `COPY`s between the shims and `COPY start.sh`), no `ARG`, downloads == checksum checks, the PGDG fingerprint/`signed-by`/client-only/purge-`gpg` discipline, the no-daemon guard (with positive and negative controls), the `EXPOSE`/`CMD`/`COPY`-source surface, the `.dockerignore` allowlist derived from the Dockerfile's `COPY` sources, CI `timeout-minutes`, and `AGENTS.md == CLAUDE.md`.
- `npm run test:e2e` — builds the image and runs it with an **empty `/data`** (tmpfs, mimicking Render's disk mount) to prove `start.sh` recreates `/data/tmp` at boot and the container stays Live; `stale-config.bats` and `supervise-e2e.bats` cover the config migration and the supervisor through the real container wiring. `tests/e2e/tools.bats` checks every baked binary offline (`docker run --network none`: version == pin from `baked-tools.env`, `ldd` resolves, arch is consistent, PATH/shim precedence holds), proves the checksum-mismatch build gate (a mutated manifest fails `docker build`), boots the image credential-free and asserts `/health` 200 with no tool processes (`tailscaled`/`caddy`/`monolith`) and no tool ports, boots against a reused `/data` volume, and asserts prompt shutdown. Needs Docker; slow.

After touching `start.sh`, `Dockerfile`, `baked-tools.env`, `.dockerignore`, `render.yaml`, or `failure-server.js`, run `npm test` (and `npm run test:e2e` for image-level changes).

## What NOT to do

- Don't patch `node_modules/alphaclaw/` — gets blown away on every `npm install`. Fix at the Dockerfile/env layer instead (or, for changes to alphaclaw itself, in the `garrytan/alphaclaw` fork).
- Don't rely on `dockerCommand` in `render.yaml` to override `CMD` — Blueprint sync may silently ignore it. Use Dockerfile `CMD`.
- Don't drop `ENV PATH="/app/node_modules/.bin:$PATH"` — it's load-bearing for alphaclaw's spawn behavior.
- Don't move the `/data/tmp` creation to Dockerfile-only — the disk mount hides it; `start.sh` must `mkdir` it at boot.
- Don't touch `/tmp` — no symlink, bind-mount, or move. Only set `TMPDIR` and leave `/tmp` be (see "Temp dir" section).
- Don't turn `start.sh` back into a one-shot launcher or `exec` the failure server — the supervise loop and its escape hatches are the fix for alphaclaw #22.
- Don't drop `-g` from the tini ENTRYPOINT — prompt shutdown of the supervised tree depends on group signaling.
- Don't drop `bubblewrap` or `socat` from the apt line — they are Claude Code's Linux sandbox dependencies, and with `sandbox.failIfUnavailable: true` in `/etc/claude-code/managed-settings.json` a worker session exits at startup without them. Contract-tested.
- Don't drop `tmux` from the Dockerfile's apt line — alphaclaw's local Claude Code rescue sessions probe for it (`tmux -V`); without it they fall back to `script(1)` hosting and die with every alphaclaw restart. Relatedly, never change `ORPHAN_SWEEP_PATTERN` to anything that could match tmux/rescue argv — the sweep would kill the session tmux exists to keep alive. Both are contract-tested.
- Don't unpin `@openai/codex`, `agy` or the gstack commit — an unpinned worker executor floats to an unreviewed release the next time an earlier layer changes, which is the failure mode the claude-code and alphaclaw pins exist to prevent. All three are contract-tested.
- Don't drop `ENV AGY_CLI_DISABLE_AUTO_UPDATE=true` — agy's background self-updater would replace the checksum-verified binary at runtime, and the pin would be fiction.
- Don't hand-edit `/etc/claude-code/managed-settings.json` on a running box, and don't move the policy onto `/data` — it is image state precisely so no worker HOME and no volume write can weaken it. Change `claude-code/managed-settings.json` in the repo, extend `tests/unit/managed-settings.test.mjs`, and redeploy.
- Don't put a credential VALUE in the managed policy — `credentials.envVars` takes variable NAMES only, and the file ships in every image layer.
- Don't add a `hooks/` directory or a worker launcher to the image — the acpx alias owns the spawn environment through `env -i` in the gateway config. Contract-tested.
- Don't convert the tool pins to `ARG` (or `ENV`) — keep them in `baked-tools.env`. Render turns service env vars into `--build-arg`s, so an `ARG` would be a dashboard-overridable pin (contract-tested: no `ARG` in the Dockerfile).
- Don't start `tailscaled` or `caddy` from the image or `start.sh` — installing is not enabling; the image must reach the setup UI credential-free with no tool daemons (static contract guard + e2e process/port checks).
- Don't install the PostgreSQL server package — client only (`postgresql-client-${PG_MAJOR}`; contract-tested).
- Don't move the apt/PGDG RUN below the npm layers — every alphaclaw pin bump would re-fetch apt and move the PG minor (ordering is contract-tested).
- Don't let `AGENTS.md` and `CLAUDE.md` diverge — they are the same file, contract-tested with `cmp`. Edit `CLAUDE.md`, then `cp CLAUDE.md AGENTS.md`.
- Don't hardcode the PostgreSQL major — use `${PG_MAJOR}` from `baked-tools.env` in package names, paths, and smokes.
- Don't add files to the build context without a `!` line in `.dockerignore` — it's an allowlist; an unlisted `COPY` source fails the build.
- Don't force-push or amend on `main` after a debug detour. Add a new commit on top.
