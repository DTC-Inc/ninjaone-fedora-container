#!/bin/bash
# Tear down the NinjaOne Fedora Container service cleanly.
#
# Usage:
#   sudo ./scripts/uninstall.sh                # keeps the named volume (state)
#   sudo PURGE_STATE=1 ./scripts/uninstall.sh  # also removes ninjarmm-state volume
#   sudo PURGE_IMAGE=1 ./scripts/uninstall.sh  # also removes the image

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: uninstall.sh requires root (sudo)." >&2
    exit 1
fi

QUADLET_FILE="/etc/containers/systemd/ninjarmm-agent.container"

systemctl stop ninjarmm-agent.service 2>/dev/null || true
systemctl reset-failed ninjarmm-agent.service 2>/dev/null || true

# Best-effort cleanup of any host-side bind left behind.
umount /opt/NinjaRMMAgent 2>/dev/null || true

if [ -f "$QUADLET_FILE" ]; then
    rm -f "$QUADLET_FILE"
    systemctl daemon-reload
fi

podman rm -fv ninjarmm-agent 2>/dev/null || true

if [ "${PURGE_STATE:-0}" = "1" ]; then
    podman volume rm -f ninjarmm-state 2>/dev/null || true
    echo "Purged ninjarmm-state volume."
fi

if [ "${PURGE_IMAGE:-0}" = "1" ]; then
    podman rmi -f localhost/ninjaone-fedora-container:latest 2>/dev/null || true
    podman rmi -f ghcr.io/dtc-inc/ninjaone-fedora-container:latest 2>/dev/null || true
    echo "Purged image."
fi

echo "Uninstalled."
