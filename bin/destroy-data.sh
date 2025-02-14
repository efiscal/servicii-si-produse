#!/bin/bash

CURRENT_SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
cd $CURRENT_SCRIPT_PATH/..
docker compose down -v