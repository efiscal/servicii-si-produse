#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Restore the named docker volumes (app + db) from ./backups tar.gz archives.
# The stack is stopped first so CockroachDB's data directory is replaced in a
# consistent state, then started again once the archives are extracted.
#
# Usage: bin/restore.sh [-d|--dir BACKUP_DIR] [TIMESTAMP]
#   -d, --dir   Directory to restore backups from. Defaults to ./backups, or the
#               BACKUP_DIR env var. May be absolute or outside the project.
#   TIMESTAMP   The backup timestamp to restore, e.g. 20260619-143000.
#               If omitted, the most recent backup is used.

# PROJECT is resolved from docker-compose.yml in _common.sh.
VOLUMES=("app" "db")

# Where to read backups from; mirror backup.sh (env var + -d/--dir override).
BACKUP_DIR="${BACKUP_DIR:-backups}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d|--dir BACKUP_DIR] [TIMESTAMP]

Restore the docker volumes (${VOLUMES[*]}) from tar.gz archives. The stack is
stopped, the volumes are replaced, then the stack is restarted. Archives are
validated before any volume is touched.

Arguments:
  TIMESTAMP       Backup to restore, e.g. 20260619-143000. If omitted, you are
                  shown a menu of available backups (newest first).

Options:
  -d, --dir DIR   Directory to restore backups from (default: ./backups, or the
                  BACKUP_DIR env var). May be absolute or outside the project.
  -h, --help      Show this help and exit.
EOF
}

TIMESTAMP=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d | --dir)
            if [ -z "${2:-}" ]; then
                echo "ERROR: $1 requires a directory argument."
                usage
                exit 1
            fi
            BACKUP_DIR="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown argument: $1"
            usage
            exit 1
            ;;
        *)
            TIMESTAMP="$1"
            shift
            ;;
    esac
done

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: backup directory '${BACKUP_DIR}' not found."
    exit 1
fi

# If no timestamp was given, present a menu of available backups to choose from.
if [ -z "$TIMESTAMP" ]; then
    # Collect available timestamps (one per backup subfolder), newest first.
    mapfile -t TIMESTAMPS < <(ls "$BACKUP_DIR" 2>/dev/null \
        | sed -n 's/^\([0-9]\{8\}-[0-9]\{6\}\)$/\1/p' \
        | sort -r)

    if [ "${#TIMESTAMPS[@]}" -eq 0 ]; then
        echo "ERROR: no backups found in '${BACKUP_DIR}'."
        echo "Expected subfolders like YYYYMMDD-HHMMSS/ containing app-*.tar.gz"
        exit 1
    fi

    echo "Available backups:"
    for i in "${!TIMESTAMPS[@]}"; do
        ts="${TIMESTAMPS[$i]}"
        size=$(du -ch "${BACKUP_DIR}/${ts}/app-${ts}.tar.gz" "${BACKUP_DIR}/${ts}/db-${ts}.tar.gz" 2>/dev/null \
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

# Each run's archives live together in their own timestamped subfolder, e.g.
# backups/20260620-081714/{app,db}-20260620-081714.tar.gz
RUN_DIR="${BACKUP_DIR}/${TIMESTAMP}"

if [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: backup subfolder not found: ${RUN_DIR}"
    exit 1
fi

# Resolve to an absolute path so docker -v works whether BACKUP_DIR was given
# as a relative or an absolute path.
RUN_DIR_ABS=$(cd "$RUN_DIR" && pwd)

# Verify every archive we are about to restore exists and is intact BEFORE we
# touch anything. A corrupt archive must be caught here, while the live volumes
# are still untouched -- otherwise we would wipe the volume and then fail to
# extract, losing the data entirely.
echo "Validating backup archives..."
for vol in "${VOLUMES[@]}"; do
    archive="${RUN_DIR}/${vol}-${TIMESTAMP}.tar.gz"
    if [ ! -f "$archive" ]; then
        echo "ERROR: archive not found: ${archive}"
        exit 1
    fi

    # gzip -t checks the gzip CRC; tar tz then verifies the tar stream is fully
    # readable to the end. Run both inside the same alpine image we restore with
    # so the check uses the exact tooling that will perform the extraction.
    if ! docker run --rm \
        -v "${RUN_DIR_ABS}:/backup:ro" \
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
    echo "  ${RUN_DIR}/${vol}-${TIMESTAMP}.tar.gz -> ${PROJECT}_${vol}"
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
    echo "Restoring volume ${full_name} <- ${RUN_DIR}/${archive}"
    # Wipe the current contents of the volume, then extract the archive into it.
    docker run --rm \
        -v "${full_name}:/data" \
        -v "${RUN_DIR_ABS}:/backup:ro" \
        alpine \
        sh -c 'rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf "/backup/'"${archive}"'" -C /data'
done

echo "Starting stack..."
docker compose start

echo "Done. Restored backup ${TIMESTAMP}."
