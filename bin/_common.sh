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

# Resolve the docker compose project name instead of hardcoding it, so volume
# names (${PROJECT}_<vol>) stay in sync if docker-compose.yml's `name:` changes.
# `docker compose config` honors the name: key, COMPOSE_PROJECT_NAME, -p and the
# directory-name fallback, i.e. the same value `docker compose` itself uses.
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required but not installed. Install it and retry."
    exit 1
fi
PROJECT=$(docker compose config --format json | jq -r '.name')
if [ -z "$PROJECT" ] || [ "$PROJECT" = "null" ]; then
    echo "ERROR: could not determine docker compose project name."
    exit 1
fi
