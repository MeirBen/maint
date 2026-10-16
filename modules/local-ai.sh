# shellcheck shell=bash
# Local AI: Open WebUI and Ollama service controls.

MODULE_TITLE='Local AI'
MODULE_ACTIONS=(
    'start|Start Open WebUI + Ollama and open the chat'
    'stop|Stop Open WebUI + Ollama'
    'update|Update Ollama, the Phi model, and Open WebUI'
    'status|Show Ollama, Docker, and Open WebUI status'
)

CHAT_URL='http://127.0.0.1:8080'

action_start() {
    info 'Starting Open WebUI and Ollama…'
    control_services start
    success "Local AI is ready at ${CHAT_URL}"
    open_chat
    show_completion_summary
}

action_stop() {
    info 'Stopping Open WebUI and Ollama. Any active reply will stop.'
    control_services stop
    success 'Both services are stopped. Your conversations and downloaded model are saved.'
    show_completion_summary
}

action_update() {
    info 'Checking for stable updates to Ollama, Phi, and Open WebUI…'
    control_services update
    show_completion_summary
}

action_status() {
    show_status
    show_completion_summary
}

control_services() {
    require_sudo
    run_root /usr/local/sbin/local-ai-service-control "$1"
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
                info 'Health checks are inactive while the container is stopped. Start Local AI to run them.' ;;
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
    if (( EUID == 0 )); then
        info "Open ${CHAT_URL} in your browser."
        return 0
    fi
    info 'Opening the browser chat…'
    # Launch independently of this terminal; keep the browser alive until it exits.
    if ! /usr/bin/systemd-run --user --collect --quiet --service-type=exec \
        --property=ExitType=cgroup \
        --property=StandardOutput=null --property=StandardError=null \
        /usr/bin/xdg-open "$CHAT_URL" >> "$LOG_FILE" 2>&1; then
        warn_condition "Open ${CHAT_URL} in your browser."
    fi
}
