#!/usr/bin/env bash
set -Eeuo pipefail

# Desktop controls for the local browser chat.
# Keep one overwritten log: <script-folder>/logs/local-ai.log
if [[ $# -eq 0 ]]; then
    echo 'Local AI — Open WebUI + Ollama'
    echo
    echo '1) Start and open chat'
    echo '2) Stop'
    echo '3) Update / upgrade'
    echo '4) Exit'
    echo
    while true; do
        read -r -p 'Choose [1-4]: ' choice || exit 0
        case "$choice" in
            1) set -- start; break ;;
            2) set -- stop; break ;;
            3) set -- update; break ;;
            4) exit 0 ;;
            *) echo 'Please choose 1, 2, 3, or 4.' ;;
        esac
    done
fi
if [[ $# -ne 1 || ( "$1" != start && "$1" != stop && "$1" != update ) ]]; then
    echo 'Usage: local-ai.sh start|stop|update' >&2
    exit 2
fi

ACTION="$1"

# sudo already authenticated. Keep root out of the user's desktop session/logs.
if (( EUID == 0 )); then
    /usr/local/sbin/local-ai-service-control "$ACTION"
    if [[ "$ACTION" == start ]]; then
        echo 'Local AI is ready. Open http://127.0.0.1:8080 in your browser.'
    fi
    exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/local-ai.log"

# Keep repeated clicks from overwriting a log while its action is still running.
exec 9>"${XDG_RUNTIME_DIR:-/run/user/$UID}/local-ai-control.lock"
if ! flock --wait 180 9; then
    echo 'Another Local AI control is still running. Please try again.' >&2
    exit 1
fi
mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

log() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

pause_before_exit() {
    if [[ -t 0 ]]; then
        echo
        read -r -p 'Press Enter to exit...' || true
    fi
}

on_error() {
    local result=$?
    trap - ERR
    log ERROR "Could not ${ACTION} Local AI (exit code ${result})."
    log ERROR "See the log: ${LOG_FILE}"
    flock --unlock 9
    pause_before_exit
    exit "$result"
}
trap on_error ERR

if [[ "$ACTION" == start ]]; then
    log INFO 'Starting Open WebUI and Ollama…'
elif [[ "$ACTION" == stop ]]; then
    log INFO 'Stopping Open WebUI and Ollama. Any active reply will stop.'
else
    log INFO 'Checking for stable updates to Ollama, Phi, and Open WebUI…'
fi
log INFO 'Ubuntu may ask for your password to control the services.'
/usr/bin/pkexec /usr/local/sbin/local-ai-service-control "$ACTION" 2>&1 | tee -a "$LOG_FILE"

if [[ "$ACTION" == start ]]; then
    log OK 'Local AI is ready at http://127.0.0.1:8080'
    log INFO 'Opening the browser chat…'
    # Launch independently of this terminal; keep the browser alive until it exits.
    if ! /usr/bin/systemd-run --user --collect --quiet --service-type=exec \
        --property=ExitType=cgroup \
        --property=StandardOutput=null --property=StandardError=null \
        /usr/bin/xdg-open http://127.0.0.1:8080 >> "$LOG_FILE" 2>&1; then
        log WARN 'Open http://127.0.0.1:8080 in your browser.'
    fi
elif [[ "$ACTION" == stop ]]; then
    log OK 'Both services are stopped. Your conversations and downloaded model are saved.'
fi
log INFO "Log: ${LOG_FILE}"
flock --unlock 9
pause_before_exit
