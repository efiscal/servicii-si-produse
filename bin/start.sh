#!/bin/bash

CURRENT_SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd $CURRENT_SCRIPT_PATH/..
docker compose pull
if [ $? -ne 0 ]; then
    echo "Failed to pull docker images"
    exit 1
fi
docker compose up -d