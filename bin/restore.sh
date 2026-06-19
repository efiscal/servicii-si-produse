#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Restore the named docker volumes (app + db) from ./backups tar.gz archives.
# The stack is stopped first so CockroachDB's data directory is replaced in a
# consistent state, then started again once the archives are extracted.
#
# Usage: bin/restore.sh [TIMESTAMP]
#   TIMESTAMP   The backup timestamp to restore, e.g. 20260619-143000.
#               If omitted, the most recent backup is used.

PROJECT="ecc-sp"
VOLUMES=("app" "db")

BACKUP_DIR="backups"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: backup directory '${BACKUP_DIR}' not found."
    exit 1
fi

TIMESTAMP="${1:-}"

# If no timestamp was given, present a menu of available backups to choose from.
if [ -z "$TIMESTAMP" ]; then
    # Collect available timestamps (one per app- archive), newest first.
    mapfile -t TIMESTAMPS < <(ls "$BACKUP_DIR" 2>/dev/null \
        | sed -n 's/^app-\(.*\)\.tar\.gz$/\1/p' \
        | sort -r)

    if [ "${#TIMESTAMPS[@]}" -eq 0 ]; then
        echo "ERROR: no backups found in '${BACKUP_DIR}'."
        echo "Expected archives like app-YYYYMMDD-HHMMSS.tar.gz"
        exit 1
    fi

    echo "Available backups:"
    for i in "${!TIMESTAMPS[@]}"; do
        ts="${TIMESTAMPS[$i]}"
        size=$(du -ch "${BACKUP_DIR}/app-${ts}.tar.gz" "${BACKUP_DIR}/db-${ts}.tar.gz" 2>/dev/null \
            | awk '/total/{print $1}')
        printf "  %2d) %s  (%s)\n" "$((i + 1))" "$ts" "${size:-?}"
    done

    read -r -p "Select a backup to restore [1-${#TIMESTAMPS[@]}, default 1]: " choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#TIMESTAMPS[@]}" ]; then
        echo "ERROR: invalid selection '${choice}'."
        exit 1
    fi
    TIMESTAMP="${TIMESTAMPS[$((choice - 1))]}"
    echo "Selected backup: ${TIMESTAMP}"
fi

# Verify every archive we are about to restore exists and is intact BEFORE we
# touch anything. A corrupt archive must be caught here, while the live volumes
# are still untouched -- otherwise we would wipe the volume and then fail to
# extract, losing the data entirely.
echo "Validating backup archives..."
for vol in "${VOLUMES[@]}"; do
    archive="${BACKUP_DIR}/${vol}-${TIMESTAMP}.tar.gz"
    if [ ! -f "$archive" ]; then
        echo "ERROR: archive not found: ${archive}"
        exit 1
    fi

    # gzip -t checks the gzip CRC; tar tz then verifies the tar stream is fully
    # readable to the end. Run both inside the same alpine image we restore with
    # so the check uses the exact tooling that will perform the extraction.
    if ! docker run --rm \
        -v "$(pwd)/${BACKUP_DIR}:/backup:ro" \
        alpine \
        sh -c 'gzip -t "/backup/'"${vol}-${TIMESTAMP}.tar.gz"'" && tar tzf "/backup/'"${vol}-${TIMESTAMP}.tar.gz"'" >/dev/null'; then
        echo "ERROR: archive is corrupt or unreadable: ${archive}"
        echo "Aborting restore; live volumes have not been modified."
        exit 1
    fi
    echo "  OK: ${archive}"
done

echo "About to restore the following archives into volumes (existing data will be REPLACED):"
for vol in "${VOLUMES[@]}"; do
    echo "  ${BACKUP_DIR}/${vol}-${TIMESTAMP}.tar.gz -> ${PROJECT}_${vol}"
done
read -r -p "Continue? [y/N] " confirm
case "$confirm" in
    [yY] | [yY][eE][sS]) ;;
    *)
        echo "Aborted."
        exit 1
        ;;
esac

echo "Stopping stack for a consistent restore..."
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
    echo "Aborting restore to avoid corrupting the volumes."
    exit 1
fi
echo "All containers stopped."

for vol in "${VOLUMES[@]}"; do
    full_name="${PROJECT}_${vol}"
    archive="${vol}-${TIMESTAMP}.tar.gz"
    echo "Restoring volume ${full_name} <- ${BACKUP_DIR}/${archive}"
    # Wipe the current contents of the volume, then extract the archive into it.
    docker run --rm \
        -v "${full_name}:/data" \
        -v "$(pwd)/${BACKUP_DIR}:/backup:ro" \
        alpine \
        sh -c 'rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf "/backup/'"${archive}"'" -C /data'
done

echo "Starting stack..."
docker compose start

echo "Done. Restored backup ${TIMESTAMP}."
