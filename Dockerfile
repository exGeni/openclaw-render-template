# Image build pipeline (keep this diagram in sync with the stages below; see
# CLAUDE.md "Baked tools"):
#
#  baked-tools.env (repo; the single pin source: versions, checksums, MONOLITH_REV, PG_MAJOR)
#       │ COPY                                   │ COPY
#       ▼                                        ▼
#  ┌─ stage pins (node:24-slim) ─────────┐  ┌─ stage tools (node:24-slim) ──────────────────────┐
#  │ /monolith.env = MONOLITH_* lines     │  │ apt: ca-certificates curl unzip (build-only)      │
#  │ /pg.env       = PG_MAJOR line        │  │ . baked-tools.env → arch case → dl() + sha*sum -c │
#  │ (each file changes only when its own │  │  → /out/usr/local/bin/{caddy,tailscale,tailscaled,│
#  │  pins change, so downstream caches   │  │     bun,bunx→bun,agy} ; /out/etc/baked-tools.env   │
#  │  survive unrelated pin bumps)        │  └─────────────────────────┬─────────────────────────┘
#  └──────┬─────────────────┬────────────┘                            │
#         │ /monolith.env   │ /pg.env                                  │
#         ▼                 │                                          │
#  ┌─ stage monolith-build (rust:<pinned digest>) ──┐                  │
#  │ apt: perl make ; cargo install --git Y2Z/monolith│                 │
#  │   --rev $MONOLITH_REV --locked → /opt/monolith  │                  │
#  └──────┬───────────────────────────────────────────┘                 │
#         │                 │                                          │
#  ┌─ final (node:24-slim) ─┼─ layer order is load-bearing ────────────┼──┐
#  │ 1 apt line (git curl … tmux, + bubblewrap socat: the Claude Code  │  │
#  │   sandbox deps on Linux — sandboxing.md "Set up Linux and WSL2")  │  │
#  │ 2 NEW apt/PGDG RUN (reads /pg.env): ca-certificates openssl gpg   │  │
#  │   jq git-lfs psmisc util-linux; PGDG key fingerprint check;       │  │
#  │   postgresql-client-$PG_MAJOR (client only);                      │  │
#  │   purge gpg; git lfs install --system; smoke   (ABOVE npm layers: │  │
#  │   alphaclaw pin bumps never re-fetch apt or move the PG minor)    │  │
#  │ 3 npm -g claude-code@pin                    UNCHANGED             │  │
#  │ 4 COPY package.json; npm install            UNCHANGED             │  │
#  │ 5 shims (/usr/bin, /usr/local/bin symlinks) UNCHANGED             │  │
#  │ 6 NEW COPY --from=tools bins + /etc/baked-tools.env  ◄────────────┼──┘
#  │       COPY --from=monolith-build monolith            ◄────────────┘
#  │   RUN . /etc/baked-tools.env; every tool --version == pin (fails the build)
#  │ 7 COPY start.sh, failure-server.js; ENV PATH/TMPDIR…; mkdir /data/tmp;
#  │   EXPOSE 3000; ENTRYPOINT tini -g; CMD /start.sh   UNCHANGED
#  └──────────────────────────────────────────────────────────────────────┘
#  Nothing in the image or start.sh launches tailscaled/caddy; no new ports, cron, or ENV.
#  Pins are a plain file, never ARG: Render turns every service env var into a
#  --build-arg, so an ARG default would be a dashboard-overridable pin.

# --- stage pins: split the manifest so each consumer's cache key depends only on its own pins
FROM node:24-slim AS pins
COPY baked-tools.env /baked-tools.env
RUN set -eu; \
    grep '^MONOLITH_' /baked-tools.env > /monolith.env; test -s /monolith.env; \
    grep '^PG_MAJOR=' /baked-tools.env > /pg.env; test -s /pg.env

