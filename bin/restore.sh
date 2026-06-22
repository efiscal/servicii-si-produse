#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Restore selected parts of a backup: the docker volumes (app + db) and/or the
# captured configuration (docker-compose.yml, .env, docker/ env files).
#
# Restore is interactive and opt-in per item: you are asked about each piece
# separately and the default for every restore item is NO -- you must press 'y'.
# Before any of that you are offered a backup of the CURRENT state (default YES)
# so a wrong choice can be undone.
#
# Usage: bin/restore.sh [-d|--dir BACKUP_DIR] [TIMESTAMP]
#   -d, --dir   Directory to restore backups from. Defaults to ./backups, or the
#               BACKUP_DIR env var. May be absolute or outside the project.
#   TIMESTAMP   The backup timestamp to restore, e.g. 20260619-143000.
#               If omitted, you are shown a menu of available backups.

# PROJECT is resolved from docker-compose.yml in _common.sh. Note it reflects
# the CURRENT compose file, so volumes are restored into the currently running
# project's volumes -- which is why volumes are restored BEFORE any compose/env
# file is swapped in below.
VOLUMES=("app" "db")

# Where to read backups from; mirror backup.sh (env var + -d/--dir override).
BACKUP_DIR="${BACKUP_DIR:-backups}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d|--dir BACKUP_DIR] [TIMESTAMP]

Restore selected parts of a backup. You are asked, per item, whether to restore
each docker volume (${VOLUMES[*]}) and each captured config file
(docker-compose.yml, .env, docker/). The default for every item is NO. Selected
volume archives are validated before anything is touched, and existing config
files are saved aside as <file>.bak-<timestamp> before being overwritten.

Arguments:
  TIMESTAMP       Backup to restore, e.g. 20260619-143000. If omitted, you are
                  shown a menu of available backups (newest first).

Options:
  -d, --dir DIR   Directory to restore backups from (default: ./backups, or the
                  BACKUP_DIR env var). May be absolute or outside the project.
  -h, --help      Show this help and exit.
EOF
}

