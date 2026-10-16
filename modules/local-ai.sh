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
    echo '4) Current services status'
    echo '5) Exit'
    echo
    while true; do
        read -r -p 'Choose [1-5]: ' choice || return 1
        case "$choice" in
            1) ACTION=start; return 0 ;;
            2) ACTION=stop; return 0 ;;
            3) ACTION=update; return 0 ;;
            4) ACTION=status; return 0 ;;
            5) return 1 ;;
            *) echo 'Please choose 1, 2, 3, 4, or 5.' ;;
        esac
    done
}

show_status() {
    local service state docker_state="unknown" container_details container_state health_state
    info 'Checking current Local AI service status…'
    for service in ollama docker; do
        # is-active returns nonzero for normal stopped/failed states.
        state="$(systemctl is-active "${service}.service" 2>> "$LOG_FILE")" || true
        case "$state" in
            active) success "${service^}: RUNNING" ;;
            inactive) info "${service^}: NOT RUNNING" ;;
            failed) warn_condition "${service^}: FAILED" ;;
            activating|deactivating|reloading|refreshing|maintenance)
                info "${service^}: ${state^^}" ;;
            *)
                state=unknown
                warn_condition "${service^}: UNKNOWN (service missing or status unavailable; see log)" ;;
        esac
        if [[ "$service" == docker ]]; then
            docker_state="$state"
        fi
    done

    # Avoid contacting Docker's socket when stopped: it could activate the daemon.
    if [[ "$docker_state" != active && "$docker_state" != reloading ]]; then
        warn_note "Open WebUI: UNKNOWN (Docker is ${docker_state}; container status unavailable)"
        return 0
    fi

    require_sudo
    if container_details="$(as_root /usr/bin/docker --host unix:///var/run/docker.sock \
        inspect --type container --format \
        '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        open-webui 2>> "$LOG_FILE")"; then
        IFS='|' read -r container_state health_state <<< "$container_details"
        case "$container_state" in
            running)
                case "$health_state" in
                    healthy) success 'Open WebUI: RUNNING (health: healthy)' ;;
                    starting) info 'Open WebUI: RUNNING (health: starting)' ;;
                    none) info 'Open WebUI: RUNNING (no health check configured)' ;;
                    *) warn_condition "Open WebUI: RUNNING (health: ${health_state:-unknown})" ;;
                esac ;;
            created|exited)
                info "Open WebUI: NOT RUNNING (${container_state})"
                info 'Health checks are inactive while the container is stopped. Choose option 1 to start Local AI.' ;;
            paused) info 'Open WebUI: PAUSED (health checks are inactive)' ;;
            restarting) warn_condition 'Open WebUI: RESTARTING' ;;
            dead) warn_condition 'Open WebUI: FAILED (dead)' ;;
            *) warn_condition "Open WebUI: ${container_state:-UNKNOWN}" ;;
        esac
    else
        warn_condition 'Open WebUI: UNKNOWN (container missing or status unavailable; see log)'
    fi
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
    elif [[ $# -ne 1 || ( "$ACTION" != start && "$ACTION" != stop && "$ACTION" != update && "$ACTION" != status ) ]]; then
        echo 'Usage: local-ai start|stop|update|status' >&2
        return 2
    fi

    initialize_runtime "$SCRIPT_DIR" local-ai "Local AI ${ACTION}"
    case "$ACTION" in
        start) info 'Starting Open WebUI and Ollama…' ;;
        stop) info 'Stopping Open WebUI and Ollama. Any active reply will stop.' ;;
        update) info 'Checking for stable updates to Ollama, Phi, and Open WebUI…' ;;
        status) show_status; show_completion_summary; return 0 ;;
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