# --- stage tools: download + checksum-verify the static release binaries (build tooling stays here)
FROM node:24-slim AS tools
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*
COPY baked-tools.env /opt/baked-tools.env
# dash has no pipefail: every pipeline below ends in the command whose failure
# must abort the build (the sha*sum -c), so set -e catches it.
RUN set -eu; \
    . /opt/baked-tools.env; \
    dl() { curl -fsSL --retry 5 --retry-all-errors --retry-max-time 180 --connect-timeout 20 -o "$2" "$1"; }; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) caddy_sha="$CADDY_SHA512_AMD64"; ts_sha="$TAILSCALE_SHA256_AMD64"; bun_arch=x64;     bun_sha="$BUN_SHA256_X64";     agy_path=linux-x64/cli_linux_x64;   agy_sha="$AGY_SHA512_AMD64" ;; \
      arm64) caddy_sha="$CADDY_SHA512_ARM64"; ts_sha="$TAILSCALE_SHA256_ARM64"; bun_arch=aarch64; bun_sha="$BUN_SHA256_AARCH64"; agy_path=linux-arm/cli_linux_arm64; agy_sha="$AGY_SHA512_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    work="$(mktemp -d)"; cd "$work"; \
    mkdir -p /out/usr/local/bin /out/etc; \
    dl "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${arch}.tar.gz" caddy.tgz; \
    echo "${caddy_sha}  caddy.tgz" | sha512sum -c -; \
    tar -xzf caddy.tgz caddy; \
    install -m 0755 caddy /out/usr/local/bin/caddy; \
    dl "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${arch}.tgz" tailscale.tgz; \
    echo "${ts_sha}  tailscale.tgz" | sha256sum -c -; \
    tar -xzf tailscale.tgz --strip-components=1 "tailscale_${TAILSCALE_VERSION}_${arch}/tailscale" "tailscale_${TAILSCALE_VERSION}_${arch}/tailscaled"; \
    install -m 0755 tailscale /out/usr/local/bin/tailscale; \
    install -m 0755 tailscaled /out/usr/local/bin/tailscaled; \
    dl "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip" bun.zip; \
    echo "${bun_sha}  bun.zip" | sha256sum -c -; \
    unzip -q bun.zip; \
    install -m 0755 "bun-linux-${bun_arch}/bun" /out/usr/local/bin/bun; \
    ln -s bun /out/usr/local/bin/bunx; \
    dl "https://storage.googleapis.com/antigravity-public/antigravity-cli/${AGY_BUILD}/${agy_path}.tar.gz" agy.tgz; \
    echo "${agy_sha}  agy.tgz" | sha512sum -c -; \
    tar -xzf agy.tgz antigravity; \
    install -m 0755 antigravity /out/usr/local/bin/agy; \
    install -m 0644 /opt/baked-tools.env /out/etc/baked-tools.env; \
    cd /; rm -rf "$work"

# --- stage monolith-build: the upstream aarch64 prebuilt links libssl1.1 (absent from
# bookworm), so monolith is compiled from the pinned git commit on every arch. Default
# features = cli + vendored OpenSSL, so the binary links only glibc/libgcc_s.
FROM rust:1.98.0-slim-bookworm@sha256:1469a27c125cb5a3aebfa4f4e4665d935b02fb72cc093b2c974b3d740e43f157 AS monolith-build
COPY --from=pins /monolith.env /monolith.env
RUN apt-get update && apt-get install -y --no-install-recommends perl make && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    . /monolith.env; \
    cargo install --git https://github.com/Y2Z/monolith --rev "$MONOLITH_REV" --locked --root /opt/monolith monolith; \
    test "$(/opt/monolith/bin/monolith --version)" = "monolith ${MONOLITH_VERSION}"

# --- final image
FROM node:24-slim