# Ask a yes/no question that DEFAULTS TO NO. Returns 0 only on an explicit yes.
confirm_no() {
    local reply
    read -r -p "$1 [y/N] " reply
    case "$reply" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Save an existing file/dir aside before it is overwritten, so a restore of the
# config can itself be undone.
save_aside() {
    local path="$1"
    if [ -e "$path" ]; then
        local bak="${path}.bak-${TIMESTAMP}"
        rm -rf "$bak"
        cp -a "$path" "$bak"
        echo "  saved current ${path} -> ${bak}"
    fi
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
CONFIG_DIR="${RUN_DIR}/config"

if [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: backup subfolder not found: ${RUN_DIR}"
    exit 1
fi

# Resolve to an absolute path so docker -v works whether BACKUP_DIR was given
# as a relative or an absolute path.
RUN_DIR_ABS=$(cd "$RUN_DIR" && pwd)

# --- Offer a safety backup of the CURRENT state first (default YES) ----------
# A restore is destructive, so by default we snapshot the current state before
# changing anything. Press 'n' to skip.
read -r -p "Take a backup of the CURRENT state before restoring? [Y/n] " do_backup
case "${do_backup:-Y}" in
    [nN] | [nN][oO])
        echo "Skipping pre-restore backup."
        ;;
    *)
        echo "Running pre-restore backup..."
        if "$(dirname "${BASH_SOURCE[0]}")/backup.sh"; then
            echo "Pre-restore backup complete."
        else
            echo "WARNING: pre-restore backup did not complete cleanly."
            if ! confirm_no "Continue with the restore anyway?"; then
                echo "Aborted."
                exit 1
            fi
        fi
        ;;
esac

# --- Choose what to restore (every item defaults to NO) ---------------------
echo
echo "Select what to restore from backup ${TIMESTAMP} (default for each is NO):"

RESTORE_VOLS=()
for vol in "${VOLUMES[@]}"; do
    archive="${RUN_DIR}/${vol}-${TIMESTAMP}.tar.gz"
    if [ ! -f "$archive" ]; then
        echo "  - '${vol}' volume: no archive in this backup -- skipping"
        continue
    fi
    if confirm_no "  Restore '${vol}' volume? REPLACES all data in ${PROJECT}_${vol}"; then
        RESTORE_VOLS+=("$vol")
    fi
done

RESTORE_COMPOSE=0
RESTORE_ENV=0
RESTORE_DOCKER=0
if [ -f "${CONFIG_DIR}/docker-compose.yml" ] && confirm_no "  Restore docker-compose.yml? Overwrites ./docker-compose.yml"; then
    RESTORE_COMPOSE=1
fi
if [ -f "${CONFIG_DIR}/.env" ] && confirm_no "  Restore .env? Overwrites ./.env"; then
    RESTORE_ENV=1
fi
if [ -d "${CONFIG_DIR}/docker" ] && confirm_no "  Restore docker/ env files? Overwrites ./docker"; then
    RESTORE_DOCKER=1
fi

nvols=${#RESTORE_VOLS[@]}
if [ "$nvols" -eq 0 ] && [ "$RESTORE_COMPOSE" -eq 0 ] && [ "$RESTORE_ENV" -eq 0 ] && [ "$RESTORE_DOCKER" -eq 0 ]; then
    echo "Nothing selected to restore. Exiting."
    exit 0
fi

# Verify every selected volume archive exists and is intact BEFORE we touch
# anything. A corrupt archive must be caught here, while the live volumes are
# still untouched -- otherwise we would wipe the volume and then fail to
# extract, losing the data entirely.
if [ "$nvols" -gt 0 ]; then
    echo "Validating selected volume archives..."
    for vol in "${RESTORE_VOLS[@]}"; do
        archive="${RUN_DIR}/${vol}-${TIMESTAMP}.tar.gz"
        # gzip -t checks the gzip CRC; tar tz then verifies the tar stream is
        # fully readable. Run both inside the same alpine image we restore with.
        if ! docker run --rm \
            -v "${RUN_DIR_ABS}:/backup:ro" \
            alpine \
            sh -c 'gzip -t "/backup/'"${vol}-${TIMESTAMP}.tar.gz"'" && tar tzf "/backup/'"${vol}-${TIMESTAMP}.tar.gz"'" >/dev/null'; then
            echo "ERROR: archive is corrupt or unreadable: ${archive}"
            echo "Aborting restore; nothing has been modified."
            exit 1
        fi
        echo "  OK: ${archive}"
    done
fi

# --- Restore volumes first (uses the CURRENT compose file/project) -----------
if [ "$nvols" -gt 0 ]; then
    echo "Stopping stack for a consistent restore..."
    docker compose stop

    # Make sure nothing is still running/restarting before we touch the volumes.
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

    for vol in "${RESTORE_VOLS[@]}"; do
        full_name="${PROJECT}_${vol}"
        archive="${vol}-${TIMESTAMP}.tar.gz"
        echo "Restoring volume ${full_name} <- ${RUN_DIR}/${archive}"
        # Wipe the current contents of the volume, then extract the archive.
        docker run --rm \
            -v "${full_name}:/data" \
            -v "${RUN_DIR_ABS}:/backup:ro" \
            alpine \
            sh -c 'rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf "/backup/'"${archive}"'" -C /data'
    done

    echo "Starting stack..."
    docker compose start
fi

# --- Restore config files (after volumes, so the stop/start above used the
#     current, consistent compose file) ---------------------------------------
if [ "$RESTORE_COMPOSE" -eq 1 ]; then
    save_aside docker-compose.yml
    cp "${CONFIG_DIR}/docker-compose.yml" docker-compose.yml
    echo "Restored docker-compose.yml"
fi
if [ "$RESTORE_ENV" -eq 1 ]; then
    save_aside .env
    cp "${CONFIG_DIR}/.env" .env
    echo "Restored .env"
fi
if [ "$RESTORE_DOCKER" -eq 1 ]; then
    save_aside docker
    rm -rf docker
    cp -a "${CONFIG_DIR}/docker" docker
    echo "Restored docker/"
fi

if [ "$RESTORE_COMPOSE" -eq 1 ] || [ "$RESTORE_ENV" -eq 1 ] || [ "$RESTORE_DOCKER" -eq 1 ]; then
    echo
    echo "NOTE: configuration files were restored, but the running containers still"
    echo "use the previous config. Run 'docker compose up -d' to apply the restored"
    echo "compose file / env (this may recreate containers with different versions)."
fi

echo "Done. Restored backup ${TIMESTAMP}."
