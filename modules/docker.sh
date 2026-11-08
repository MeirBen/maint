# shellcheck shell=bash disable=SC2034 # MODULE_TITLE and MODULE_ACTIONS are read by maint.
# Docker: list local containers; update Compose projects from their current Compose file.
# The unit of update is a Compose project deployed from one Compose file: everything an update recreates
# or removes belongs to it.

MODULE_TITLE='Docker'
MODULE_ACTIONS=(
    'list|List containers by Compose project; changes nothing'
    'update|Pull newer images, apply the current Compose file, and remove the images it replaced'
)

# Settings.
DOCKER_WAIT_SECONDS=120    # Maximum wait for restarted services to become running/healthy.

# jq definitions shared by every query over `docker inspect` records.
DOCKER_JQ='
def compose($name): .Config.Labels["com.docker.compose." + $name] // "";
def name: .Name | ltrimstr("/");
def state: .State.Status + (if .State.Health then " (" + .State.Health.Status + ")" else "" end);
def projects: [.[] | compose("project") | select(. != "")] | unique;
def familiar: sub("^(index\\.)?docker\\.io/"; "") | sub("^library/"; "") | sub(":[^/@]*@"; "@") |
    if split("/")[-1] | test("[:@]") then . else . + ":latest" end;
'

action_list() {
    docker_connect
    docker_load_inventory
    docker_show_inventory
}

