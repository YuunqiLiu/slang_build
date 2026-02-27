#!/bin/bash
# Build and test pyslang wheels using the CentOS 7 Docker container.
# Usage: ./scripts/build_in_docker.sh [version]
# Example: ./scripts/build_in_docker.sh 1.0.0
#
# Uses the pre-baked builder image (ghcr.io/yuunqiliu/slang-builder:latest)
# if available — it has patchelf + Python 3.8-3.11 envs pre-installed, making
# builds much faster. Falls back to the base image if builder is not found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION="${1:-}"

BUILDER_IMAGE="ghcr.io/yuunqiliu/slang-builder:latest"
BASE_IMAGE="ghcr.io/yuunqiliu/centos7-gcc14:latest"

echo ">>> Checking for pre-baked builder image..."
if docker pull "$BUILDER_IMAGE" 2>/dev/null; then
    DOCKER_IMAGE="$BUILDER_IMAGE"
    echo ">>> Using builder image (faster — envs pre-installed): $DOCKER_IMAGE"
else
    DOCKER_IMAGE="$BASE_IMAGE"
    echo ">>> Builder image not found; using base image (will install envs): $DOCKER_IMAGE"
    docker pull "$DOCKER_IMAGE"
fi

echo ">>> Building wheels in Docker..."
# Use --network host and forward proxy environment for network access
PROXY_ARGS=""
if [ -n "${http_proxy:-}" ]; then
    PROXY_ARGS="-e http_proxy=$http_proxy -e https_proxy=${https_proxy:-} -e HTTP_PROXY=${HTTP_PROXY:-} -e HTTPS_PROXY=${HTTPS_PROXY:-} -e no_proxy=${no_proxy:-}"
fi

docker run --rm \
    --network host \
    $PROXY_ARGS \
    -v "$PROJECT_DIR":/workspace \
    -w /workspace \
    "$DOCKER_IMAGE" \
    bash -c "
        chmod +x /workspace/scripts/build_wheels.sh /workspace/scripts/test_wheels.sh
        /workspace/scripts/build_wheels.sh ${VERSION}
        /workspace/scripts/test_wheels.sh
    "

echo ""
echo ">>> Build complete. Wheels:"
ls -la "$PROJECT_DIR/dist/"*.whl
