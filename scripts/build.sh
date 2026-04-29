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
FEDORA_VERSION="${FEDORA_VERSION:-41}"

if [ ! -f "$RPM_PATH" ]; then
    echo "FATAL: $RPM_PATH not found." >&2
    echo "Download a token-stamped agent RPM from NinjaOne and place it at $RPM_PATH." >&2
    exit 1
fi

# Buildah/Podman expects the build context to contain the RPM at ./agent.rpm.
# Copy in if necessary; tolerate the case where it's already at the path.
BUILD_CTX="$(mktemp -d)"
trap 'rm -rf "$BUILD_CTX"' EXIT

cp "$REPO_ROOT/docker/Containerfile" "$BUILD_CTX/Containerfile"
cp "$REPO_ROOT/docker/entrypoint.sh" "$BUILD_CTX/entrypoint.sh"
cp "$RPM_PATH" "$BUILD_CTX/agent.rpm"

echo "Building $IMAGE with $BUILDER (Fedora $FEDORA_VERSION)..."
"$BUILDER" build \
    --build-arg "FEDORA_VERSION=$FEDORA_VERSION" \
    -t "$IMAGE" \
    "$BUILD_CTX"

echo "Built $IMAGE"
