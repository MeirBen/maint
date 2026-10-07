#!/usr/bin/env bash
# Shared runtime for the Maintenance tools. Source from a Bash entry script.

initialize_runtime() {
    SCRIPT_DIR="$1"
    TASK_LABEL="$3"
    LOG_DIR="${SCRIPT_DIR}/logs"
    LOG_FILE="${LOG_DIR}/$2.log"
    TMP_DIR=""
    WARNING_COUNT=0
    START_TIME=$SECONDS
    COLOR_ENABLED=0
    RUNTIME_INTERRUPTED=0

    umask 077
    export LC_ALL=C
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        COLOR_ENABLED=1
    fi

    # Normal and sudo runs share the same lock. Never truncate an active log.
    mkdir -p -- "$LOG_DIR"
    exec 9>>"$LOG_FILE"
    if ! flock --wait 180 9; then
        printf 'Another %s run is still active. Please try again.\n' "$TASK_LABEL" >&2
        exec 9>&-
        return 1
    fi

    trap 'on_error "$?" "$LINENO"' ERR
    trap on_exit EXIT
    trap 'RUNTIME_INTERRUPTED=1; exit 129' HUP
    trap 'RUNTIME_INTERRUPTED=1; exit 130' INT
    trap 'RUNTIME_INTERRUPTED=1; exit 143' TERM

    # Keep files created by sudo usable by the toolkit's owner afterwards.
    if (( EUID == 0 )); then
        chown --reference="$SCRIPT_DIR" -- "$LOG_DIR" "$LOG_FILE"
    fi
    : > "$LOG_FILE"
    info "Starting ${TASK_LABEL}."
    info "Script directory: ${SCRIPT_DIR}"
    info "Log file: ${LOG_FILE}"
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
    TMP_DIR="$(mktemp -d "${LOG_DIR}/maintenance.XXXXXX")"
}

pause_before_exit() {
    if [[ "${SCRIPT_PAUSE_ON_EXIT:-0}" == 1 && -t 0 ]]; then
        echo
        read -r -p 'Press Enter to exit...' || true
    fi
}

on_error() {
    local exit_code="$1" line_number="$2"
    trap - ERR
    # A logging failure must not hide the original command's exit status.
    error "${TASK_LABEL} failed at line ${line_number}, exit code ${exit_code}." || true
    error "See the log: ${LOG_FILE}" || true
    exit "$exit_code"
}

on_exit() {
    local exit_code=$?
    trap - ERR EXIT
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        if ! rm -rf -- "$TMP_DIR"; then
            error "Could not remove temporary folder: ${TMP_DIR}" || true
            if (( exit_code == 0 )); then exit_code=1; fi
        fi
    fi
    if ! flock --unlock 9; then
        error 'Could not release the log lock.' || true
        if (( exit_code == 0 )); then exit_code=1; fi
    fi
    exec 9>&-
    # Desktop readers should not hold locks or temporary files while paused.
    if (( RUNTIME_INTERRUPTED == 0 )); then
        pause_before_exit
    fi
    exit "$exit_code"
}

show_completion_summary() {
    local duration=$((SECONDS - START_TIME)) warning_label
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
