#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Backup the named docker volumes (app + db) into ./backups as tar.gz archives.
# The stack is stopped first so CockroachDB's data directory is in a consistent
# state, then started again once the archives are written.

# PROJECT is resolved from docker-compose.yml in _common.sh.
VOLUMES=("app" "db")

# Where to write backups. Defaults to ./backups (relative to the project root),
# overridable via the BACKUP_DIR env var or the -d/--dir option. May be an
# absolute path or a path outside the project.
BACKUP_DIR="${BACKUP_DIR:-backups}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d|--dir BACKUP_DIR]

Back up the docker volumes (${VOLUMES[*]}) into a timestamped subfolder as
tar.gz archives. The stack is stopped for a consistent snapshot and restarted
afterwards. Each archive is validated after writing, and free disk space is
checked before starting.

Options:
  -d, --dir DIR   Directory to write backups into (default: ./backups, or the
                  BACKUP_DIR env var). May be absolute or outside the project.
  -h, --help      Show this help and exit.
EOF
}

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
        *)
            echo "ERROR: unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Each run's archives live together in their own timestamped subfolder, e.g.
# backups/20260620-081714/{app,db}-20260620-081714.tar.gz
RUN_DIR="${BACKUP_DIR}/${TIMESTAMP}"

# Require this much headroom over the worst-case (uncompressed) size before we
# consider the disk "definitely big enough".
SAFETY_MARGIN="1.10"

mkdir -p "$RUN_DIR"

# Resolve to an absolute path so docker -v works whether BACKUP_DIR was given
# as a relative or an absolute path.
RUN_DIR_ABS=$(cd "$RUN_DIR" && pwd)

# Format a byte count as a human-readable size (1024-based).
human() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB", u, " ");
        i = 1; while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), b, u[i]
    }'
}

# --- Pre-flight: is there enough disk space to make this backup? ------------
# Estimate the archive size and compare it against the free space on the
# filesystem that holds ./backups, so we fail fast instead of producing a
# truncated archive when the disk is full. All measurements here are read-only
# and happen BEFORE the stack is stopped, so a failure here is non-disruptive.

avail_kb=$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')
free_bytes=$((avail_kb * 1024))

# Worst case = current uncompressed volume usage (gzip can only make this
# smaller). Measured live; the mount is read-only so it is safe while running.
echo "Measuring current volume usage..."
worst_bytes=0
for vol in "${VOLUMES[@]}"; do
    full_name="${PROJECT}_${vol}"
    vol_kb=$(docker run --rm -v "${full_name}:/data:ro" alpine du -sk /data 2>/dev/null | tail -1 | awk '{print $1}')
    vol_kb=${vol_kb:-0}
    echo "  ${full_name}: $(human $((vol_kb * 1024))) uncompressed"
    worst_bytes=$((worst_bytes + vol_kb * 1024))
done

# Likely size = the most recent existing backup, if any. Real data is usually
# far smaller than the uncompressed figure once gzip'd, so this is the more
# realistic expectation when previous backups exist.
last_dir=$(ls -1d "${BACKUP_DIR}"/*/ 2>/dev/null \
    | grep -E "/[0-9]{8}-[0-9]{6}/$" \
    | grep -v "/${TIMESTAMP}/$" \
    | sort | tail -1)
likely_bytes=0
if [ -n "$last_dir" ]; then
    last_kb=$(du -sk "$last_dir" 2>/dev/null | awk '{print $1}')
    likely_bytes=$(( ${last_kb:-0} * 1024 ))
fi

required_bytes=$(awk -v w="$worst_bytes" -v m="$SAFETY_MARGIN" 'BEGIN{printf "%d", w * m}')

echo
echo "Disk space check:"
echo "  Free on $(df -P "$BACKUP_DIR" | awk 'NR==2{print $6}'): $(human "$free_bytes")"
echo "  Worst case (uncompressed):      $(human "$worst_bytes")"
if [ "$likely_bytes" -gt 0 ]; then
    echo "  Likely (last backup was):       $(human "$likely_bytes")"
else
    echo "  Likely:                         unknown (no previous backup)"
fi
echo "  Required (worst case + margin):  $(human "$required_bytes")"

if [ "$free_bytes" -ge "$required_bytes" ]; then
    echo "  -> Enough space. Proceeding."
elif [ "$likely_bytes" -gt 0 ] && [ "$free_bytes" -ge $((likely_bytes * 3 / 2)) ]; then
    echo "  -> WARNING: not enough for the uncompressed worst case, but free space"
    echo "     comfortably exceeds the last backup. Compression should fit; the"
    echo "     post-backup validation below will catch a truncated archive."
else
    echo "  -> ERROR: not enough free disk space to safely make this backup."
    echo "     Free up space (e.g. delete old backups under ${BACKUP_DIR}/) and retry."
    echo "     The stack was NOT stopped."
    exit 1
fi
echo

# If we error out after stopping the stack (disk fills mid-write, validation
# fails, etc.), make a best effort to bring it back up rather than leaving the
# service down.
STACK_STOPPED=0
restart_on_failure() {
    if [ "$STACK_STOPPED" = "1" ]; then
        echo "An error occurred after the stack was stopped; attempting to restart it..."
        docker compose start || true
    fi
}
trap restart_on_failure EXIT

echo "Stopping stack for a consistent snapshot..."
docker compose stop
STACK_STOPPED=1

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
    echo "Backing up volume ${full_name} -> ${RUN_DIR}/${archive}"
    docker run --rm \
        -v "${full_name}:/data:ro" \
        -v "${RUN_DIR_ABS}:/backup" \
        alpine \
        tar czf "/backup/${archive}" -C /data .

    # Validate the freshly written archive (gzip CRC + a full tar read) using
    # the same image, so a truncated or corrupt file -- e.g. from a disk that
    # filled up mid-write -- is caught now rather than at restore time.
    echo "Validating ${archive}..."
    if ! docker run --rm \
        -v "${RUN_DIR_ABS}:/backup:ro" \
        alpine \
        sh -c 'gzip -t "/backup/'"${archive}"'" && tar tzf "/backup/'"${archive}"'" >/dev/null'; then
        echo "ERROR: archive failed validation: ${RUN_DIR}/${archive}"
        echo "The bad backup is left in place for inspection."
        exit 1
    fi
    echo "  OK: ${archive}"
done

echo "Starting stack..."
docker compose start
STACK_STOPPED=0

echo "Done. Archives written to ${RUN_DIR}/"
ls -lh "$RUN_DIR"
