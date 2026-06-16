#!/bin/bash
#
# First-boot bootstrap. Runs once (before ninjarmm-agent.service) when the
# persistent /opt/NinjaRMMAgent volume has no agent yet:
#   - download the token-stamped NinjaOne RPM from $NINJA_AGENT_URL
#   - install it (the RPM lays down /opt/NinjaRMMAgent and the systemd units)
#   - enable + start ninjarmm-agent.service
#
# With systemd as PID 1, the agent then manages its own patcher timer and the
# Lockhart backup daemon natively. On every later boot the volume already holds
# the agent, so this unit's ConditionPathExists short-circuits and it never runs.

set -euo pipefail

AGENT_BIN=/opt/NinjaRMMAgent/programfiles/ninjarmm-linagent

NINJA_AGENT_URL="${NINJA_AGENT_URL:-}"

# compose / TrueNAS Custom App pass NINJA_AGENT_URL as a container env var, which
# reaches PID 1 (systemd) but NOT the services systemd spawns. Pull it straight
# from PID 1's environ as a fallback. (Quadlet deploys get it via EnvironmentFile.)
if [ -z "$NINJA_AGENT_URL" ] && [ -r /proc/1/environ ]; then
    NINJA_AGENT_URL="$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^NINJA_AGENT_URL=//p' | head -n1)"
fi

# A URL never contains whitespace; some YAML editors fold a space or newline into
# long values (notably the TrueNAS Custom App editor), which curl then rejects.
NINJA_AGENT_URL="$(printf '%s' "$NINJA_AGENT_URL" | tr -d '[:space:]')"

if [ -x "$AGENT_BIN" ]; then
    echo "[bootstrap] agent already present in volume; nothing to do."
    exit 0
fi

if [ -z "$NINJA_AGENT_URL" ]; then
    echo "[bootstrap] FATAL: no agent in the volume and NINJA_AGENT_URL is unset." >&2
    echo "[bootstrap] Set NINJA_AGENT_URL to your NinjaOne Linux agent .rpm link" >&2
    echo "[bootstrap] (NinjaOne console -> Add Devices -> Linux -> pick distro/arch)." >&2
    exit 1
fi

echo "[bootstrap] downloading agent installer from \$NINJA_AGENT_URL ..."
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

# `|| true`: the vendor %post can return nonzero on edge cases while still
# laying down the files; verify by the binary, not the exit code.
dnf -y install "$tmp_rpm" || true
if [ ! -x "$AGENT_BIN" ]; then
    echo "[bootstrap] FATAL: install did not produce $AGENT_BIN." >&2
    exit 1
fi

# The RPM %post already enabled + started ninjarmm-agent.service. Re-assert
# enable (idempotent), but start with --no-block: a blocking start from inside
# this oneshot can wedge the boot. enable --no-reload then a no-block start.
systemctl daemon-reload
systemctl enable ninjarmm-agent.service 2>/dev/null || true
systemctl start --no-block ninjarmm-agent.service || true
echo "[bootstrap] agent installed; ninjarmm-agent.service enabled and starting."
