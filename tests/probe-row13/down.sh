#!/usr/bin/env bash
# down.sh — remove the probe container and its volume. Requires --yes.
#
# Deletes ONLY openclaw-row13-probe and row13-probe-data. The guards in
# common.sh make the live names unaddressable from here; this script also
# re-checks each name against the forbidden list immediately before the
# destructive verb, because that is the one place where a copy-paste mistake
# would be irreversible.
#
# The owner's Claude login lives on the volume, so removing it means owner
# action O4a has to be repeated. `down.sh --yes --keep-volume` keeps it.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

YES=no; KEEP_VOLUME=no
for a in "$@"; do
  case "$a" in
    --yes) YES=yes;;
    --keep-volume) KEEP_VOLUME=yes;;
    *) die "unknown argument: $a (usage: down.sh --yes [--keep-volume])";;
  esac
done

require_docker
guard_names

if [ "$YES" != yes ]; then
  say "This would remove:"
  say "  container $PROBE_CONTAINER"
  [ "$KEEP_VOLUME" = yes ] && say "  volume    $PROBE_VOLUME (KEPT: --keep-volume)" || say "  volume    $PROBE_VOLUME (and with it the probe HOME login, owner action O4a)"
  say ""
  say "Nothing was done. Re-run with --yes."
  verdict 6 "BLOCKED (no --yes)"
  exit 0
fi

for n in $FORBIDDEN_CONTAINERS; do [ "$PROBE_CONTAINER" = "$n" ] && die "refusing: $n is live"; done
if docker container inspect "$PROBE_CONTAINER" >/dev/null 2>&1; then
  img="$(docker inspect -f '{{.Config.Image}}' "$PROBE_CONTAINER")"
  [ "$img" = "$PROBE_IMAGE" ] || die "refusing: $PROBE_CONTAINER runs '$img', not the candidate image"
  docker rm -f "$PROBE_CONTAINER" >/dev/null
  say "removed container $PROBE_CONTAINER"
else
  say "container $PROBE_CONTAINER: already absent"
fi

if [ "$KEEP_VOLUME" = yes ]; then
  say "volume $PROBE_VOLUME: kept"
else
  for n in $FORBIDDEN_VOLUMES; do [ "$PROBE_VOLUME" = "$n" ] && die "refusing: $n is live"; done
  if docker volume inspect "$PROBE_VOLUME" >/dev/null 2>&1; then
    docker volume rm "$PROBE_VOLUME" >/dev/null
    say "removed volume $PROBE_VOLUME"
  else
    say "volume $PROBE_VOLUME: already absent"
  fi
fi

hr "far-side check"
docker ps -a --filter "name=$PROBE_CONTAINER" --format '{{.Names}} {{.Status}}' || true
docker volume ls --filter "name=$PROBE_VOLUME" --format '{{.Name}}' || true
say "(empty above = gone; the three live names are untouched:)"
docker ps --format '{{.Names}} {{.Ports}}'

verdict 6 "PASS"
