#!/bin/bash
# cleanup-shm.sh — Remove orphaned files from /dev/shm (run as root via cron)
#
# A file is orphaned if no process holds it open (fd or mmap) and it is
# older than MIN_AGE_MINUTES. POSIX semaphores (sem.*) get extra checking:
# if the owning UID has no running processes, the semaphore is orphaned.
#
# Exit codes: 0=clean, 1=fatal/errors, 2=clean but /dev/shm usage is high
#
# Usage: cleanup-shm.sh [--dry-run] [--min-age MINUTES] [--verbose]
#                        [--unlinker PATH] [-h|--help]
#
# Environment:
#   SHM_CLEANUP_MIN_AGE   Default --min-age value (minutes)
#   SHM_UNLINK_BIN        Default --unlinker path

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -uo pipefail
umask 077

# ── Configuration ────────────────────────────────────────────────────
MIN_AGE_MINUTES="${SHM_CLEANUP_MIN_AGE:-60}"
DRY_RUN=0
VERBOSE=0
LOG_TAG="cleanup-shm"
SHM_USAGE_WARN_PCT=90
EXIT_CODE=0
UNLINKER_ARG=""

# ── Argument parsing ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --verbose)  VERBOSE=1; shift ;;
        --min-age)
            [[ $# -lt 2 ]] && { echo "Error: --min-age requires an argument" >&2; exit 1; }
            MIN_AGE_MINUTES="$2"; shift 2 ;;
        --unlinker)
            [[ $# -lt 2 ]] && { echo "Error: --unlinker requires an argument" >&2; exit 1; }
            UNLINKER_ARG="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--min-age MINUTES] [--verbose] [--unlinker PATH]"
            exit 0 ;;
        *)  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if ! [[ "$MIN_AGE_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: MIN_AGE_MINUTES must be a positive integer (got: '${MIN_AGE_MINUTES}')" >&2
    exit 1
fi

# ── Resolve /dev/shm ────────────────────────────────────────────────
SHM_CANONICAL="$(realpath -e /dev/shm 2>/dev/null)" || true
if [[ -z "$SHM_CANONICAL" ]]; then
    logger -t "$LOG_TAG" -p user.err "/dev/shm does not exist or cannot be resolved"
    exit 1
fi
readonly SHM_CANONICAL

# ── Logging ──────────────────────────────────────────────────────────
log_info() {
    logger -t "$LOG_TAG" -p user.info "$*"
    if [[ "$VERBOSE" -eq 1 ]]; then echo "[INFO]  $*"; fi
}
log_warn() {
    logger -t "$LOG_TAG" -p user.warning "$*"
    echo "[WARN]  $*" >&2
}
log_err() {
    logger -t "$LOG_TAG" -p user.err "$*"
    echo "[ERROR] $*" >&2
}

# ── Concurrency lock ────────────────────────────────────────────────
LOCKFILE="/var/run/cleanup-shm.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log_warn "Another instance is running; exiting"
    exit 0
fi

# ── Detect shm-unlink helper ────────────────────────────────────────
# Resolution: --unlinker flag > SHM_UNLINK_BIN env > PATH + /usr/local/sbin
USE_HELPER=0
SHM_UNLINK=""

detect_unlinker() {
    local candidate=""

    if [[ -n "$UNLINKER_ARG" ]]; then
        candidate="$UNLINKER_ARG"
    elif [[ -n "${SHM_UNLINK_BIN:-}" ]]; then
        candidate="$SHM_UNLINK_BIN"
    else
        candidate="$(command -v shm-unlink 2>/dev/null)" || true
        [[ -z "$candidate" && -x /usr/local/sbin/shm-unlink ]] && candidate="/usr/local/sbin/shm-unlink"
    fi

    [[ -z "$candidate" ]] && return 1

    if [[ ! -f "$candidate" ]]; then
        log_warn "shm-unlink helper not found at '${candidate}'"; return 1
    fi
    if [[ ! -x "$candidate" ]]; then
        log_warn "shm-unlink helper at '${candidate}' is not executable"; return 1
    fi

    SHM_UNLINK="$candidate"
    USE_HELPER=1
}

detect_unlinker

if [[ -n "$UNLINKER_ARG" && "$USE_HELPER" -eq 0 ]]; then
    log_err "Specified --unlinker '${UNLINKER_ARG}' is not usable"
    exit 1
fi

# ── Path safety check ───────────────────────────────────────────────
is_under_shm() {
    local canonical
    canonical="$(realpath -e -- "$1" 2>/dev/null)" || return 1
    [[ "$canonical" == "${SHM_CANONICAL}/"* ]]
}

is_owned_by_root() {
    [[ "$(stat -c '%u' -- "$1" 2>/dev/null)" == "0" ]]
}

# ── Open file tracking ──────────────────────────────────────────────
# Scan /proc to build an O(1) lookup of files held open by any process.
declare -A OPEN_FILES

populate_open_files() {
    local target
    local pattern
    for pattern in '/proc/[0-9]*/fd/*' '/proc/[0-9]*/map_files/*'; do
        while IFS= read -r -d '' link; do
            target="$(readlink -f "$link" 2>/dev/null)" || continue
            [[ "$target" == "${SHM_CANONICAL}/"* ]] && OPEN_FILES["$target"]=1
        done < <(find /proc -maxdepth 3 -path "$pattern" -print0 \
                    2> >(logger -t "$LOG_TAG" -p user.info))
    done
}

# ── Deletion backends ───────────────────────────────────────────────

# Bash backend: re-resolves canonical path right before deletion to minimize
# the TOCTOU window (cannot fully eliminate it without kernel support).
safe_remove_bash() {
    local filepath="$1"

    if [[ -L "$filepath" ]]; then
        local canonical_parent
        canonical_parent="$(realpath -e -- "$(dirname -- "$filepath")" 2>/dev/null)" || return 1
        [[ "$canonical_parent" == "${SHM_CANONICAL}" || "$canonical_parent" == "${SHM_CANONICAL}/"* ]] || return 1
        rm -f -- "$filepath" 2>&1
        return $?
    fi

    local canonical
    canonical="$(realpath -e -- "$filepath" 2>/dev/null)" || return 1
    [[ "$canonical" == "${SHM_CANONICAL}/"* ]] || return 1
    rm -f -- "$canonical" 2>&1
}

# Helper backend: TOCTOU-safe via openat2/O_PATH + unlinkat in the C helper.
safe_remove_helper() {
    local filepath="$1"
    local -a args=("--root" "$SHM_CANONICAL")
    [[ "$DRY_RUN" -eq 1 ]] && args+=("--dry-run")
    "$SHM_UNLINK" "${args[@]}" "$filepath" 2>&1
}

safe_remove() {
    if [[ "$USE_HELPER" -eq 1 ]]; then
        safe_remove_helper "$1"
    else
        safe_remove_bash "$1"
    fi
}

# ── Unified remove-or-log wrapper ───────────────────────────────────
# Handles dry-run logic and counters in one place.
removed=0 skipped=0 errors=0

try_remove() {
    local filepath="$1"
    local label="${2:-}"  # optional label like "symlink" or "orphaned semaphore"
    local desc="${label:+${label}: }${filepath}"

    if [[ "$DRY_RUN" -eq 1 && "$USE_HELPER" -eq 0 ]]; then
        log_info "[DRY RUN] Would remove ${desc}"
        return
    fi

    local rm_err
    if rm_err="$(safe_remove "$filepath")"; then
        log_info "Removed ${desc}"
        ((removed++))
    else
        log_warn "Failed to remove ${desc}: ${rm_err}"
        ((errors++))
    fi
}

# ── Semaphore orphan detection ──────────────────────────────────────
# A sem.* file is orphaned if no process has it open AND the owning UID
# has no running processes at all.
is_semaphore_orphaned() {
    local filepath="$1"
    [[ "$(basename -- "$filepath")" == sem.* ]] || return 1

    local canonical
    canonical="$(realpath -e -- "$filepath" 2>/dev/null)" || return 0
    [[ -z "${OPEN_FILES[$canonical]+_}" ]] || return 1

    local file_uid
    file_uid="$(stat -c '%u' -- "$filepath" 2>/dev/null)" || return 0
    if [[ -n "$file_uid" ]] && ! find /proc -maxdepth 1 -uid "$file_uid" -name '[0-9]*' -print -quit 2>/dev/null | grep -q .; then
        return 0  # owner has no running processes
    fi
    return 1
}

# ── Helpers for find piping ──────────────────────────────────────────
# Redirect find stderr to syslog so permission errors don't spam the console.
find_shm() {
    find -P "${SHM_CANONICAL}" "$@" -print0 2> >(logger -t "$LOG_TAG" -p user.warning)
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_err "Must run as root"
        exit 1
    fi

    local backend_desc
    if [[ "$USE_HELPER" -eq 1 ]]; then
        backend_desc="shm-unlink (${SHM_UNLINK})"
    else
        backend_desc="bash (TOCTOU-minimized)"
    fi
    log_info "Starting cleanup (min_age=${MIN_AGE_MINUTES}m, dry_run=${DRY_RUN}, backend=${backend_desc})"

    populate_open_files
    log_info "Found ${#OPEN_FILES[@]} open file(s) in ${SHM_CANONICAL}"

    local canonical

    # 1) Regular files (excluding sem.* — handled separately)
    while IFS= read -r -d '' filepath; do
        if ! is_under_shm "$filepath"; then
            log_warn "Skipping unsafe path: ${filepath}"; ((skipped++)); continue
        fi
        if is_owned_by_root "$filepath"; then
            if [[ "$VERBOSE" -eq 1 ]]; then log_info "Owned by root, skipping: ${filepath}"; fi
            ((skipped++)); continue
        fi
        canonical="$(realpath -e -- "$filepath" 2>/dev/null)" || continue
        if [[ -n "${OPEN_FILES[$canonical]+_}" ]]; then
            if [[ "$VERBOSE" -eq 1 ]]; then log_info "In use, skipping: ${filepath}"; fi
            ((skipped++)); continue
        fi
        try_remove "$filepath"
    done < <(find_shm -mindepth 1 -not -type d -not -type l -not -name 'sem.*' \
                -mmin "+${MIN_AGE_MINUTES}")

    # 2) Symlinks (dangling or pointing outside /dev/shm)
    local link_target canonical_parent
    while IFS= read -r -d '' link; do
        canonical_parent="$(realpath -e -- "$(dirname -- "$link")" 2>/dev/null)" || continue
        if [[ "$canonical_parent" != "${SHM_CANONICAL}" && "$canonical_parent" != "${SHM_CANONICAL}/"* ]]; then
            log_warn "Skipping symlink with unsafe parent: ${link}"; ((skipped++)); continue
        fi
        if is_owned_by_root "$link"; then
            if [[ "$VERBOSE" -eq 1 ]]; then log_info "Owned by root, skipping: ${link}"; fi
            ((skipped++)); continue
        fi
        link_target="$(realpath -e -- "$link" 2>/dev/null)" || true
        if [[ -n "$link_target" && -n "${OPEN_FILES[$link_target]+_}" ]]; then
            if [[ "$VERBOSE" -eq 1 ]]; then log_info "Symlink target in use, skipping: ${link}"; fi
            ((skipped++)); continue
        fi
        try_remove "$link" "symlink"
    done < <(find_shm -mindepth 1 -type l -mmin "+${MIN_AGE_MINUTES}")

    # 3) POSIX semaphores with no open fds and dead owner
    while IFS= read -r -d '' semfile; do
        is_under_shm "$semfile" || continue
        is_owned_by_root "$semfile" && continue
        is_semaphore_orphaned "$semfile" && try_remove "$semfile" "orphaned semaphore"
    done < <(find_shm -mindepth 1 -maxdepth 1 -name 'sem.*' -type f \
                -mmin "+${MIN_AGE_MINUTES}")

    # 4) Empty directories (bottom-up; rmdir is inherently race-safe)
    while IFS= read -r -d '' dirpath; do
        if ! is_under_shm "$dirpath"; then
            log_warn "Skipping unsafe directory: ${dirpath}"; continue
        fi
        if is_owned_by_root "$dirpath"; then
            if [[ "$VERBOSE" -eq 1 ]]; then log_info "Owned by root, skipping: ${dirpath}"; fi
            continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "[DRY RUN] Would remove empty dir: ${dirpath}"
        else
            rmdir -- "$dirpath" 2>/dev/null && { log_info "Removed empty dir: ${dirpath}"; ((removed++)); }
        fi
    done < <(find_shm -mindepth 1 -type d -empty -mmin "+${MIN_AGE_MINUTES}" -depth)

    # 5) Disk usage warning
    local usage_pct
    usage_pct="$(df --output=pcent /dev/shm 2>/dev/null | tail -1 | tr -d '% ')" || true
    if [[ -n "$usage_pct" ]] && (( usage_pct > SHM_USAGE_WARN_PCT )); then
        log_warn "/dev/shm is ${usage_pct}% full; unlinked-but-open files may be consuming space"
        EXIT_CODE=2
    fi

    log_info "Finished: removed=${removed} skipped=${skipped} errors=${errors} backend=${backend_desc}"
    if (( errors > 0 && EXIT_CODE == 0 )); then
        EXIT_CODE=1
    fi
}

main
exit "$EXIT_CODE"