# bubblewrap + socat are the Claude Code sandbox dependencies on Linux:
# "the unprivileged sandboxing tool that enforces filesystem isolation" and
# "the relay used to route network traffic through the sandbox proxy"
# (code.claude.com/docs/en/sandboxing "Set up Linux and WSL2"). The managed
# policy in /etc/claude-code sets sandbox.failIfUnavailable=true, so a worker
# session refuses to start when either package is missing — they are a hard
# dependency of the image, not an optional extra. Debian-versioned like tmux:
# an exact apt pin expires when the pool rotates (see AGENTS.md "Baked tools").
RUN apt-get update && apt-get install -y git curl procps python3 make g++ cron tini vim screen tmux unzip bubblewrap socat && rm -rf /var/lib/apt/lists/*

# Support packages + the PostgreSQL CLIENT (never the server) from the signed PGDG
# repo. Sits ABOVE the npm layers on purpose: alphaclaw pin bumps are frequent and
# must not re-fetch apt indexes or move the PostgreSQL minor; editing this RUN is
# rare and costs a rebuild of the pinned claude-code layer and the bounded app
# `npm install` (the same trade-off the apt line above already accepts).
# The PGDG key is verified by fingerprint (exactly one primary key, and it must be
# the pinned one) before apt ever sees it. TMPDIR is unset at this point, so the
# scratch dir lands in the build container's ephemeral temp (no literal path here;
# the /data disk does not exist at build time).
COPY --from=pins /pg.env /opt/pg.env
RUN set -eu; \
    . /opt/pg.env; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates openssl gpg jq git-lfs psmisc util-linux; \
    scratch="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-max-time 180 --connect-timeout 20 -o "$scratch/pgdg.asc" https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    listing="$(GNUPGHOME="$scratch" gpg --batch --show-keys --with-colons "$scratch/pgdg.asc")"; \
    test "$(printf '%s\n' "$listing" | awk -F: '$1=="pub"' | wc -l)" -eq 1; \
    test "$(printf '%s\n' "$listing" | awk -F: '$1=="fpr"{print $10; exit}')" = "B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"; \
    install -D -m 0644 "$scratch/pgdg.asc" /usr/share/keyrings/postgresql-archive-keyring.asc; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}"; \
    apt-get purge -y --auto-remove gpg; \
    rm -rf /var/lib/apt/lists/* "$scratch" /opt/pg.env; \
    git lfs install --system --skip-repo; \
    psql --version | grep -qF "(PostgreSQL) ${PG_MAJOR}."; \
    pg_dump --version | grep -qF "(PostgreSQL) ${PG_MAJOR}."; \
    pg_restore --version | grep -qF "(PostgreSQL) ${PG_MAJOR}."; \
    test -x "/usr/lib/postgresql/${PG_MAJOR}/bin/psql"; \
    jq --version; git lfs version; flock --version; fuser -V; openssl version; \
    test -s /etc/ssl/certs/ca-certificates.crt

# Pinned exactly, same discipline as the alphaclaw SHA pin: an unpinned
# install floats to latest whenever an earlier layer changes, silently
# shipping an unreviewed claude-code. Bump deliberately and record it.
RUN npm install -g @anthropic-ai/claude-code@2.1.252 && npm cache clean --force

# Shared libraries Chromium needs on a slim Debian image, installed the way
# Playwright documents it (`playwright install-deps chromium`). gstack's
# ./setup downloads chromium-headless-shell into the executor's HOME and then
# fails with "Playwright Chromium could not be launched" without these.
RUN npx --yes playwright@1.58.2 install-deps chromium && rm -rf /var/lib/apt/lists/* /root/.npm/_npx

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

RUN printf '#!/bin/sh\nexec /app/node_modules/.bin/openclaw "$@"\n' > /usr/bin/openclaw \
 && printf '#!/bin/sh\nexec /app/node_modules/.bin/alphaclaw "$@"\n' > /usr/bin/alphaclaw \
 && printf '#!/bin/sh\nexec /usr/local/bin/claude "$@"\n' > /usr/bin/claude \
 && chmod +x /usr/bin/openclaw /usr/bin/alphaclaw /usr/bin/claude \
 && ln -sf /app/node_modules/.bin/openclaw /usr/local/bin/openclaw \
 && ln -sf /app/node_modules/.bin/alphaclaw /usr/local/bin/alphaclaw \
 && /usr/bin/openclaw --version \
 && /usr/bin/claude --version

# Baked static tools land BELOW the npm layers (a tool bump never re-resolves app
# deps) and ABOVE the script COPYs (a start.sh hotfix never re-downloads tools).
# The smoke compares every binary against the shipped manifest so a mismatch
# fails the build. tailscaled is only checked for presence here: it is a daemon
# and the image must never invoke it (its --version is exercised by the e2e suite).
COPY --from=tools /out/usr/local/bin/ /usr/local/bin/
COPY --from=tools /out/etc/baked-tools.env /etc/baked-tools.env
COPY --from=monolith-build /opt/monolith/bin/monolith /usr/local/bin/monolith
RUN set -eu; \
    . /etc/baked-tools.env; \
    test "$(caddy version | cut -d' ' -f1)" = "v${CADDY_VERSION}"; \
    test "$(tailscale version | head -n1)" = "${TAILSCALE_VERSION}"; \
    test -x /usr/local/bin/tailscaled; \
    test "$(bun --version)" = "${BUN_VERSION}"; \
    test "$(bunx --version)" = "${BUN_VERSION}"; \
    test "$(monolith --version)" = "monolith ${MONOLITH_VERSION}"; \
    test "$(agy --version)" = "${AGY_VERSION}"

# gbrain CLI, installed exactly as INSTALL_FOR_AGENTS.md "Step 1: Install GBrain"
# prescribes (`bun install -g github:garrytan/gbrain#<ref>`; the npm registry is
# forbidden there). Bun itself is no longer fetched here: the baked-tools layer
# above ships a checksum-verified bun/bunx at /usr/local/bin, so the old
# `curl bun.sh/install` step and the /usr/local/bin/bun symlink it needed are
# gone — symlinking over the baked binary would defeat the version smoke that
# just ran. `bun install -g` still targets $HOME/.bun/bin, hence the PATH line.
# Image-owned so it is reproduced by the build on every recreate and on the
# server, never by writes into the volume. Pinned by commit to the same ref as
# gbrain-serve/Dockerfile so the two cannot drift.
# GBRAIN_HOME moves gbrain's own config/state onto the persistent volume: HOME is
# /root here and does not survive a recreate (docs/mcp/OPENCLAW.md names
# GBRAIN_HOME as the knob "when the brain home isn't ~/.gbrain"). It is a PARENT
# directory — gbrain appends ".gbrain" itself — so /data yields /data/.gbrain.
ENV PATH="/root/.bun/bin:$PATH"
ARG GBRAIN_REF=43597b19e50a3abf56409337f248f7966860293c
# `bun pm cache rm` is bun's own cache purge, the counterpart of the
# `npm cache clean --force` every npm layer above already runs. It must stay
# INSIDE this RUN: a later layer cannot delete bytes an earlier one committed.
RUN bun install -g "github:garrytan/gbrain#${GBRAIN_REF}" && gbrain --version \
 && ln -sf /root/.bun/bin/gbrain /usr/local/bin/gbrain \
 && bun pm cache rm \
 && test ! -d /root/.bun/install/cache
ENV GBRAIN_HOME=/data

# --- worker tooling: the executors an ACP-spawned Claude Code worker calls -----
# Everything below is image-owned so a recreate reproduces it; nothing here is
# written into /data. All three land on PATH for every user (/usr/local/bin or
# a global npm prefix), because an ACP worker runs under its own per-client
# HOME on the volume, not under /root.

# OpenAI Codex CLI, pinned exactly, same discipline as the claude-code pin
# above: an unpinned global install floats whenever an earlier layer changes.
# The package resolves its platform binary through optionalDependencies
# (@openai/codex-linux-{x64,arm64}), so one spec covers both arches.
RUN npm install -g @openai/codex@0.154.0 && npm cache clean --force

# gstack, installed the way its own docs prescribe for an OpenClaw host —
# docs/OPENCLAW.md "Installation" step 1 spawns Claude Code sessions with
# "gstack installed at ~/.claude/skills/gstack", and README.md "Step 1: Install
# on your machine" gives the command as
#   git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git \
#     ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup
# Two deliberate departures from that line, both required here:
#   * the documented clone tracks a moving branch, and garrytan/gstack ships no
#     tags, so the commit is pinned instead (VERSION 1.84.1.0 at this SHA) —
#     the same rule as the alphaclaw and claude-code pins. `fetch --depth 1
#     origin <sha>` keeps the clone shallow.
#   * `./setup` is what installs the skills and builds the browser; it needs the
#     Chromium shared libraries the playwright layer above already installs.
# Steps 2-4 of that section (the four ClawHub native skills, the AGENTS.md
# dispatch block, the verification spawn) are gateway/volume state, not image
# state, and are deliberately NOT done here.
# The path is not free: setup derives its skills dir as the PARENT of its own
# location (setup:65) and gates the whole Claude branch on that parent being
# named "skills" (setup:2119,2126). From anywhere else -- /opt/gstack included
# -- it takes the else branch at setup:2166-2168, "would symlink the source
# into ~/.claude/skills/gstack/ and register from there", and setup:2482 pins
# hook registration to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/gstack. So a
# shared /opt root would end up symlinked back into the build HOME anyway, with
# two paths instead of one. HOME is /root at build time, so the one path is
# /root/.claude/skills/gstack, root-owned.
# A worker running under a per-client HOME on /data does not see that tree. It
# gets it through a symlink ~/.claude/skills/gstack -> /root/.claude/skills/gstack
# created by the renderer in each worker HOME. The image seeds no worker HOME.
# ./setup runs `bun install`, which fills bun's global download cache with ~1.3 GB
# of build residue nothing reads at runtime; `bun pm cache rm` in the same RUN is
# what keeps those bytes out of the layer. The browser IS kept: client work is
# websites, and the playwright deps layer above exists for exactly that.
RUN git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git /root/.claude/skills/gstack \
 && git -C /root/.claude/skills/gstack fetch --depth 1 origin 71f6048e8ada25180e61438abc1d98cb151fe9a7 \
 && git -C /root/.claude/skills/gstack checkout --detach 71f6048e8ada25180e61438abc1d98cb151fe9a7 \
 && grep -qxF 1.84.1.0 /root/.claude/skills/gstack/VERSION \
 && cd /root/.claude/skills/gstack \
 && ./setup \
 && bun pm cache rm \
 && test ! -d /root/.bun/install/cache

# agy runs a background self-updater on a 15-minute debounce, which would
# replace the checksum-verified binary the tools stage pinned. The vendor's own
# knob turns it off (antigravity.google/docs/cli/troubleshooting/).
ENV AGY_CLI_DISABLE_AUTO_UPDATE=true

# The managed Claude Code policy for worker sessions. Linux path per
# code.claude.com/docs/en/managed-settings "Place the file on each machine":
# "Linux and WSL: /etc/claude-code/managed-settings.json". Root-owned 0644 so a
# worker session can read it and cannot rewrite it; the policy itself denies
# reads of /etc/claude-code from inside the sandbox. Baked into the image, not
# the volume, so no worker HOME and no /data write can weaken it.
# NOT set here: CLAUDE_CODE_SUBPROCESS_ENV_SCRUB, which would "strip credentials
# from all subprocesses regardless of sandboxing" (sandboxing.md). It has no
# entry in settings-reference.md -- it is an env var, not a settings key -- so
# its place is the acpx alias `env -i` allowlist in the gateway config, and it
# "turns auto-allow off" (settings-reference#sandbox-autoallowbashifsandboxed),
# which would make every sandboxed Bash command prompt an unattended worker.
COPY claude-code/managed-settings.json /etc/claude-code/managed-settings.json
RUN chown root:root /etc/claude-code/managed-settings.json \
 && chmod 0644 /etc/claude-code/managed-settings.json \
 && node -e "JSON.parse(require('fs').readFileSync('/etc/claude-code/managed-settings.json','utf8'))"

COPY start.sh /start.sh
COPY failure-server.js /failure-server.js
RUN chmod +x /start.sh

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data

# Route temp onto the persistent disk instead of the container's ephemeral /tmp.
# OpenClaw is migrating hardcoded /tmp callsites to TMPDIR-aware APIs; any code
# that respects the standard temp env vars will land under /data/tmp.
# NOTE: /data is a runtime-mounted disk, so this build-time mkdir is shadowed at
# runtime — start.sh recreates /data/tmp on boot. Kept here for image self-consistency.
ENV TMPDIR=/data/tmp
ENV TEMP=/data/tmp
ENV TMP=/data/tmp

RUN mkdir -p /data/tmp && chmod 1777 /data/tmp

EXPOSE 3000

# -g: tini signals the ENTIRE process group, so a TERM to PID 1 reaches
# alphaclaw, tee, and any backoff sleep directly from the kernel. This is what
# lets start.sh's supervise loop stay a plain foreground loop with no trap /
# job-control machinery — bash's default TERM disposition is fine because no
# process depends on bash forwarding anything.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/start.sh"]
