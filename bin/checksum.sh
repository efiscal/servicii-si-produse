#!/bin/bash

CURRENT_SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd $CURRENT_SCRIPT_PATH/..
# Load environment variables from .env file
if [ -f .env ]; then
    export $(cat .env | xargs)
else
    echo ".env file not found!"
    exit 1
fi

docker run --rm --privileged multiarch/qemu-user-static --reset -p yes &>/dev/null
if [ $? -ne 0 ]; then
    echo "Failed to run multiarch/qemu-user-static"
    exit 1
fi

amd64_output=$(docker run -it --rm --platform linux/amd64 ${REGISTRY_DOMAIN}/${CORE_VERSION} cat /ecc/ecc.sha256 2>/dev/null)
echo "LINUX/AMD64: $amd64_output"

arm64_output=$(docker run -it --rm --platform linux/arm64 ${REGISTRY_DOMAIN}/${CORE_VERSION} cat /ecc/ecc.sha256 2>/dev/null)
echo "LINUX/ARM64: $arm64_output"