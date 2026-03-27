#!/usr/bin/env bash
#
# Handles:
# - Scans /dev/shm recursively, including subdirectories.
# - Processes only regular files (-type f).
# - Skips POSIX named semaphore files named sem.* anywhere in the tree.
# - Detects files currently open by a process via lsof.
# - Detects files currently memory-mapped via /proc/*/maps.
# - Uses a quarantine directory inside /dev/shm.
# - Processes quarantine first; files still unused there are deleted.
# - Uses the time between cron runs as the grace period.
# - Preserves relative paths in quarantine to avoid basename collisions.
# - Uses a non-blocking flock lock to prevent overlapping cron runs.
# - Supports dry-run mode via DRY_RUN=1 (default) and live mode via DRY_RUN=0.
#
# Does not handle:
# - Deleted-but-still-open files that no longer have a pathname.
# - Perfectly race-free "unused then delete" semantics; TOCTOU still exists.
# - Automatic restoration of quarantined files if an application later expects the old pathname.
# - Symlink cleanup or verification.
# - Special handling for hard-linked files beyond treating them as regular files if found by path.
# - Non-file shm objects with no visible pathname.
# - Cross-filesystem quarantine moves (quarantine must stay on the same filesystem).
#
set -u
set -o pipefail

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
umask 077
LC_ALL=C
export PATH LC_ALL

SHM_DIR="${1:-/dev/shm}"
AGE_DAYS="${2:-2}"
DRY_RUN="${DRY_RUN:-1}"
LOCK_FILE="${LOCK_FILE:-/var/run/shm_cleanup.lock}"
LOG_TS="${LOG_TS:-1}"
QUAR_NAME="${QUAR_NAME:-.quarantine}"
QUAR_DIR="$SHM_DIR/$QUAR_NAME"

log() {
    local tag="$1"
    shift
    if [[ "$LOG_TS" == "1" ]]; then
        printf '%s %-14s %s\n' "$(date '+%F %T')" "$tag" "$*"
    else
        printf '%-14s %s\n' "$tag" "$*"
    fi
}

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN" "$*"
    else
        "$@"
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "ERROR" "required command not found: $1"
        exit 1
    }
}

is_open() {
    local f="$1"
    lsof -t -- "$f" >/dev/null 2>&1
}

is_mapped() {
    local f="$1"
    awk -v target="$f" '$NF == target { found=1; exit } END { exit !found }' /proc/*/maps 2>/dev/null
}

is_semaphore() {
    local f="$1"
    [[ "$(basename -- "$f")" == sem.* ]]
}

is_in_use() {
    local f="$1"
    is_open "$f" || is_mapped "$f"
}

relative_path() {
    local f="$1"
    printf '%s\n' "${f#"$SHM_DIR"/}"
}

quarantine_target() {
    local f="$1"
    local rel dir base target
    rel="$(relative_path "$f")"
    dir="$(dirname -- "$rel")"
    base="$(basename -- "$rel")"
    target="$QUAR_DIR/$dir/$base"

    if [[ -e "$target" ]]; then
        target="$QUAR_DIR/$dir/${base}.$(date +%s).$$"
    fi

    printf '%s\n' "$target"
}

need_cmd find
need_cmd awk
need_cmd lsof
need_cmd mv
need_cmd rm
need_cmd mkdir
need_cmd dirname
need_cmd basename
need_cmd flock
need_cmd date

if [[ ! -d "$SHM_DIR" ]]; then
    log "ERROR" "directory does not exist: $SHM_DIR"
    exit 1
fi

mkdir -p -- "$QUAR_DIR" || {
    log "ERROR" "failed to create quarantine directory: $QUAR_DIR"
    exit 1
}

exec 9>"$LOCK_FILE" || {
    log "ERROR" "cannot open lock file: $LOCK_FILE"
    exit 1
}

if ! flock -n 9; then
    log "LOCKED" "another instance is already running"
    exit 0
fi

log "START" "SHM_DIR=$SHM_DIR AGE_DAYS=$AGE_DAYS DRY_RUN=$DRY_RUN"

log "PHASE" "processing quarantine"

find "$QUAR_DIR" -xdev -type f -print0 2>/dev/null |
while IFS= read -r -d '' file; do
    if is_semaphore "$file"; then
        log "SKIP-SEM" "$file"
        continue
    fi

    if is_in_use "$file"; then
        log "KEEP-IN-USE" "$file"
        continue
    fi

    log "DELETE" "$file"
    run rm -f -- "$file"
done

log "PHASE" "scanning active tree"

find "$SHM_DIR" -xdev -type f -mtime +"$AGE_DAYS" ! -path "$QUAR_DIR/*" -print0 2>/dev/null |
while IFS= read -r -d '' file; do
    if is_semaphore "$file"; then
        log "SKIP-SEM" "$file"
        continue
    fi

    if is_in_use "$file"; then
        if is_open "$file"; then
            log "SKIP-OPEN" "$file"
        else
            log "SKIP-MMAP" "$file"
        fi
        continue
    fi

    target="$(quarantine_target "$file")"
    run mkdir -p -- "$(dirname -- "$target")"

    log "QUARANTINE" "$file -> $target"
    run mv -- "$file" "$target"
done

log "DONE" "completed"
exit 0
