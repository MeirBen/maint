#!/usr/bin/env bash
set -Eeuo pipefail

# Local AI feature: Open WebUI and Ollama service controls.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

choose_action() {
    local choice
    echo 'Local AI — Open WebUI + Ollama'
    echo
    echo '1) Start and open chat'
    echo '2) Stop'
    echo '3) Update / upgrade'
    echo '4) Exit'
    echo
    while true; do
        read -r -p 'Choose [1-4]: ' choice || return 1
        case "$choice" in
            1) ACTION=start; return 0 ;;
            2) ACTION=stop; return 0 ;;
            3) ACTION=update; return 0 ;;
            4) return 1 ;;
            *) echo 'Please choose 1, 2, 3, or 4.' ;;
        esac
    done
}

open_chat() {
    success 'Local AI is ready at http://127.0.0.1:8080'
    if (( EUID == 0 )); then
        info 'Open http://127.0.0.1:8080 in your browser.'
    else
        info 'Opening the browser chat…'
        # Launch independently of this terminal; keep the browser alive until it exits.
        if ! /usr/bin/systemd-run --user --collect --quiet --service-type=exec \
            --property=ExitType=cgroup \
            --property=StandardOutput=null --property=StandardError=null \
            /usr/bin/xdg-open http://127.0.0.1:8080 >> "$LOG_FILE" 2>&1; then
            warn_condition 'Open http://127.0.0.1:8080 in your browser.'
        fi
    fi
}

main() {
    ACTION="${1:-}"
    if [[ $# -eq 0 ]]; then
        choose_action || return 0
    elif [[ $# -ne 1 || ( "$ACTION" != start && "$ACTION" != stop && "$ACTION" != update ) ]]; then
        echo 'Usage: local-ai start|stop|update' >&2
        return 2
    fi

    initialize_runtime "$SCRIPT_DIR" local-ai "Local AI ${ACTION}"
    case "$ACTION" in
        start) info 'Starting Open WebUI and Ollama…' ;;
        stop) info 'Stopping Open WebUI and Ollama. Any active reply will stop.' ;;
        update) info 'Checking for stable updates to Ollama, Phi, and Open WebUI…' ;;
    esac
    require_sudo
    run_root /usr/local/sbin/local-ai-service-control "$ACTION"

    case "$ACTION" in
        start) open_chat ;;
        stop) success 'Both services are stopped. Your conversations and downloaded model are saved.' ;;
    esac
    show_completion_summary
}

main "$@"
