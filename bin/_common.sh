#!/bin/bash

set -euo pipefail

CURRENT_SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[1]}")" &>/dev/null && pwd)
cd "$CURRENT_SCRIPT_PATH/.."

# Load environment variables from .env file
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo ".env file not found!"
    exit 1
fi
