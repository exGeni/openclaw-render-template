#!/usr/bin/env bats
#
# Contract tests for the Dockerfile + render.yaml. Static assertions that the
# image-layer invariants documented in CLAUDE.md / AGENTS.md stay in place.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# --- PATH fix (primary + belt-and-suspenders shims) ---------------------------

@test "Dockerfile: sets PATH so /app/node_modules/.bin wins" {
  grep -Eq 'ENV PATH="/app/node_modules/\.bin:\$PATH"' "$REPO/Dockerfile"
}

@test "Dockerfile: installs openclaw + alphaclaw shims into /usr/bin" {
  grep -q '/usr/bin/openclaw' "$REPO/Dockerfile"
  grep -q '/usr/bin/alphaclaw' "$REPO/Dockerfile"
}

# --- TMPDIR onto the persistent disk ------------------------------------------

@test "Dockerfile: sets TMPDIR/TEMP/TMP env to /data/tmp" {
  grep -q 'ENV TMPDIR=/data/tmp' "$REPO/Dockerfile"
  grep -q 'ENV TEMP=/data/tmp'   "$REPO/Dockerfile"
  grep -q 'ENV TMP=/data/tmp'    "$REPO/Dockerfile"
}

@test "Dockerfile: creates /data/tmp with the sticky bit" {
  grep -Eq 'mkdir -p /data/tmp && chmod 1777 /data/tmp' "$REPO/Dockerfile"
}

