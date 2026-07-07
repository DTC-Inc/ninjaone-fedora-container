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

# Podman >= 4.4 ships the quadlet generator; the drop-in dir may not exist yet on
# a fresh host, so create it rather than failing.
mkdir -p "$QUADLET_DIR"

# localhost/* -> build the image here. An agent-free build is fine: the agent
# installs on first boot from NINJA_AGENT_URL (drop ./agent.rpm to bake one in).
# Anything else is pulled from a registry.
if [[ "$IMAGE" == localhost/* ]]; then
    echo "Building local image ($IMAGE)..."
    BUILDER=podman IMAGE="$IMAGE" "$REPO_ROOT/scripts/build.sh"
else
    echo "Pulling $IMAGE..."
    podman pull "$IMAGE"
fi

# Persist the agent download URL for the quadlet's EnvironmentFile (podman
# --env-file). The URL carries a NinjaOne org token, so keep it 0600 and out of
# the world-readable quadlet. podman --env-file REQUIRES the file to exist even
# when empty, so always ensure it's there:
#   - URL provided       -> write it (overwrites any stale value)
#   - URL unset + file    -> leave it (preserves a URL from a previous run)
#   - URL unset + no file -> empty 0600 placeholder so the container still boots
#                            (baked-RPM image, or a boot before the token is set)
umask 077
if [ -n "$NINJA_AGENT_URL" ]; then
    echo "Writing $AGENT_ENV_FILE..."
    printf 'NINJA_AGENT_URL=%s\n' "$NINJA_AGENT_URL" > "$AGENT_ENV_FILE"
    chmod 0600 "$AGENT_ENV_FILE"
elif [ ! -f "$AGENT_ENV_FILE" ]; then
    : > "$AGENT_ENV_FILE"
    chmod 0600 "$AGENT_ENV_FILE"
fi

# Guardrail: if nothing supplies an agent (no URL now, none baked, none stored in
# the env file) the container still boots but first-boot install has nothing to
# fetch. Warn loudly; don't fail (re-run with NINJA_AGENT_URL later still works).
if [ -z "$NINJA_AGENT_URL" ] && [ ! -f "$REPO_ROOT/agent.rpm" ] \
   && ! grep -q '^NINJA_AGENT_URL=.' "$AGENT_ENV_FILE" 2>/dev/null; then
    echo "WARNING: no NINJA_AGENT_URL, no ./agent.rpm, and no URL in $AGENT_ENV_FILE." >&2
    echo "         The container will boot but first-boot agent install will FAIL." >&2
    echo "         Re-run with: sudo NINJA_AGENT_URL='https://<console>/...agent.rpm' $0" >&2
fi

# Generate the quadlet with the resolved image baked in.
sed "s|^Image=.*|Image=$IMAGE|" "$REPO_ROOT/quadlet/ninjarmm-agent.container" > "$QUADLET_FILE"
chmod 0644 "$QUADLET_FILE"

systemctl daemon-reload
systemctl reset-failed ninjarmm-agent.service 2>/dev/null || true
# restart (not start) so re-running install.sh after an image rebuild or quadlet
# change actually recreates the container -- `start` is a no-op if it's already
# active, and would silently keep the old image.
systemctl restart ninjarmm-agent.service

sleep 4
systemctl --no-pager --lines=0 status ninjarmm-agent.service || true

echo
# The container name equals the host's hostname (quadlet ContainerName=%H).
CNAME="$(hostname)"
echo "Installed. Tail logs with:    journalctl -u ninjarmm-agent.service -f"
echo "Container logs:               podman logs -f $CNAME"
echo "Shell into container:         podman exec -it $CNAME bash"
echo "Agent + backup services:      podman exec -it $CNAME systemctl status ninjarmm-agent.service com.ninjarmm.lockhartd.service"
