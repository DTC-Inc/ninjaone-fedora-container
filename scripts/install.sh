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
#
# Runtime agent download (no local RPM / no build needed):
#   sudo NINJA_AGENT_URL='https://<console>/...agent.rpm' \
#        IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:latest ./scripts/install.sh
#   When NINJA_AGENT_URL is set it is written to /etc/ninjarmm-agent.env (0600),
#   and the container downloads + installs the agent on first run.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: install.sh requires root (sudo)." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-localhost/ninjaone-fedora-container:latest}"
NINJA_AGENT_URL="${NINJA_AGENT_URL:-}"
QUADLET_DIR="/etc/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/ninjarmm-agent.container"
AGENT_ENV_FILE="/etc/ninjarmm-agent.env"

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

# Persist the agent download URL for the quadlet's EnvironmentFile. The URL
# carries a NinjaOne org token, so keep it 0600 and out of the world-readable
# quadlet. Leaving NINJA_AGENT_URL unset preserves any existing env file (e.g.
# a baked-in-RPM image needs none).
if [ -n "$NINJA_AGENT_URL" ]; then
    echo "Writing $AGENT_ENV_FILE..."
    umask 077
    printf 'NINJA_AGENT_URL=%s\n' "$NINJA_AGENT_URL" > "$AGENT_ENV_FILE"
    chmod 0600 "$AGENT_ENV_FILE"
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
