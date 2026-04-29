#!/bin/bash
# Install the NinjaOne Fedora Container as a system service via Podman quadlet.
#
# Requires: podman, systemd, root.
# Builds the image locally first if a ./agent.rpm is present and IMAGE is unset
# or set to the localhost build target.
#
# Usage:
#   sudo ./scripts/install.sh
#   sudo IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:1.0.0 ./scripts/install.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: install.sh requires root (sudo)." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-localhost/ninjaone-fedora-container:latest}"
QUADLET_DIR="/etc/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/ninjarmm-agent.container"

if [ ! -d "$QUADLET_DIR" ]; then
    echo "FATAL: $QUADLET_DIR does not exist. Podman quadlet support requires podman >= 4.4." >&2
    exit 1
fi

# Build locally if image starts with localhost/ and we have a fresh RPM.
if [[ "$IMAGE" == localhost/* ]]; then
    if [ -f "$REPO_ROOT/agent.rpm" ]; then
        echo "Building local image..."
        BUILDER=podman IMAGE="$IMAGE" "$REPO_ROOT/scripts/build.sh"
    else
        if ! podman image exists "$IMAGE"; then
            echo "FATAL: $IMAGE not present and ./agent.rpm not available to build it." >&2
            exit 1
        fi
    fi
else
    echo "Pulling $IMAGE..."
    podman pull "$IMAGE"
fi

# Generate the quadlet with the resolved image baked in.
sed "s|^Image=.*|Image=$IMAGE|" "$REPO_ROOT/quadlet/ninjarmm-agent.container" > "$QUADLET_FILE"
chmod 0644 "$QUADLET_FILE"

systemctl daemon-reload
systemctl reset-failed ninjarmm-agent.service 2>/dev/null || true
systemctl start ninjarmm-agent.service

sleep 4
systemctl --no-pager --lines=0 status ninjarmm-agent.service || true

echo
echo "Installed. Tail logs with:    journalctl -u ninjarmm-agent.service -f"
echo "Container logs:               podman logs -f ninjarmm-agent"
echo "Shell into container:         podman exec -it ninjarmm-agent bash"
