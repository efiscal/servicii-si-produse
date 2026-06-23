#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Start the stack. Rather than always pulling, decide per image:
#   - not present locally          -> pull it (no version to compare against)
#   - present, newer in registry   -> offer to pull/update
#   - present, already up to date   -> leave it as is
#   - present, registry unreachable -> say so and keep using the local image
#
# A registry that is down or not responding is never fatal: we print a notice
# and carry on with whatever images are already present locally.

# How long to wait on the registry before treating it as "not responding".
REGISTRY_TIMEOUT=15

# When set, skip the whole image check/pull step and start with local images.
SKIP_CHECK=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [-n|--no-check] [-h|--help]

Start the stack. By default each image is checked against the registry and, if a
newer version exists, you are offered to pull it; missing images are pulled
automatically. A registry that is down is never fatal -- it is reported and the
local images are used.

Options:
  -n, --no-check   Skip the image version check/pull entirely and just start the
                   stack with whatever images are present locally.
  -h, --help       Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n | --no-check)
            SKIP_CHECK=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# sha256 manifest digest of the image stored LOCALLY (empty if unknown).
local_digest() {
    local ref="$1"
    local repo="${ref%:*}"
    docker image inspect "$ref" --format '{{json .RepoDigests}}' 2>/dev/null \
        | jq -r --arg repo "$repo" '.[]? | select(startswith($repo + "@")) | sub(".*@"; "")' \
        | head -1
}

# sha256 manifest digest of the image in the REGISTRY. Empty if the registry is
# unreachable, not responding (timeout) or the tag is missing.
remote_digest() {
    timeout "$REGISTRY_TIMEOUT" docker buildx imagetools inspect "$1" \
        --format '{{.Manifest.Digest}}' 2>/dev/null
}

# Yes/no question that DEFAULTS TO YES (press Enter to accept).
confirm_yes() {
    local reply
    read -r -p "$1 [Y/n] " reply
    case "${reply:-Y}" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$SKIP_CHECK" = "1" ]; then
    echo "Skipping image check (--no-check); starting with local images..."
    docker compose up -d
    exit $?
fi

# Resolve services -> images from the compose config.
mapfile -t SVC_IMG < <(docker compose config --format json \
    | jq -r '.services | to_entries[] | "\(.key)\t\(.value.image)"')

if [ "${#SVC_IMG[@]}" -eq 0 ]; then
    echo "ERROR: could not read any services/images from the compose config."
    exit 1
fi

declare -A IMG_STATUS      # image -> missing|current|update|unknown|registry-error
declare -A IMG_DECISION    # image -> pull|skip (cached after prompting once)
PULL_SERVICES=()
REGISTRY_PROBLEM=0

echo "Checking images..."
for line in "${SVC_IMG[@]}"; do
    svc="${line%%$'\t'*}"
    img="${line#*$'\t'}"

    # Determine the status of each unique image only once.
    if [ -z "${IMG_STATUS[$img]:-}" ]; then
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            IMG_STATUS[$img]="missing"
        else
            rd=$(remote_digest "$img")
            if [ -z "$rd" ]; then
                IMG_STATUS[$img]="registry-error"
                REGISTRY_PROBLEM=1
            else
                ld=$(local_digest "$img")
                if [ -z "$ld" ]; then
                    IMG_STATUS[$img]="unknown"
                elif [ "$ld" = "$rd" ]; then
                    IMG_STATUS[$img]="current"
                else
                    IMG_STATUS[$img]="update"
                fi
            fi
        fi
    fi

    case "${IMG_STATUS[$img]}" in
        missing)
            echo "  [$svc] $img: not present locally -> will pull"
            PULL_SERVICES+=("$svc")
            ;;
        current)
            echo "  [$svc] $img: up to date"
            ;;
        registry-error)
            echo "  [$svc] $img: present locally; registry not responding -> using local image"
            ;;
        update | unknown)
            # Prompt once per image; reuse the decision for its other services.
            if [ -z "${IMG_DECISION[$img]:-}" ]; then
                if [ "${IMG_STATUS[$img]}" = "update" ]; then
                    prompt="  $img: a newer version is available in the registry. Pull/update?"
                else
                    prompt="  $img: present, but its version cannot be verified. Pull anyway?"
                fi
                if confirm_yes "$prompt"; then
                    IMG_DECISION[$img]="pull"
                else
                    IMG_DECISION[$img]="skip"
                fi
            fi
            if [ "${IMG_DECISION[$img]}" = "pull" ]; then
                PULL_SERVICES+=("$svc")
            fi
            ;;
    esac
done

if [ "$REGISTRY_PROBLEM" = "1" ]; then
    echo
    echo "WARNING: the docker registry appears to be having problems (unreachable or"
    echo "         not responding within ${REGISTRY_TIMEOUT}s). Continuing with the"
    echo "         images already present locally."
fi

if [ "${#PULL_SERVICES[@]}" -gt 0 ]; then
    echo
    echo "Pulling: ${PULL_SERVICES[*]}"
    if ! docker compose pull "${PULL_SERVICES[@]}"; then
        echo "WARNING: one or more pulls failed (registry problems?). Continuing anyway."
    fi
fi

echo
echo "Starting stack..."
docker compose up -d
