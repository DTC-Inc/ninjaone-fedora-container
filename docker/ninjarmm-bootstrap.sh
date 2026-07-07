#!/bin/bash
#
# Boot-time agent wiring.
#
# The NinjaOne agent's files and runtime state/identity live in the persistent
# /opt/NinjaRMMAgent volume, but the RPM also installs systemd *units*
# (ninjarmm-agent.service, the patcher timer, ...) into /usr/lib/systemd/system --
# the container's own filesystem, which is EPHEMERAL: the quadlet runs the
# container with --rm/--replace, so every restart or image update yields a fresh
# rootfs with no agent units. If we installed only on the very first boot, a later
# recreate would leave the agent binary orphaned in the volume with nothing to run
# it, and the box would stop checking in.
#
# So this runs on every boot where the agent unit is absent and (re)lays it:
#   - Cache the downloaded RPM in the volume (survives recreation).
#   - First boot ever: download from $NINJA_AGENT_URL, cache it, install.
#   - Any later fresh container: install from the cached RPM (no network needed).
#   - Enable + (non-blocking) start ninjarmm-agent.service.
# The agent then reads its identity from the volume (so it re-attaches as the same
# device, not a new one) and re-creates its own runtime-managed units -- notably
# the Lockhart backup daemon, which it (re)installs and starts when a backup
# policy applies.
#
# The unit's ConditionPathExists=!/usr/lib/systemd/system/ninjarmm-agent.service
# skips all this once the agent is wired (e.g. a baked-in-RPM image).

set -euo pipefail

AGENT_UNIT=/usr/lib/systemd/system/ninjarmm-agent.service
CACHED_RPM=/opt/NinjaRMMAgent/.bootstrap/agent.rpm

# Already wired (baked image, or a re-run within the same boot): nothing to do.
if [ -e "$AGENT_UNIT" ]; then
    echo "[bootstrap] agent systemd unit already present; nothing to do."
    exit 0
fi

# Obtain the RPM: reuse the volume-cached copy if present, else download it once.
if [ ! -s "$CACHED_RPM" ]; then
    NINJA_AGENT_URL="${NINJA_AGENT_URL:-}"
    # compose / TrueNAS Custom App pass NINJA_AGENT_URL to PID 1 (systemd) but NOT
    # to the services it spawns; read it straight from PID 1's environ as a
    # fallback. (Quadlet deploys get it via the unit's EnvironmentFile.)
    if [ -z "$NINJA_AGENT_URL" ] && [ -r /proc/1/environ ]; then
        NINJA_AGENT_URL="$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^NINJA_AGENT_URL=//p' | head -n1)"
    fi
    # A URL never contains whitespace; some YAML editors fold a space/newline into
    # long values (notably the TrueNAS Custom App editor), which curl then rejects.
    NINJA_AGENT_URL="$(printf '%s' "$NINJA_AGENT_URL" | tr -d '[:space:]')"

    if [ -z "$NINJA_AGENT_URL" ]; then
        echo "[bootstrap] FATAL: no cached agent RPM and NINJA_AGENT_URL is unset." >&2
        echo "[bootstrap] Set NINJA_AGENT_URL to your NinjaOne Linux agent .rpm link" >&2
        echo "[bootstrap] (NinjaOne console -> Add Devices -> Linux -> pick distro/arch)." >&2
        exit 1
    fi

    echo "[bootstrap] downloading agent installer from \$NINJA_AGENT_URL ..."
    mkdir -p "$(dirname "$CACHED_RPM")"
    tmp_rpm="$(mktemp --suffix=.rpm)"
    trap 'rm -f "$tmp_rpm"' EXIT
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$tmp_rpm" "$NINJA_AGENT_URL"; then
        echo "[bootstrap] FATAL: download failed from NINJA_AGENT_URL." >&2
        exit 1
    fi
    if ! rpm -qp "$tmp_rpm" >/dev/null 2>&1; then
        echo "[bootstrap] FATAL: NINJA_AGENT_URL did not return a valid RPM." >&2
        exit 1
    fi
    mv "$tmp_rpm" "$CACHED_RPM"
    chmod 600 "$CACHED_RPM"   # org-stamped installer -- keep it root-only
    echo "[bootstrap] cached agent RPM in the volume for future boots."
fi

# Install from the cached RPM. This lays the systemd units + rpmdb into this
# (fresh) container and the agent files into the volume; the agent's runtime
# state/identity in the volume is untouched, so it re-attaches as the same device.
# `|| true`: the vendor %post can exit nonzero while still laying down files --
# verify by the unit, not the exit code.
echo "[bootstrap] installing agent from cached RPM ..."
dnf -y install "$CACHED_RPM" || true
if [ ! -e "$AGENT_UNIT" ]; then
    echo "[bootstrap] FATAL: install did not produce $AGENT_UNIT." >&2
    exit 1
fi

systemctl daemon-reload
# Enable and enqueue the start WITHOUT blocking: this oneshot is ordered
# Before=ninjarmm-agent.service, so a blocking start deadlocks (systemctl waits on
# the agent's start job, which systemd holds until this unit finishes). --no-block
# queues it and lets us exit; the agent starts as this oneshot completes (and on
# later boots via multi-user.target).
systemctl enable ninjarmm-agent.service
systemctl start --no-block ninjarmm-agent.service
echo "[bootstrap] agent wired up; ninjarmm-agent.service start enqueued."
