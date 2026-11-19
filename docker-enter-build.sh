#!/bin/bash
# Openterface QT Shared Build Script
# # Uses Docker image with static Qt6 build
#
# set -e
#
# Configuration
DOCKER_IMAGE="ghcr.io/chow411/shared-qtbuild-complete:sha-ca1b7d7-amd64"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"

echo "=== Openterface QT Static Build Script ==="
echo "Project directory: ${PROJECT_DIR}"
echo "Build directory: ${BUILD_DIR}"
echo "Docker image: ${DOCKER_IMAGE}"
echo
docker run -ti --rm \
    -v "${PROJECT_DIR}:/workspace/src" \
    -w "/workspace/src" \
    "${DOCKER_IMAGE}" \
    bash 
