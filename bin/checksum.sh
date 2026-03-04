#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if ! docker run --rm --privileged multiarch/qemu-user-static --reset -p yes &>/dev/null; then
    echo "Failed to run multiarch/qemu-user-static"
    exit 1
fi

amd64_output=$(docker run --rm --platform linux/amd64 "${REGISTRY_DOMAIN}/${CORE_VERSION}" cat /ecc/ecc.sha256 2>/dev/null)
echo "LINUX/AMD64: $amd64_output"

arm64_output=$(docker run --rm --platform linux/arm64 "${REGISTRY_DOMAIN}/${CORE_VERSION}" cat /ecc/ecc.sha256 2>/dev/null)
echo "LINUX/ARM64: $arm64_output"
