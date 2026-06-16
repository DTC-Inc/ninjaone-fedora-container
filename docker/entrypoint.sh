#!/bin/bash
#
# NinjaOne Fedora Container — entrypoint.
#
# - Initializes /state layout in the persistent volume.
# - Ensures the agent is installed, in priority order:
#     1. already present in the volume  -> skip (idempotent across restarts)
#     2. baked into the image           -> seed from the image baseline
#     3. NINJA_AGENT_URL set            -> download + install the RPM, then seed
#   The volume is the source of truth, so the download only ever happens on a
#   first run with no agent baked in — never on a plain restart.
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
AGENT_BIN_REL="programfiles/ninjarmm-linagent"
PATCHER_INTERVAL=${PATCHER_INTERVAL:-300}
NINJA_AGENT_URL="${NINJA_AGENT_URL:-}"
# Strip whitespace some compose editors fold into long values (notably the
# TrueNAS Custom App YAML editor, which wraps long lines and injects a space or
# newline mid-URL — curl then rejects it as "Malformed input to a URL
# function"). A URL never contains literal whitespace, so this is safe.
NINJA_AGENT_URL="$(printf '%s' "$NINJA_AGENT_URL" | tr -d '[:space:]')"

mkdir -p \
    "$STATE/docdb" \
    "$STATE/db" \
    "$STATE/logs" \
    "$AGENT_TARGET"

chmod 0755 "$STATE" "$STATE/ninjarmm"

# Resolve the agent install. The volume is authoritative and persists across
# restarts, so a populated volume short-circuits everything below — the
# NINJA_AGENT_URL download only fires on a first run with nothing baked in.
if [ -x "$AGENT_TARGET/$AGENT_BIN_REL" ]; then
    echo "[entrypoint] NinjaOne agent already present in volume; skipping install."
elif [ -x "$AGENT_BAKED/$AGENT_BIN_REL" ]; then
    echo "[entrypoint] Seeding $AGENT_TARGET from image baseline..."
    cp -a "$AGENT_BAKED/." "$AGENT_TARGET/"
elif [ -n "$NINJA_AGENT_URL" ]; then
    echo "[entrypoint] No agent in volume or image; downloading installer from \$NINJA_AGENT_URL..."
    tmp_rpm="$(mktemp --suffix=.rpm)"
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$tmp_rpm" "$NINJA_AGENT_URL"; then
        echo "[entrypoint] FATAL: download failed from NINJA_AGENT_URL." >&2
        rm -f "$tmp_rpm"
        exit 1
    fi
    # Guard against a non-RPM body (e.g. an HTML error page from a stale link).
    if ! rpm -qp "$tmp_rpm" >/dev/null 2>&1; then
        echo "[entrypoint] FATAL: NINJA_AGENT_URL did not return a valid RPM." >&2
        rm -f "$tmp_rpm"
        exit 1
    fi
    # `|| true`: the vendor RPM's scriptlets assume a systemd host and fail in
    # the container — harmless, since we run the binary directly via nsenter.
    dnf -y install "$tmp_rpm" || true
    rm -f "$tmp_rpm"
    if [ ! -x "$AGENT_BAKED/$AGENT_BIN_REL" ]; then
        echo "[entrypoint] FATAL: install did not produce $AGENT_BAKED/$AGENT_BIN_REL." >&2
        exit 1
    fi
    echo "[entrypoint] Seeding $AGENT_TARGET from freshly installed agent..."
    cp -a "$AGENT_BAKED/." "$AGENT_TARGET/"
else
    echo "[entrypoint] FATAL: no agent in volume, none baked into the image, and NINJA_AGENT_URL is unset." >&2
    echo "[entrypoint] Set NINJA_AGENT_URL to your NinjaOne Linux agent .rpm download link" >&2
    echo "[entrypoint] (NinjaOne console -> Add Devices -> Linux -> pick distro/arch), or bake an agent.rpm at build time." >&2
    exit 1
fi

HOST_STATE=$(awk '$5 == "/state" { print $4; exit }' /proc/self/mountinfo)
if [ -z "$HOST_STATE" ]; then
    echo "[entrypoint] FATAL: could not resolve host path for /state volume" >&2
    exit 1
fi
HOST_AGENT_PATH="$HOST_STATE/ninjarmm/app"

echo "[entrypoint] /state on host: $HOST_STATE"
echo "[entrypoint] Agent binary on host: $HOST_AGENT_PATH/programfiles/ninjarmm-linagent"

# Make the agent install visible at the canonical /opt/NinjaRMMAgent in the
# host mount namespace. Creating the mountpoint writes to the host root; on
# hosts where / is read-only with no writable /opt redirect (TrueNAS SCALE and
# similar appliances — unlike ostree distros where /opt -> /var/opt is
# writable) the mkdir fails. In that case overlay /opt with a tmpfs just to
# hold the bind target. The bind itself is a VFS op and works on a read-only
# root once the mountpoint exists.
nsenter -t 1 -m -- bash -c "
    set -e
    if ! mkdir -p /opt/NinjaRMMAgent 2>/dev/null; then
        echo '[entrypoint] host /opt is read-only; overlaying it with tmpfs for the agent mountpoint.'
        mountpoint -q /opt || mount -t tmpfs tmpfs /opt
        mkdir -p /opt/NinjaRMMAgent
    fi
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
