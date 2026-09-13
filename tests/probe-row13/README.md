# row-13 probe harness (plan step 2b)

Local probes for the **row 13 worker-isolation** design, run against the
candidate image before anything is built on top of it.

Plan documents this harness answers, quoted where a script relies on them:

- `exgenius-system/plans/worker-isolation-by-client-source-2026-09-13.md`
  (v4) — §B (spawn shape), §C (worker HOME + the one managed policy),
  §"Measure before build" items 1-5.
- `exgenius-system/plans/intermediate-goal-phone-to-isolated-worker-2026-09-13.md`
  step 2b — *"Local probes (v4 §Measure 1-4) in a container from the candidate
  image on the laptop with a scratch volume and a test HOME (O4a) ... Nothing
  proceeds to step 3 on a red probe."*

## What it never touches

The live stack is `openclaw-stack-openclaw-1`, `gbrain-serve`,
`gbrain-postgres`, volume `openclaw-stack_openclaw-data`, host ports 3000 and
127.0.0.1:3131. **Nothing here addresses any of them.** The harness owns
exactly three names:

| | |
|---|---|
| image | `openclaw-stack-openclaw:row13-candidate` |
| container | `openclaw-row13-probe` |
| volume | `row13-probe-data` |

`common.sh` re-checks all three against a forbidden list before every docker
verb, asserts the target container was created from the candidate image, that
no live volume is mounted in it, and that it publishes **no host port**. Every
container call goes through `pexec` / `occ`, which address `$PROBE_CONTAINER`
and nothing else. No published port is needed: the health check and every CLI
call are `docker exec` from inside the probe container.

No real secret is copied anywhere. `up.sh` generates `.probe.env` (0600,
gitignored) with `openssl rand -hex 32` for `SETUP_PASSWORD`,
`OPENCLAW_GATEWAY_TOKEN` and `WEBHOOK_TOKEN`. The "tokens" the probes hunt for
are the literal string `gbrain_at_PROBECANARY_NOT_A_TOKEN`, which authenticates
nothing.

## The probes

| script | measures | plan item | needs |
|---|---|---|---|
| `up.sh` | brings the container up, seeds config + canaries, gates on the login | precondition for 1-5 | docker |
| `probe1-env.sh` | the acpx alias's `env -i` argv: exact child env NAME set | v4 §Measure 1 | nothing |
| `probe2-sandbox.sh` | 2A `claude -p`, 2B a real ACP spawn: own canary readable, neighbour canary / `/data/.env` / neighbour HOME token / `/proc/1/environ` / `codex exec` / `agy` / the Read tool all denied, denial text captured verbatim; records whether `bwrap` was actually used | v4 §Measure 2 | login (2A), onboarded gateway + provider key (2B) |
| `probe2b-broken-bwrap.sh` | `bwrap` renamed away → the session must refuse to start (`sandbox.failIfUnavailable`) | v4 §Measure 2, last clause | login |
| `probe3-auth.sh` | MCP surface and connectors in the worker HOME | v4 §Measure 3 (the `whoami` half is **not** measurable without a minted brain client, owner O3) | login |
| `probe4-negatives.sh` | four negative spawns: not-allowed agent, bare `claude`, foreign `cwd`, bogus `resumeSessionId` | v4 §Measure 4 | onboarded gateway + provider key |
| `probe5-acpx.sh` | is acpx present in a fresh volume at all; install `@openclaw/acpx@2026.9.3`; `plugins doctor` | v4 §Measure 5 | network |
| `down.sh --yes` | removes the container and the volume (`--keep-volume` keeps the login) | — | — |
| `run-all.sh` | 1-5 in order after `up.sh` reports logged in; prints a verdict table | — | — |

Each script prints `PROBE-<n>: PASS|FAIL|BLOCKED` as its last line and leaves
every raw command output under `out/` (gitignored), one file per command with a
`.rc` sidecar holding the real exit code — an exit code is never read through a
pipe.

`BLOCKED` is not a soft `PASS`. It means the probe could not be run, and the
reason is printed above the verdict.

## The owner's one step

`up.sh` stops with `LOGIN-NEEDED` until the probe HOME has a Claude login. That
is owner action **O4a**, the only manual step:

```
docker exec -it openclaw-row13-probe env HOME=/data/agents/probe/home TERM=xterm claude
```

then `/login`. `up.sh` is idempotent — re-run it afterwards. The login lives on
`row13-probe-data`, so it survives a container restart and dies with
`down.sh --yes` (use `--keep-volume` to keep it).

Login state is read with `claude auth status --text`, which
[cli-reference](https://code.claude.com/docs/en/cli-reference.md) documents as
*"Show authentication status as JSON. Use `--text` for human-readable output.
Exits with code 0 if logged in, 1 if not"*.

## Reading the output

1. `out/run-all-verdicts.txt` — the verdict table.
2. For a FAIL, open the named `out/*.txt`. Every file is raw command output; the
   scripts add no interpretation to it beyond a `----` banner.
3. For probe 2, `out/p2a.txt` is the model's transcript and
   `out/p2a-debug.log` is Claude Code's own debug log (`--debug-file`,
   cli-reference.md:82) — the only place that says whether `bwrap` actually
   ran. A denial in the transcript with no sandbox line in the debug log means
   the permission system denied it, not the sandbox; sandboxing.md §Scope:
   *"Built-in file tools: Read, Edit, and Write use the permission system
   directly rather than running through the sandbox."*

## Three facts measured while building this, 2026-09-13

They are properties of the candidate image and of a **fresh** volume, and each
one changes what a probe can answer.

1. **`openclaw` CLI needs `HOME=/data` in this image.** With the image default
   `HOME=/root`, every config writer dies with `[openclaw] Reason: Atomic
   replace parent must be a real directory: /root/.openclaw` — alphaclaw
   symlinks that path at boot (`[alphaclaw] Symlinked /root/.openclaw ->
   /data/.openclaw`, `/data/start.log`) and openclaw's atomic replace refuses a
   symlinked parent. `occ()` in `common.sh` is that fix, and
   `openclaw config file` then prints `/data/.openclaw/openclaw.json`, the same
   file the gateway reads.
2. **A fresh volume carries no acpx and no openclaw.json.** `plugins list`
   before the install shows 39/59 stock plugins and no acpx; `openclaw setup
   --baseline` (cli/index.md:16) creates the config the seeding step needs.
3. **The OpenClaw gateway does not start in a fresh probe container.**
   alphaclaw parks on `[alphaclaw] Awaiting onboarding via Setup UI` and never
   launches it, so `ws://127.0.0.1:18789` is `ECONNREFUSED` and every
   `openclaw agent` / `/acp spawn` route is unavailable. Onboarding is
   alphaclaw's own web flow (`README.md:163-165`: the server "runs `openclaw
   onboard`, configures channels"), which needs a published port and a model
   provider. **Consequence: probes 1, 2A, 2b, 3 and 5 are answerable on this
   laptop; the ACP-spawn halves (2B and probe 4) are not, and report BLOCKED.**
   Deciding whether to onboard the probe container is not this harness's call.
