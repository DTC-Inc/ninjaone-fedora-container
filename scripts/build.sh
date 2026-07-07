#!/bin/bash
# Build the NinjaOne Fedora Container image locally.
#
# Expects a token-stamped NinjaOne RPM at the repo root as ./agent.rpm
# (download from your NinjaOne console — Add Devices → Linux → Fedora/RHEL).
#
# Usage:
#   ./scripts/build.sh                    # uses podman
#   BUILDER=docker ./scripts/build.sh     # uses docker
#   IMAGE=ghcr.io/dtc-inc/ninjaone-fedora-container:custom ./scripts/build.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER="${BUILDER:-podman}"
IMAGE="${IMAGE:-localhost/ninjaone-fedora-container:latest}"
RPM_PATH="${RPM_PATH:-$REPO_ROOT/agent.rpm}"
FEDORA_VERSION="${FEDORA_VERSION:-42}"

BUILD_CTX="$(mktemp -d)"
trap 'rm -rf "$BUILD_CTX"' EXIT

cp "$REPO_ROOT/docker/Containerfile" "$BUILD_CTX/Containerfile"
cp "$REPO_ROOT/docker/ninjarmm-bootstrap.sh" "$BUILD_CTX/ninjarmm-bootstrap.sh"
cp "$REPO_ROOT/docker/ninjarmm-bootstrap.service" "$BUILD_CTX/ninjarmm-bootstrap.service"
cp "$REPO_ROOT/docker/in-host" "$BUILD_CTX/in-host"

# Two ways to supply the agent:
#   1) Bake it in  -- drop a token-stamped RPM at ./agent.rpm; it installs at build.
#   2) Runtime URL -- no ./agent.rpm; stage a zero-byte placeholder (exactly as CI
#      does) and the container downloads the agent on first boot from
#      NINJA_AGENT_URL. This is the public, agent-free image.
if [ -f "$RPM_PATH" ]; then
    echo "Baking in agent RPM from $RPM_PATH"
    cp "$RPM_PATH" "$BUILD_CTX/agent.rpm"
else
    echo "No $RPM_PATH -- building an AGENT-FREE image (the agent installs on first"
    echo "boot via NINJA_AGENT_URL). Drop a token-stamped ./agent.rpm to bake one in."
    : > "$BUILD_CTX/agent.rpm"
fi

echo "Building $IMAGE with $BUILDER (Fedora $FEDORA_VERSION)..."
"$BUILDER" build \
    --build-arg "FEDORA_VERSION=$FEDORA_VERSION" \
    -t "$IMAGE" \
    "$BUILD_CTX"

echo "Built $IMAGE"
