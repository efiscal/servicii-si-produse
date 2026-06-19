#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Backup the named docker volumes (app + db) into ./backups as tar.gz archives.
# The stack is stopped first so CockroachDB's data directory is in a consistent
# state, then started again once the archives are written.

PROJECT="ecc-sp"
VOLUMES=("app" "db")

BACKUP_DIR="backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "Stopping stack for a consistent snapshot..."
docker compose stop

# Make sure nothing is still running/restarting before we touch the volumes.
# Poll until docker reports no running containers for the project, then fail
# loudly if anything refuses to die.
echo "Verifying all containers are stopped..."
for _ in $(seq 1 30); do
    running=$(docker compose ps --status running --status restarting -q)
    [ -z "$running" ] && break
    sleep 1
done

running=$(docker compose ps --status running --status restarting -q)
if [ -n "$running" ]; then
    echo "ERROR: some containers are still running after stop:"
    docker compose ps --status running --status restarting
    echo "Aborting backup to avoid an inconsistent snapshot."
    exit 1
fi
echo "All containers stopped."

for vol in "${VOLUMES[@]}"; do
    full_name="${PROJECT}_${vol}"
    archive="${vol}-${TIMESTAMP}.tar.gz"
    echo "Backing up volume ${full_name} -> ${BACKUP_DIR}/${archive}"
    docker run --rm \
        -v "${full_name}:/data:ro" \
        -v "$(pwd)/${BACKUP_DIR}:/backup" \
        alpine \
        tar czf "/backup/${archive}" -C /data .
done

echo "Starting stack..."
docker compose start

echo "Done. Archives written to ${BACKUP_DIR}/"
ls -lh "$BACKUP_DIR"
