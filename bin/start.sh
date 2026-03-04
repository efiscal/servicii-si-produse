#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if ! docker compose pull; then
    echo "Failed to pull docker images"
    exit 1
fi
docker compose up -d
