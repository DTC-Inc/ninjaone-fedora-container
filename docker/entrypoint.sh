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

# The agent install ($AGENT_TARGET, inside the persistent volume) has to appear
# at the canonical /opt/NinjaRMMAgent in the HOST mount namespace, since that's
# where the agent (run via nsenter) and its self-updater expect it. To bind it
# there we need the volume's REAL path in the host namespace.
#
# Two earlier approaches failed:
#   - /proc/self/mountinfo field 4 (the mount's root WITHIN its filesystem) is
#     only a valid host path when that filesystem is mounted at the host root
#     (podman on ostree). On TrueNAS SCALE the Docker volumes live on a separate
#     dataset, so field 4 (/volumes/<name>/_data) doesn't exist at that location
#     in the host ns -> "special device ... does not exist".
#   - Binding via the entrypoint's /proc/<pid>/root/<path> reads fine across
#     namespaces but is rejected as a bind SOURCE, because the subtree lives on
#     a mount that belongs to the container's namespace, not the host's
#     -> "wrong fs type, bad option, bad superblock".
#
# Resolve it properly: the filesystem device id (mountinfo field 3) is global
# across namespaces, so match /state's device between this container and the
# host (/proc/1/mountinfo, host init via --pid=host), then translate field 4
# through the host mount's own root to get the real host-ns path. Binding from
# that path is an ordinary same-namespace bind the kernel allows.
read -r STATE_DEV STATE_ROOT < <(awk '$5 == "/state" { print $3, $4; exit }' /proc/self/mountinfo)
if [ -z "$STATE_DEV" ]; then
    echo "[entrypoint] FATAL: /state is not a mount; cannot resolve its host path." >&2
    exit 1
fi
HOST_STATE=$(awk -v dev="$STATE_DEV" -v croot="$STATE_ROOT" '
    $3 == dev {
        mp = $5; r = $4
        if (r == "/")                       rel = croot
        else if (croot == r)                rel = ""
        else if (index(croot, r "/") == 1)  rel = substr(croot, length(r) + 1)
        else                                next
        if (length(r) >= bestlen) { bestlen = length(r); best = mp rel }
    }
    END { if (best != "") print best }
' /proc/1/mountinfo)
if [ -z "$HOST_STATE" ]; then
    echo "[entrypoint] FATAL: could not resolve host path for /state (dev=$STATE_DEV root=$STATE_ROOT)." >&2
    echo "[entrypoint] host mounts on that device:" >&2
    awk -v dev="$STATE_DEV" '$3 == dev { print "  " $0 }' /proc/1/mountinfo >&2
    exit 1
fi
HOST_AGENT_PATH="$HOST_STATE/ninjarmm/app"
echo "[entrypoint] /state host path: $HOST_STATE"
echo "[entrypoint] Binding $HOST_AGENT_PATH onto /opt/NinjaRMMAgent in host ns"

# Creating the /opt/NinjaRMMAgent mountpoint writes to the host root; on hosts
# where / is read-only with no writable /opt redirect (TrueNAS SCALE and similar
# appliances — unlike ostree distros where /opt -> /var/opt is writable) the
# mkdir fails. In that case overlay /opt with a tmpfs just to hold the bind
# target; the bind itself is a VFS op and works on a read-only root once the
# mountpoint exists.
#
# Mount the tmpfs unconditionally once the mkdir has proven /opt is read-only:
# on these appliances /opt is itself already a (read-only) mountpoint, so a
# `mountpoint -q /opt` guard would see it mounted and wrongly skip the overlay,
# leaving the next mkdir to fail on the still-read-only filesystem. The tmpfs
# stacks over the read-only mount and shadows it; agent data still persists in
# the named volume via the bind below. Restart is idempotent — once the tmpfs
# is in place the first mkdir succeeds, so the overlay never double-stacks.
nsenter -t 1 -m -- bash -c "
    set -e
    if ! mkdir -p /opt/NinjaRMMAgent 2>/dev/null; then
        echo '[entrypoint] host /opt is read-only; overlaying it with tmpfs for the agent mountpoint.'
        mount -t tmpfs tmpfs /opt
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