@test "Dockerfile: never redirects bare /tmp (mentions only in comments)" {
  # Only /data/tmp is added; bare /tmp must never be a build instruction target.
  while IFS= read -r line; do
    [[ "$line" =~ ^[0-9]+:[[:space:]]*# ]] || { echo "non-comment /tmp use: $line"; false; }
  done < <(grep -nw '/tmp' "$REPO/Dockerfile")
}

# --- tmux (rescue-session hosting) ---------------------------------------------

@test "Dockerfile: installs tmux (rescue-session hosting)" {
  # alphaclaw's local Claude Code rescue sessions probe for tmux (`tmux -V`);
  # without it they degrade to script(1) hosting and die with every alphaclaw
  # restart. Portable delimiters, no \b — BSD grep doesn't reliably support it.
  grep -Eq 'apt-get install[^&]* tmux( |$)' "$REPO/Dockerfile"
}

@test "CI workflow: installs tmux so the rescue-survival test can never silently skip" {
  # supervise.bats skips its tmux-survival test when the host lacks tmux, and
  # bats reports skips as green — so CI must install tmux explicitly or the
  # survival property goes unproven while CI stays green. Same delimiter
  # rationale as above (no \b).
  grep -Eq 'apt-get install[^&]* tmux( |$)' "$REPO/.github/workflows/test.yml"
}

@test "Dockerfile: pins @anthropic-ai/claude-code to an exact version" {
  # Unpinned, this install floats to latest whenever an earlier layer changes
  # (e.g. an apt edit), silently shipping an unreviewed claude-code — the same
  # failure mode the alphaclaw SHA pin exists to prevent.
  grep -Eq 'npm install -g @anthropic-ai/claude-code@[0-9]+\.[0-9]+\.[0-9]+' "$REPO/Dockerfile"
}

# --- Worker executors: sandbox deps, codex, agy, gstack -------------------------
#
# An ACP-spawned Claude Code worker runs `codex` and `agy` as Bash children
# inside the sandbox and loads gstack from the skills tree. Each is pinned the
# same way claude-code is (exact version / exact commit), so an unrelated layer
# edit can never float one of them to an unreviewed release.

@test "Dockerfile: installs bubblewrap + socat (Claude Code sandbox deps on Linux)" {
  # sandboxing.md "Set up Linux and WSL2": the sandbox relies on bubblewrap
  # ("enforces filesystem isolation") and socat ("routes network traffic
  # through the sandbox proxy"). With sandbox.failIfUnavailable=true in the
  # managed policy a missing package means the worker refuses to start.
  # Same portable delimiters as the tmux check above (no \b).
  grep -Eq 'apt-get install[^&]* bubblewrap( |$)' "$REPO/Dockerfile"
  grep -Eq 'apt-get install[^&]* socat( |$)'      "$REPO/Dockerfile"
}

@test "Dockerfile: pins @openai/codex to an exact version" {
  grep -Eq 'npm install -g @openai/codex@[0-9]+\.[0-9]+\.[0-9]+' "$REPO/Dockerfile"
}

@test "Dockerfile: bakes agy from the pinned manifest, never the vendor curl|bash installer" {
  # agy-usage.md documents `curl -fsSL https://antigravity.google/cli/install.sh
  # | bash`, which resolves a moving manifest and pipes into a shell. The tools
  # stage fetches the same immutable artifact by pinned build id and verifies
  # the vendor's own SHA-512 instead (tools.bats covers the download/checksum
  # counts and the version smoke).
  grep -qF 'antigravity-cli/${AGY_BUILD}/${agy_path}.tar.gz' "$REPO/Dockerfile"
  grep -qF 'install -m 0755 antigravity /out/usr/local/bin/agy' "$REPO/Dockerfile"
  grep -Eq '^AGY_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$REPO/baked-tools.env"
  run grep -F 'antigravity.google/cli/install.sh' "$REPO/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "Dockerfile: disables the agy background self-updater (it would replace the pinned binary)" {
  grep -qxF 'ENV AGY_CLI_DISABLE_AUTO_UPDATE=true' "$REPO/Dockerfile"
}

@test "Dockerfile: installs gstack at a pinned commit, into the documented skills path" {
  # gstack docs/OPENCLAW.md "Installation" + README "Step 1": clone into
  # ~/.claude/skills/gstack and run ./setup. garrytan/gstack ships no tags, so
  # the pin is the commit, asserted against VERSION at build time.
  grep -qF 'git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git /root/.claude/skills/gstack' "$REPO/Dockerfile"
  [ "$(grep -cE 'checkout --detach [0-9a-f]{40}' "$REPO/Dockerfile")" -eq 1 ]
  grep -qE 'grep -qxF [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ /root/\.claude/skills/gstack/VERSION' "$REPO/Dockerfile"
  grep -qE '^ && \./setup$' "$REPO/Dockerfile"
  # the fetch and the checkout must name the SAME commit, or the pin is a lie
  shas=$(grep -oE '(fetch --depth 1 origin|checkout --detach) [0-9a-f]{40}' "$REPO/Dockerfile" | awk '{print $NF}' | sort -u)
  [ "$(wc -l <<<"$shas")" -eq 1 ]
  # steps 2-4 of that section are gateway/volume state, never image state
  run grep -F 'clawhub install' "$REPO/Dockerfile"
  [ "$status" -ne 0 ]
}

# --- Managed Claude Code policy -------------------------------------------------

@test "Dockerfile: copies the managed policy to the documented Linux path, root-owned 0644" {
  # managed-settings.md "Place the file on each machine": on Linux and WSL the
  # file is /etc/claude-code/managed-settings.json.
  grep -qxF 'COPY claude-code/managed-settings.json /etc/claude-code/managed-settings.json' "$REPO/Dockerfile"
  grep -qF 'chown root:root /etc/claude-code/managed-settings.json' "$REPO/Dockerfile"
  grep -qF 'chmod 0644 /etc/claude-code/managed-settings.json' "$REPO/Dockerfile"
  # the build parses it, so malformed JSON can never reach a running worker
  grep -qF "node -e \"JSON.parse(require('fs').readFileSync('/etc/claude-code/managed-settings.json','utf8'))\"" "$REPO/Dockerfile"
}

@test "Dockerfile: ships no hooks directory and no worker launcher script" {
  # The acpx alias supplies HOME/PATH/OPENCLAW_SESSION through `env -i` in the
  # gateway config; nothing in the image wraps a worker launch, and the Codex
  # auth stopgap stays a manual /data script.
  [ ! -d "$REPO/hooks" ]
  run grep -E '(^|[[:space:]])(hooks/|/opt/exgenius|acp-launch)' "$REPO/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "claude-code/managed-settings.json: is a repo file carried by the allowlist" {
  [ -f "$REPO/claude-code/managed-settings.json" ]
  # the allowlist .dockerignore must carry its ! row or the COPY fails the build
  grep -qxF '!claude-code/managed-settings.json' "$REPO/.dockerignore"
}

# --- Init + entrypoint --------------------------------------------------------

@test "Dockerfile: uses tini -g as PID 1 (group signaling)" {
  # -g is load-bearing: the supervise loop in start.sh is a plain foreground
  # loop with no traps; prompt TERM delivery to alphaclaw/tee/sleep relies on
  # tini signaling the whole process group.
  grep -Eq 'ENTRYPOINT \["/usr/bin/tini", "-g", "--"\]' "$REPO/Dockerfile"
}

@test "Dockerfile: CMD boots via start.sh" {
  grep -Eq 'CMD \["/start.sh"\]' "$REPO/Dockerfile"
}

@test "Dockerfile: exposes port 3000" {
  grep -q 'EXPOSE 3000' "$REPO/Dockerfile"
}

@test "Dockerfile: points ALPHACLAW_ROOT_DIR at the persistent disk" {
  grep -q 'ENV ALPHACLAW_ROOT_DIR=/data' "$REPO/Dockerfile"
}

# --- Render blueprint ---------------------------------------------------------

@test "render.yaml: health check is /health" {
  grep -q 'healthCheckPath: /health' "$REPO/render.yaml"
}

@test "render.yaml: mounts a persistent disk at /data" {
  grep -q 'mountPath: /data' "$REPO/render.yaml"
}
