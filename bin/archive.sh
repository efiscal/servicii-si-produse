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

WORKING_DIR=$(pwd)

# Get current user and groupe
USER_ID=$(id -u)
GROUP_ID=$(id -g)
# Get current date
CURRENT_DATE=$(date +"%Y%m%d")

# Set archive file name with current date
ARCHIVE_FILE="ecc_$CURRENT_DATE.tar.gz"

docker run -it --rm -v "${WORKING_DIR}:/archival" --user "${USER_ID}:${GROUP_ID}" ${REGISTRY_DOMAIN}/${CORE_VERSION} tar czf /archival/$ARCHIVE_FILE /ecc
if [ $? -ne 0 ]; then
    echo "failed to create archive file"
    exit 1
fi
zip -r $WORKING_DIR/$ARCHIVE_FILE.zip $ARCHIVE_FILE
echo "archived successfully"