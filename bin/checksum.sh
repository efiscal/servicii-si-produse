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

docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

echo "LINUX/AMD64:"
docker run -it --rm --platform linux/amd64 ${REGISTRY_DOMAIN}/${CORE_VERSION} cat /ecc/ecc.sha256
echo "LINUX/ARM64:"
docker run -it --rm --platform linux/arm64 ${REGISTRY_DOMAIN}/${CORE_VERSION} cat /ecc/ecc.sha256