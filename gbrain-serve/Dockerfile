# gbrain serve --http sidecar. Nothing here is invented: the install is
# INSTALL_FOR_AGENTS.md "Step 1: Install GBrain" verbatim (bun + `bun install -g
# github:garrytan/gbrain#latest-stable`, the form "the bootstrap flow mandates";
# npm registry is forbidden there), and the entrypoint is docs/mcp/DEPLOY.md
# "Run gbrain under a real init (tini / --init)":
#   ENTRYPOINT ["/usr/bin/tini", "--", "gbrain", "serve", "--http"]
# Pinned by commit so the sidecar and the brain never drift: 5cfb84f1d is the
# `latest-stable` tag at build time (0.48.2.0; schema 145 = the brain's current
# version, introduced in 0.47.8.0 — no migration is implied by this pin).
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates unzip tini \
 && rm -rf /var/lib/apt/lists/*

# INSTALL_FOR_AGENTS.md Step 1, default path.
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"
ARG GBRAIN_REF=5cfb84f1d
RUN bun install -g "github:garrytan/gbrain#${GBRAIN_REF}" && gbrain --version

ENTRYPOINT ["/usr/bin/tini", "--", "gbrain", "serve", "--http"]
CMD ["--port", "3131", "--bind", "0.0.0.0"]
