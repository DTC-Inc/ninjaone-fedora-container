#!/bin/bash
#
# NinjaOne Fedora Container — entrypoint.
#
# - Initializes /state layout in the persistent volume.
# - Seeds /state/ninjarmm/app from the image baseline on first run.
# - Binds /state/ninjarmm/app over /opt/NinjaRMMAgent in the HOST mount
#   namespace so the agent (running via nsenter) sees its files at the
#   canonical path while data persists in the volume.
# - Forks a background patcher loop (calls ninjarmm-linagent-patcher
#   periodically; PATCHER_INTERVAL seconds, default 300).
# - Execs the agent into the host's mount namespace so disk, mount,
#   filesystem, and OS-release reporting reflect host reality.

set -e

STATE=/state
AGENT_BAKED=/opt/NinjaRMMAgent
AGENT_TARGET="$STATE/ninjarmm/app"
PATCHER_INTERVAL=${PATCHER_INTERVAL:-300}

mkdir -p \
    "$STATE/docdb" \
    "$STATE/db" \
    "$STATE/logs" \
    "$AGENT_TARGET"

chmod 0755 "$STATE" "$STATE/ninjarmm"

if [ -d "$AGENT_BAKED" ] && [ -z "$(ls -A "$AGENT_TARGET" 2>/dev/null)" ]; then
    echo "[entrypoint] Seeding $AGENT_TARGET from image baseline..."
    cp -a "$AGENT_BAKED/." "$AGENT_TARGET/"
fi

HOST_STATE=$(awk '$5 == "/state" { print $4; exit }' /proc/self/mountinfo)
if [ -z "$HOST_STATE" ]; then
    echo "[entrypoint] FATAL: could not resolve host path for /state volume" >&2
    exit 1
fi
HOST_AGENT_PATH="$HOST_STATE/ninjarmm/app"

echo "[entrypoint] /state on host: $HOST_STATE"
echo "[entrypoint] Agent binary on host: $HOST_AGENT_PATH/programfiles/ninjarmm-linagent"

nsenter -t 1 -m -- bash -c "
    set -e
    mkdir -p /opt/NinjaRMMAgent
    mountpoint -q /opt/NinjaRMMAgent || mount --bind '$HOST_AGENT_PATH' /opt/NinjaRMMAgent
"

(
    sleep 60
    while true; do
        nsenter -t 1 -m -- env LC_ALL=C /opt/NinjaRMMAgent/programfiles/ninjarmm-linagent-patcher \
            >/dev/null 2>&1 || true
        sleep "$PATCHER_INTERVAL"
    done
) &

exec nsenter -t 1 -m -- env DAEMON_RUN=1 LC_ALL=C \
    /opt/NinjaRMMAgent/programfiles/ninjarmm-linagent
