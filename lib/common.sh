#!/usr/bin/env bash
# Shared runtime for maint actions: daily logs, locking, privileges, prompts, cleanup.

MAINT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Settings.
LOG_RETENTION_DAYS=90    # Daily logs kept per module, today included.
LOCK_WAIT_SECONDS=180    # How long a run waits for another run of the same module.

# Starts an action run: takes the per-tool lock, opens today's log, installs traps.
initialize_runtime() {
    local tool="$1" run_day lock_file
    TASK_LABEL="$2"
    LOG_DIR="${MAINT_ROOT}/logs"
    LOG_FILE="${LOG_DIR}/${tool}.log"
    TMP_DIR=""
    WARNING_COUNT=0
    START_TIME=$SECONDS
    COLOR_ENABLED=0
    INTERRUPTED_BY=""
    SUMMARY_SHOWN=0

    umask 077
    export LC_ALL=C
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        COLOR_ENABLED=1
    fi
    run_day="$(date +%F)"

    # Lock a stable file: the current-log link changes when the day changes.
    mkdir -p -- "$LOG_DIR"
    lock_file="${LOG_DIR}/.${tool}.lock"
    exec {LOCK_FD}>>"$lock_file"
    if (( EUID == 0 )); then
        chown --reference="$MAINT_ROOT" -- "$LOG_DIR" "$lock_file"
    fi
    # Report the wait on the terminal only: the other run is still writing the log.
    if ! flock --nonblock "$LOCK_FD"; then
        printf 'Waiting up to %s seconds for another %s run to finish...\n' \
            "$LOCK_WAIT_SECONDS" "$TASK_LABEL" >&2
        if ! flock --wait "$LOCK_WAIT_SECONDS" "$LOCK_FD"; then
            printf 'Another %s run is still active. Please try again.\n' "$TASK_LABEL" >&2
            return 1
        fi
    fi

    trap 'on_error "$?" "$LINENO"' ERR
    trap on_exit EXIT
    trap 'INTERRUPTED_BY=SIGHUP; exit 129' HUP
    trap 'INTERRUPTED_BY=SIGINT; exit 130' INT
    trap 'INTERRUPTED_BY=SIGTERM; exit 143' TERM

    prepare_daily_log "$tool" "$run_day"
    info "===== ${TASK_LABEL} | user $(id -un) | pid $$ ====="
    info "Log file: ${LOG_FILE}"
}

prepare_daily_log() {
    local tool="$1" day="$2" history_dir="${LOG_DIR}/$1" cutoff daily_log path name
    # Calendar days counted from noon, independent of DST changes.
    cutoff="$(date --date="${day} 12:00:00 $((LOG_RETENTION_DAYS - 1)) days ago" +%F)"
    daily_log="${history_dir}/${day}.log"
    mkdir -p -- "$history_dir"
    : >> "$daily_log"
    if (( EUID == 0 )); then
        chown --reference="$MAINT_ROOT" -- "$history_dir" "$daily_log"
    fi
    ln -sfnT -- "${tool}/${day}.log" "$LOG_FILE"

    # Only this tool's regular dated logs are eligible for retention cleanup.
    for path in "$history_dir"/*.log; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        name="${path##*/}"
        if [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$ && "${name%.log}" < "$cutoff" ]]; then
            rm -- "$path"
        fi
    done
}

log() {
    local level="$1"
    shift
    local line color="" reset=""
    printf -v line '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s' -1 "$level" "$*"

    if (( COLOR_ENABLED )); then
        case "$level" in
            INFO) color=$'\033[0;34m' ;;
            OK) color=$'\033[0;32m' ;;
            WARN|NOTE|SUMMARY) color=$'\033[1;33m' ;;
            ERROR) color=$'\033[0;31m' ;;
        esac
        reset=$'\033[0m'
    fi
    printf '%s%s%s\n' "$color" "$line" "$reset"
    printf '%s\n' "$line" >> "$LOG_FILE"
}

info() { log INFO "$*"; }
success() { log OK "$*"; }
error() { log ERROR "$*"; }

warn_condition() {
    WARNING_COUNT=$((WARNING_COUNT + 1))
    log WARN "$*"
}

warn_note() { log NOTE "$*"; }

print_and_log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

run() {
    info "Running: $(printf '%q ' "$@")"
    "$@" 2>&1 | tee -a "$LOG_FILE"
}

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

run_root() {
    if (( EUID == 0 )); then
        run "$@"
    else
        run sudo "$@"
    fi
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            error "Required command is missing: ${command_name}"
            return 1
        fi
    done
    success 'Required commands are available.'
}

require_sudo() {
    if (( EUID == 0 )); then
        success 'Administrator access is already available.'
        return 0
    fi
    info 'Checking sudo access...'
    sudo -v
    success 'Sudo access confirmed.'
}

confirm() {
    local prompt="$1" answer=""
    [[ -t 0 ]] || return 1
    read -r -p "${prompt} [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

confirm_phrase() {
    local prompt="$1" expected="$2" answer=""
    [[ -t 0 ]] || return 1
    read -r -p "${prompt} Type ${expected} to continue: " answer || return 1
    [[ "$answer" == "$expected" ]]
}

create_temp_dir() {
    TMP_DIR="$(mktemp -d "${LOG_DIR}/maint.XXXXXX")"
}

# Logs the failing call chain, e.g. "action_update (system.sh:33) > run (common.sh:113)".
on_error() {
    local status="$1" line="$2" frame last=$(( ${#FUNCNAME[@]} - 1 )) trace=""
    trap - ERR
    # Frame 0 is on_error itself; the last frame is the script body, shown only when it failed there.
    if (( last > 1 )); then last=$(( last - 1 )); fi
    for (( frame = 1; frame <= last; frame++ )); do
        if (( frame > 1 )); then line="${BASH_LINENO[frame - 1]}"; fi
        trace="${FUNCNAME[frame]} (${BASH_SOURCE[frame]##*/}:${line})${trace:+ > ${trace}}"
    done
    # A logging failure must not hide the original command's exit status.
    error "${TASK_LABEL} failed with exit code ${status} at: ${trace}" || true
    error "See the log: ${LOG_FILE}" || true
    exit "$status"
}

on_exit() {
    local status=$?
    trap - ERR EXIT
    # Finish cleanup even if another signal arrives.
    trap '' HUP INT TERM
    if [[ -n "$INTERRUPTED_BY" ]]; then
        error "${TASK_LABEL} was interrupted (${INTERRUPTED_BY}). See the log: ${LOG_FILE}" || true
    fi
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && ! rm -rf -- "$TMP_DIR"; then
        error "Could not remove temporary folder: ${TMP_DIR}" || true
        if (( status == 0 )); then status=1; fi
    fi
    exit "$status"
}

# Logs the warning count and duration once per run. The runner calls it after each successful
# action, so an action calls it only to log the summary earlier.
show_completion_summary() {
    local duration=$((SECONDS - START_TIME)) warning_label
    if (( SUMMARY_SHOWN )); then
        return 0
    fi
    SUMMARY_SHOWN=1
    if (( WARNING_COUNT == 0 )); then
        success "${TASK_LABEL} completed successfully with no warning conditions."
    else
        warning_label="${WARNING_COUNT} warning conditions"
        if (( WARNING_COUNT == 1 )); then warning_label='1 warning condition'; fi
        log SUMMARY "${TASK_LABEL} completed with ${warning_label}. Review the WARN/NOTE lines above."
    fi
    info "Total duration: ${duration} seconds"
    info "Log file: ${LOG_FILE}"
}
