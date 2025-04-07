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

WORKING_DIR=$(pwd)

# Get current user and groupe
USER_ID=$(id -u)
GROUP_ID=$(id -g)
# Get current date
CURRENT_DATE=$(date +"%Y%m%d")

# Set archive file name with current date
ARCHIVE_AMD64_FILE="ecc_$CURRENT_DATE.amd64.tar.gz"
ARCHIVE_ARM64_FILE="ecc_$CURRENT_DATE.arm64.tar.gz"

# AMD64
docker run -it --rm --platform linux/amd64 -v "${WORKING_DIR}:/archival" --user "${USER_ID}:${GROUP_ID}" ${REGISTRY_DOMAIN}/${CORE_VERSION} tar czf /archival/$ARCHIVE_AMD64_FILE /ecc
if [ $? -ne 0 ]; then
    echo "failed to create archive file"
    exit 1
fi

zip -r $WORKING_DIR/$ARCHIVE_AMD64_FILE.zip $ARCHIVE_AMD64_FILE
if [ $? -ne 0 ]; then
    echo "Failed to create zip archive: $WORKING_DIR/$ARCHIVE_AMD64_FILE.zip"
    exit 1
fi
echo "archived amd64 successfully"

# ARM64
docker run -it --rm --platform linux/arm64 -v "${WORKING_DIR}:/archival" --user "${USER_ID}:${GROUP_ID}" ${REGISTRY_DOMAIN}/${CORE_VERSION} tar czf /archival/$ARCHIVE_ARM64_FILE /ecc
if [ $? -ne 0 ]; then
    echo "failed to create archive file"
    exit 1
fi

zip -r $WORKING_DIR/$ARCHIVE_ARM64_FILE.zip $ARCHIVE_ARM64_FILE
if [ $? -ne 0 ]; then
    echo "Failed to create zip archive: $WORKING_DIR/$ARCHIVE_ARM64_FILE.zip"
    exit 1
fi
echo "archived arm64 successfully"