action_update() {
    local project
    local -a ready=()
    docker_connect
    docker_load_inventory
    docker_show_inventory
    docker_load_projects
    if (( ${#DOCKER_PROJECTS[@]} == 0 )); then
        info 'No Compose projects to update.'
        return 0
    fi
    if ! docker_exec compose version > /dev/null 2>&1; then
        error 'Docker Compose v2 is required: the docker compose command is unavailable.'
        return 1
    fi
    docker_select_projects
    if (( ${#DOCKER_SELECTED[@]} == 0 )); then
        info 'No project selected; nothing was changed.'
        return 0
    fi
    for project in "${DOCKER_SELECTED[@]}"; do
        if docker_check_project "$project"; then
            ready+=("$project")
        fi
    done
    if (( ${#ready[@]} == 0 )); then
        info 'No selected project can be updated.'
        return 0
    fi
    warn_note 'Settings such as ports, users, and limits are applied exactly as written in the Compose file; changes made to containers by hand are not kept.'
    warn_note 'Services whose image or settings changed are recreated; containers of services no longer defined are removed.'
    warn_note "Services that were running are started again and must be running/healthy within ${DOCKER_WAIT_SECONDS} seconds; stopped services stay stopped unless a running service depends on them."
    warn_note 'Named volumes and bind mounts are kept. Recreation loses in-memory data, tmpfs contents, and files changed inside the container.'
    warn_note 'Afterwards the images each project ran before are removed once no container uses them.'
    if ! confirm "Update ${#ready[@]} Compose project(s)?"; then
        info 'Update cancelled; nothing was changed.'
        return 0
    fi
    # Download everything first: a registry failure must leave every project untouched.
    info 'Checking for newer images. Nothing changes until every download has finished.'
    for project in "${ready[@]}"; do
        if ! docker_compose_context "$project"; then
            error "Stopping before any change: ${project} can no longer be reproduced."
            return 1
        fi
        docker_run "${DOCKER_COMPOSE[@]}" pull
    done
    for project in "${ready[@]}"; do
        docker_update_project "$project"
    done
}

docker_exec() {
    if (( DOCKER_USE_SUDO )); then
        as_root "${DOCKER_COMMAND[@]}" "$@"
    else
        "${DOCKER_COMMAND[@]}" "$@"
    fi
}

docker_run() {
    if (( DOCKER_USE_SUDO )); then
        run_root "${DOCKER_COMMAND[@]}" "$@"
    else
        run "${DOCKER_COMMAND[@]}" "$@"
    fi
}

# Pins the user's local Docker endpoint, then falls back to sudo only if that socket denies access.
docker_connect() {
    local context endpoint
    require_commands docker jq
    create_temp_dir
    DOCKER_INVENTORY="$TMP_DIR/containers.json"
    DOCKER_PROJECT="$TMP_DIR/project.json"
    DOCKER_USE_SUDO=0
    # Resolve the endpoint before sudo, which has its own Docker context.
    if [[ -z "${DOCKER_CONTEXT:-}" && -n "${DOCKER_HOST:-}" ]]; then
        endpoint="$DOCKER_HOST"
    else
        context="${DOCKER_CONTEXT:-$(docker context show)}"
        endpoint="$(docker context inspect "$context" | jq -er '.[0].Endpoints.docker.Host')"
    fi
    if [[ "$endpoint" != unix:///* ]]; then
        error 'This module supports local Unix-socket Docker engines only; the selected endpoint was not changed.'
        return 1
    fi
    DOCKER_COMMAND=(docker --config "${DOCKER_CONFIG:-$HOME/.docker}" --host "$endpoint")
    if ! docker_exec info > /dev/null 2>&1; then
        require_sudo
        DOCKER_USE_SUDO=1
        docker_exec info > /dev/null
    fi
    info "Docker endpoint: ${endpoint}"
}

docker_load_inventory() {
    local ids
    local -a container_ids=()
    ids="$(docker_exec ps --all --quiet --no-trunc)"
    if [[ -z "$ids" ]]; then
        printf '[]\n' > "$DOCKER_INVENTORY"
        return
    fi
    mapfile -t container_ids <<< "$ids"
    docker_exec inspect "${container_ids[@]}" | jq 'sort_by(.Name)' > "$DOCKER_INVENTORY"
}

# Project numbers follow this sorted order in the inventory and in the selection prompt.
docker_load_projects() {
    local names
    DOCKER_PROJECTS=()
    names="$(jq -r "$DOCKER_JQ"'projects[]' "$DOCKER_INVENTORY")"
    if [[ -n "$names" ]]; then
        mapfile -t DOCKER_PROJECTS <<< "$names"
    fi
}

docker_show_inventory() {
    local rows header=$'#\tPROJECT\tCONTAINER\tSTATE\tIMAGE'
    if [[ "$(jq length "$DOCKER_INVENTORY")" == 0 ]]; then
        info 'No containers found.'
        return
    fi
    rows="$(jq -r "$DOCKER_JQ"'projects as $projects |
        (. as $all | $projects | to_entries[] | .key as $index | .value as $project |
            $all[] | select(compose("project") == $project) | [$index + 1, $project, name, state, .Config.Image]),
        (.[] | select(compose("project") == "") | ["-", "(none)", name, state, .Config.Image])
        | @tsv' "$DOCKER_INVENTORY")"
    if [[ ! -t 1 ]]; then
        print_and_log "$header"$'\n'"$rows"
        return
    fi
    # Keep complete, unstyled TSV in the log, independent of terminal size.
    printf '%s\n%s\n' "$header" "$rows" >> "$LOG_FILE"
    docker_render_inventory "$header" "$rows"
}

# Aligned columns when they fit the terminal, labeled entries otherwise; each project is named once.
docker_render_inventory() {
    local header="$1" rows="$2" column total=0 previous='' prefix
    local -a widths=(0 0 0 0 0) cells=()
    terminal_setup
    while IFS=$'\t' read -r -a cells; do
        for column in "${!widths[@]}"; do
            if (( ${#cells[column]} > widths[column] )); then
                widths[column]="${#cells[column]}"
            fi
        done
    done <<< "$header"$'\n'"$rows"
    # Each column has two spaces before it, including the left margin.
    for column in "${widths[@]}"; do total=$((total + column + 2)); done

    printf '\n  %sContainers by Compose project%s\n\n' "$TERMINAL_BOLD" "$TERMINAL_RESET"
    if (( total <= TERMINAL_WIDTH - 2 )); then
        while IFS=$'\t' read -r -a cells; do
            if [[ "${cells[0]}" == "$previous" ]]; then
                cells[0]='' cells[1]=''
            else
                previous="${cells[0]}"
            fi
            printf '  %*s  %-*s  %-*s  %-*s  %s\n' "${widths[0]}" "${cells[0]}" "${widths[1]}" "${cells[1]}" \
                "${widths[2]}" "${cells[2]}" "${widths[3]}" "${cells[3]}" "${cells[4]}"
            if [[ "$previous" == '#' ]]; then
                terminal_rule "$((total - 2))"
            fi
        done <<< "$header"$'\n'"$rows"
    else
        while IFS=$'\t' read -r -a cells; do
            if [[ "${cells[0]}" != "$previous" ]]; then
                previous="${cells[0]}"
                printf -v prefix '  %*s) ' "${widths[0]}" "${cells[0]}"
                terminal_wrap "$prefix" "${cells[1]}" "$((TERMINAL_WIDTH - 2))"
            fi
            terminal_wrap '       Container  ' "${cells[2]}" "$((TERMINAL_WIDTH - 2))"
            terminal_wrap '       State      ' "${cells[3]}" "$((TERMINAL_WIDTH - 2))"
            terminal_wrap '       Image      ' "${cells[4]}" "$((TERMINAL_WIDTH - 2))"
            printf '\n'
        done <<< "$rows"
    fi
    printf '\n'
}

# Sets DOCKER_SELECTED to the chosen project names, in inventory order. Without a terminal, all are chosen.
docker_select_projects() {
    local answer token index count="${#DOCKER_PROJECTS[@]}" valid
    local -a numbers=()
    DOCKER_SELECTED=("${DOCKER_PROJECTS[@]}")
    [[ -t 0 ]] || return 0
    while true; do
        read -r -p 'Select projects (all, numbers separated by spaces/commas, or 0 to cancel): ' answer || answer=0
        case "$answer" in
            all) return 0 ;;
            ''|0) DOCKER_SELECTED=(); return 0 ;;
        esac
        read -r -a numbers <<< "${answer//,/ }"
        valid=1
        for token in "${numbers[@]}"; do
            if [[ ! "$token" =~ ^[1-9][0-9]{0,8}$ ]] || (( token > count )); then
                valid=0
                break
            fi
        done
        if (( valid && ${#numbers[@]} > 0 )); then
            DOCKER_SELECTED=()
            for index in "${!DOCKER_PROJECTS[@]}"; do
                if [[ " ${numbers[*]} " == *" $((index + 1)) "* ]]; then
                    DOCKER_SELECTED+=("${DOCKER_PROJECTS[index]}")
                fi
            done
            return 0
        fi
        info "Choose all, 0, or project numbers from 1 to ${count}."
    done
}

# Sets DOCKER_COMPOSE to the command that deployed the project: its name, directory, and Compose file
# as recorded on its containers. Snapshots those containers to DOCKER_PROJECT.
docker_compose_context() {
    local project="$1" directory file environment_files
    jq --arg project "$project" "$DOCKER_JQ"'map(select(compose("project") == $project))' \
        "$DOCKER_INVENTORY" > "$DOCKER_PROJECT"
    if ! jq -e "$DOCKER_JQ"'length > 0 and
        (map([compose("project.working_dir"), compose("project.config_files"), compose("project.environment_file")])
            | unique | length == 1)' "$DOCKER_PROJECT" > /dev/null; then
        warn_condition "Skipping ${project}: its containers are gone or were deployed from different Compose files."
        return 1
    fi
    directory="$(jq -r "$DOCKER_JQ"'.[0] | compose("project.working_dir")' "$DOCKER_PROJECT")"
    file="$(jq -r "$DOCKER_JQ"'.[0] | compose("project.config_files")' "$DOCKER_PROJECT")"
    environment_files="$(jq -r "$DOCKER_JQ"'.[0] | compose("project.environment_file")' "$DOCKER_PROJECT")"
    if [[ "$file" == *,* || -n "$environment_files" ]]; then
        warn_condition "Skipping ${project}: it was deployed with several Compose files or an environment file; only single-file projects are updated."
        return 1
    fi
    if [[ "$directory" != /* || ! -d "$directory" || "$file" != /* || ! -r "$file" || "$directory$file" == *$'\n'* ]]; then
        warn_condition "Skipping ${project}: its recorded Compose directory or file is unavailable: ${directory}, ${file}"
        return 1
    fi
    DOCKER_COMPOSE=(compose --project-name "$project" --project-directory "$directory" --file "$file")
}

# Confirms the project's Compose file still resolves, and shows any Compose warnings before the prompt.
docker_check_project() {
    local project="$1" messages="$TMP_DIR/compose-check"
    docker_compose_context "$project" || return 1
    if ! docker_exec "${DOCKER_COMPOSE[@]}" config --quiet > "$messages" 2>&1; then
        tee -a "$LOG_FILE" < "$messages"
        warn_condition "Skipping ${project}: its Compose file does not resolve; see the messages above."
        return 1
    fi
    if [[ -s "$messages" ]]; then
        tee -a "$LOG_FILE" < "$messages"
        warn_condition "${project}: Compose reported the warnings above; review them before confirming."
    fi
    info "Ready: ${project} ($(jq -r "$DOCKER_JQ"'.[0] | compose("project.config_files")' "$DOCKER_PROJECT"))"
    docker_show_changes "$project"
}

# Names services whose settings differ from their deployed containers, so an unintended change, such as
# an unset variable, is visible before confirming. Compose recreates exactly these services.
docker_show_changes() {
    local project="$1" hashes notes note
    local -a lines=()
    hashes="$(docker_exec "${DOCKER_COMPOSE[@]}" config --hash '*' 2> /dev/null)"
    notes="$(jq -nr --arg hashes "$hashes" --slurpfile project "$DOCKER_PROJECT" "$DOCKER_JQ"'
        ($hashes | split("\n") | map(select(. != "") | split(" ") | {key: .[0], value: .[1]}) | from_entries) as $model |
        $project[0] as $deployed |
        ([$deployed[] | compose("service") as $service |
            select($model[$service] != null and $model[$service] != compose("config-hash")) | $service] | unique) as $changed |
        ([$deployed[] | compose("service") | select($model[.] == null)] | unique) as $removed |
        (select($changed != []) | "settings in the Compose file differ from the current containers for: " +
            ($changed | join(", ")) + ". Expected after editing the file or upgrading Compose; otherwise decline and check for unset variables."),
        (select($removed != []) | "no longer defined in the Compose file; their containers will be removed: " +
            ($removed | join(", ")))')"
    [[ -n "$notes" ]] || return 0
    mapfile -t lines <<< "$notes"
    for note in "${lines[@]}"; do
        warn_note "${project}: ${note}"
    done
}

# Converges every service without starting anything new, restarts what was running before,
# then removes the images the update replaced.
docker_update_project() {
    local project="$1" defined services
    local -a running=()
    DOCKER_CHANGES=()
    info "${project}: applying its Compose file..."
    # Read the state after the downloads, not at selection time: it may have changed meanwhile.
    docker_load_inventory
    docker_compose_context "$project" || return 0
    # A running service that the Compose file no longer defines is removed, not started again.
    defined="$(docker_exec "${DOCKER_COMPOSE[@]}" config --services 2> /dev/null)"
    services="$(jq -r --arg defined "$defined" "$DOCKER_JQ"'[.[] | select(.State.Running) |
        compose("service") | select(IN($defined | split("\n")[]))] | unique[]' "$DOCKER_PROJECT")"
    docker_run "${DOCKER_COMPOSE[@]}" up --no-start --pull never --remove-orphans
    if [[ -n "$services" ]]; then
        mapfile -t running <<< "$services"
        docker_run "${DOCKER_COMPOSE[@]}" up --detach --wait --wait-timeout "$DOCKER_WAIT_SECONDS" \
            --pull never "${running[@]}"
    fi
    docker_load_inventory
    docker_record_container_changes "$project"
    docker_remove_replaced_images
    docker_report_result "$project" "${running[@]}"
}

# Adds "1 noun verb" or "N nouns verb" to DOCKER_CHANGES; a zero count adds nothing.
docker_record_change() {
    local count="$1" noun="$2" verb="$3"
    if (( count == 1 )); then
        DOCKER_CHANGES+=("1 ${noun} ${verb}")
    elif (( count > 1 )); then
        DOCKER_CHANGES+=("${count} ${noun}s ${verb}")
    fi
}

# Compares the project's containers before (DOCKER_PROJECT) and after the update.
docker_record_container_changes() {
    local project="$1" counts recreated created removed
    counts="$(jq -r --arg project "$project" --slurpfile before "$DOCKER_PROJECT" "$DOCKER_JQ"'
        $before[0] as $old |
        [.[] | select(compose("project") == $project)] as $new |
        [$new[] | select(.Id | IN($old[].Id) | not)] as $fresh |
        ([$old[] | compose("service")] | unique) as $old_services |
        ([$new[] | compose("service")] | unique) as $new_services |
        [([$fresh[] | select(compose("service") | IN($old_services[]))] | length),
         ([$fresh[] | select(compose("service") | IN($old_services[]) | not)] | length),
         ([$old[] | select(compose("service") | IN($new_services[]) | not)] | length)] | @tsv' "$DOCKER_INVENTORY")"
    read -r recreated created removed <<< "$counts"
    docker_record_change "$recreated" container recreated
    docker_record_change "$created" container created
    docker_record_change "$removed" container removed
}

# One line per project: what changed, or that nothing did, and which services run now.
docker_report_result() {
    local project="$1" summary='already up to date, nothing changed' state='Stopped, as before'
    shift
    if (( ${#DOCKER_CHANGES[@]} > 0 )); then
        printf -v summary '%s, ' "${DOCKER_CHANGES[@]}"
        summary="${summary%, }"
    fi
    if (( $# > 0 )); then
        printf -v state '%s, ' "$@"
        state="Running: ${state%, }"
    fi
    success "${project}: ${summary}. ${state}."
}

# Removes images that DOCKER_PROJECT's containers ran before the update once no container uses them,
# provided every tag left on them is a reference the project itself used.
docker_remove_replaced_images() {
    local replaced id record tags removed=0
    local -a ids=() targets=()
    replaced="$(jq -r --slurpfile now "$DOCKER_INVENTORY" '[.[].Image] - [$now[0][].Image] | unique[]' "$DOCKER_PROJECT")"
    [[ -n "$replaced" ]] || return 0
    mapfile -t ids <<< "$replaced"
    for id in "${ids[@]}"; do
        record="$(docker_exec image inspect "$id" 2> /dev/null)" || continue
        if ! jq -e --slurpfile project "$DOCKER_PROJECT" "$DOCKER_JQ"'
            [$project[0][].Config.Image | familiar] as $owned |
            all(.[0].RepoTags[]?; familiar | IN($owned[]))' <<< "$record" > /dev/null; then
            warn_note "Kept replaced image ${id}: it is also tagged $(jq -r '.[0].RepoTags | join(", ")' <<< "$record")."
            continue
        fi
        tags="$(jq -r '.[0].RepoTags[]?' <<< "$record")"
        if [[ -n "$tags" ]]; then
            mapfile -t targets <<< "$tags"
        else
            targets=("$id")
        fi
        if docker_run image rm "${targets[@]}"; then
            removed=$((removed + 1))
        else
            warn_condition "Could not remove replaced image ${id}; it was kept."
        fi
    done
    docker_record_change "$removed" 'old image' removed
}
