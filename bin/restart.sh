#!/bin/bash

CURRENT_SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

bash "$CURRENT_SCRIPT_PATH/stop.sh"
bash "$CURRENT_SCRIPT_PATH/start.sh"
