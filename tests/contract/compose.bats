#!/usr/bin/env bats
#
# Contract tests for docker-compose.yml and the seccomp profile it names.
#
# The property: the `openclaw` service relaxes BOTH container confinement layers
# that deny bubblewrap, and it does so with a custom seccomp profile rather than
# `seccomp=unconfined`. Claude Code's Bash sandbox shells out to bubblewrap,
# which creates a user + mount namespace and then mounts inside it. Measured
# 2026-09-13 on throwaway containers from this image: Docker's builtin seccomp
# profile denies the namespace CREATION (clone/unshare carrying a CLONE_NEW* bit
# is allowed only under CAP_SYS_ADMIN, which this container does not have), and
# docker-default AppArmor then denies bwrap's `mount --make-rslave /`. Neither
# relaxation works alone: with only seccomp relaxed bwrap dies at
# `Failed to make / slave: Permission denied`, with only AppArmor relaxed it dies
# at `No permissions to create new namespace`.
#
# seccomp-userns.json is moby/profiles seccomp/default.json plus exactly one
# entry, so the filter stays ENFORCING (`Seccomp: 2` in /proc/self/status) with
# the whole default profile intact. Docker's seccomp doc gives the custom-profile
# flag as the supported mechanism and states that the CLI resolves a relative
# profile path from the working directory where `docker` is invoked — which is
# why the file lives next to docker-compose.yml at the repo root.
#
# Static (no Docker, no container): runs in `npm test`.
#
# Negative checks use `run` + status: a bare non-final `! cmd` is exempt from
# bats errexit and asserts nothing.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  COMPOSE="$REPO/docker-compose.yml"
  PROFILE="$REPO/seccomp-userns.json"
  OPENCLAW_SVC="$(service_text openclaw)"
}

# Body of one top-level compose service: from `  <name>:` (two-space indent) up
# to the next two-space-indented service key or column-0 line, comments and
# blanks stripped. Keeps the assertions below on the openclaw service and not on
# a sibling.
service_text() {
  awk -v name="$1" '
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { insvc = ($0 == "  " name ":") ; next }
    /^[^[:space:]]/                    { insvc = 0 }
    insvc
  ' "$COMPOSE" | grep -vE '^[[:space:]]*(#|$)'
}

# --- compose: the two security_opt entries, on the openclaw service -----------

@test "docker-compose.yml: the openclaw service body is extractable and non-empty" {
  # Guards the negative assertion below: if the service-body extraction ever
  # matched nothing, "openclaw does not switch seccomp off wholesale" would pass
  # on an empty string while measuring nothing.
  [ -n "$OPENCLAW_SVC" ]
  grep -qE '^[[:space:]]*build:[[:space:]]*\.[[:space:]]*$' <<<"$OPENCLAW_SVC"
}

@test "docker-compose.yml: openclaw sets security_opt" {
  grep -qE '^[[:space:]]*security_opt:[[:space:]]*$' <<<"$OPENCLAW_SVC"
}

@test "docker-compose.yml: openclaw passes the repo's custom seccomp profile" {
  # Relative path: the CLI resolves it from the compose file's directory, so the
  # profile must stay committed next to docker-compose.yml.
  grep -qE '^[[:space:]]*-[[:space:]]*seccomp=\./seccomp-userns\.json[[:space:]]*$' <<<"$OPENCLAW_SVC"
}

@test "docker-compose.yml: openclaw runs AppArmor unconfined" {
  grep -qE '^[[:space:]]*-[[:space:]]*apparmor=unconfined[[:space:]]*$' <<<"$OPENCLAW_SVC"
}

@test "docker-compose.yml: openclaw does not switch seccomp off wholesale" {
  # `seccomp=unconfined` also makes bwrap work and is deliberately not what we
  # ship: it drops the whole default filter instead of adding five syscalls.
  run grep -E '^[[:space:]]*-[[:space:]]*seccomp=unconfined' <<<"$OPENCLAW_SVC"
  [ "$status" -ne 0 ]
}

@test "docker-compose.yml: the named seccomp profile exists at the repo root" {
  [ -f "$PROFILE" ]
}

# --- the profile itself -------------------------------------------------------

@test "seccomp-userns.json: parses as JSON" {
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$PROFILE"
}

@test "seccomp-userns.json: defaultAction is SCMP_ACT_ERRNO" {
  # Deny-by-default. An allow-by-default profile would pass every other
  # assertion here and enforce nothing.
  run node -e '
    const p = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    process.stdout.write(String(p.defaultAction));
  ' "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$output" = "SCMP_ACT_ERRNO" ]
}

@test "seccomp-userns.json: exactly one SCMP_ACT_ALLOW entry names the five namespace syscalls" {
  # Order-insensitive on the names; exactly one such entry, and it is an
  # unconditional allow — not gated behind a capability the container does not
  # hold, which is exactly how the stock profile's clone/unshare rule denies us.
  run node -e '
    const p = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const want = ["clone","unshare","mount","umount2","pivot_root"].sort().join(",");
    const hits = (p.syscalls || []).filter(s =>
      s.action === "SCMP_ACT_ALLOW" &&
      Array.isArray(s.names) &&
      [...s.names].sort().join(",") === want);
    if (hits.length !== 1) { console.error("entries matching the five: " + hits.length); process.exit(1); }
    const e = hits[0];
    if (e.includes && Object.keys(e.includes).length) { console.error("gated by includes"); process.exit(1); }
    if (e.excludes && Object.keys(e.excludes).length) { console.error("gated by excludes"); process.exit(1); }
    if (e.args && e.args.length) { console.error("gated by args"); process.exit(1); }
  ' "$PROFILE"
  [ "$status" -eq 0 ]
}
