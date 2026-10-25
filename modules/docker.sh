# shellcheck shell=bash disable=SC2034 # Metadata is read by maint.
# Docker: discover local containers; retain their owning Compose definitions.

MODULE_TITLE='Docker'
MODULE_ACTIONS=(
    'list|List Docker containers, images, state, and Compose ownership'
    'pull|Pull current container images again without restarting containers'
    'update|Pull and apply changed images using the original Compose settings'
)

# Settings.
DOCKER_WAIT_SECONDS=120    # Maximum wait for a recreated service to become healthy.

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

docker_discover() {
    local context endpoint
    require_commands docker jq
    create_temp_dir
    DOCKER_USE_SUDO=0
    # Resolve the user's endpoint before sudo, which has its own Docker context.
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
    if ! docker_exec info > /dev/null 2> "$TMP_DIR/access-error"; then
        require_sudo
        DOCKER_USE_SUDO=1
        docker_exec info > /dev/null
    fi
    info "Docker endpoint: ${endpoint}"
    DOCKER_INVENTORY="$TMP_DIR/containers.json"
    DOCKER_SELECTED="$TMP_DIR/selected.json"
    docker_refresh_inventory
    docker_show_inventory
}

docker_refresh_inventory() {
    local ids
    local -a container_ids=()
    ids="$(docker_exec ps -aq --no-trunc)"
    if [[ -n "$ids" ]]; then
        mapfile -t container_ids <<< "$ids"
        docker_exec inspect "${container_ids[@]}" | jq 'sort_by(.Name)' > "$DOCKER_INVENTORY"
    else
        printf '[]\n' > "$DOCKER_INVENTORY"
    fi
}

docker_show_inventory() {
    local rows
    if [[ "$(jq length "$DOCKER_INVENTORY")" == 0 ]]; then
        info 'No containers found.'
        return
    fi
    rows="$(jq -r 'to_entries[] | .key as $i | .value |
        [($i + 1), (.Name | ltrimstr("/")), .State.Status,
         (.State.Health.Status // "-"), .Config.Image,
         (if .Config.Labels["com.docker.compose.project"] then
            .Config.Labels["com.docker.compose.project"] + "/" +
            (.Config.Labels["com.docker.compose.service"] // "?") else "unmanaged" end)] | @tsv' "$DOCKER_INVENTORY")"
    print_and_log $'NUMBER\tCONTAINER\tSTATE\tHEALTH\tIMAGE\tCOMPOSE PROJECT/SERVICE'
    print_and_log "$rows"
}

docker_select() {
    local answer token count valid
    local -a numbers=()
    count="$(jq length "$DOCKER_INVENTORY")"
    cp -- "$DOCKER_INVENTORY" "$DOCKER_SELECTED"
    (( count > 0 )) || return 0
    [[ -t 0 ]] || return 0
    while true; do
        read -r -p 'Select containers (all, numbers separated by spaces/commas, or 0 to cancel): ' answer || answer=0
        case "$answer" in
            all) return 0 ;;
            ''|0) printf '[]\n' > "$DOCKER_SELECTED"; return 0 ;;
        esac
        read -r -a numbers <<< "${answer//,/ }"
        valid=1
        for token in "${numbers[@]}"; do
            if [[ ! "$token" =~ ^[1-9][0-9]*$ || ${#token} -gt 9 ]] || (( token > count )); then
                valid=0
                break
            fi
        done
        if (( valid && ${#numbers[@]} > 0 )); then
            jq --arg numbers "${numbers[*]}" '
                . as $all | ($numbers | split(" ") | map(tonumber - 1) | unique) |
                map($all[.])' "$DOCKER_INVENTORY" > "$DOCKER_SELECTED"
            return 0
        fi
        info "Choose all, 0, or container numbers from 1 to ${count}."
    done
}

action_list() {
    docker_discover
}

docker_image_platform() {
    local record="$1" platform image_id
    platform="$(jq -r '.ImageManifestDescriptor.platform // empty |
        .os + "/" + .architecture + (if .variant then "/" + .variant else "" end)' <<< "$record")"
    if [[ -z "$platform" ]]; then
        # Classic image stores do not expose a manifest descriptor on the container.
        image_id="$(jq -r '.Image' <<< "$record")"
        platform="$(docker_exec image inspect "$image_id" | jq -er '.[0] |
            .Os + "/" + .Architecture + (if (.Variant // "") != "" then "/" + .Variant else "" end)')"
    fi
    if [[ ! "$platform" =~ ^[a-z0-9]+/[a-z0-9]+(/[a-zA-Z0-9._-]+)?$ ]]; then
        error 'Cannot determine the deployed image platform.' >&2
        return 1
    fi
    printf '%s\n' "$platform"
}

docker_pull_images() {
    local file="$1" image record platform
    jq -c 'unique_by([.Config.Image, .Image, .ImageManifestDescriptor.platform])[]' "$file" > "$TMP_DIR/pull-records"
    : > "$TMP_DIR/pull-plan"
    while IFS= read -r record; do
        image="$(jq -r '.Config.Image' <<< "$record")"
        if [[ "$image" == sha256:* || "$image" =~ ^[a-f0-9]{64}$ ]]; then
            warn_condition "Skipping image ${image}: no registry reference is recorded."
            continue
        fi
        platform="$(docker_image_platform "$record")"
        printf '%s\t%s\n' "$image" "$platform" >> "$TMP_DIR/pull-plan"
    done < "$TMP_DIR/pull-records"
    sort -u "$TMP_DIR/pull-plan" > "$TMP_DIR/pulls"
    while IFS=$'\t' read -r image platform; do
        docker_run pull --platform "$platform" "$image"
    done < "$TMP_DIR/pulls"
}

action_pull() {
    docker_discover
    docker_select
    docker_pull_images "$DOCKER_SELECTED"
    success 'Image pulls finished; no containers were restarted.'
}

# Populates the Compose command and service only after validating ownership and source files.
docker_compose_context() {
    local file="$1" project directory paths path environment_files
    local -a files=()
    project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' "$file")"
    DOCKER_SERVICE="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // ""' "$file")"
    if [[ ! "$project" =~ ^[a-z0-9][a-z0-9_-]*$ || ! "$DOCKER_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        warn_condition 'Skipping container without valid Compose ownership; listing and pulling are still available.'
        return 1
    fi
    DOCKER_OWNER="${project}/${DOCKER_SERVICE}"
    if ! jq -e 'all(.[]; (.Config.Labels["com.docker.compose.oneoff"] // "false" | ascii_downcase) == "false"
        and .Config.Labels["com.docker.swarm.service.id"] == null
        and (.State.Status == "running" or .State.Status == "exited" or .State.Status == "created"))' "$file" > /dev/null; then
        warn_condition "Skipping ${DOCKER_OWNER}: one-off, Swarm, or transitional containers need their own lifecycle manager."
        return 1
    fi
    if ! jq -e --slurpfile all "$DOCKER_INVENTORY" --arg project "$project" --arg service "$DOCKER_SERVICE" '
        length == ([$all[0][] | select(.Config.Labels["com.docker.compose.project"] == $project and
            .Config.Labels["com.docker.compose.service"] == $service)] | length)' "$file" > /dev/null; then
        warn_condition "Skipping ${DOCKER_OWNER}: select all replicas of the service to update it."
        return 1
    fi
    if ! jq -e '[.[] | [.State.Running, .Config.Image,
        .ImageManifestDescriptor.platform,
        .Config.Labels["com.docker.compose.project.config_files"],
        .Config.Labels["com.docker.compose.project.working_dir"],
        .Config.Labels["com.docker.compose.project.environment_file"]]] | unique | length == 1' "$file" > /dev/null; then
        warn_condition "Skipping ${DOCKER_OWNER}: replicas have mixed states or source definitions."
        return 1
    fi
    directory="$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // ""' "$file")"
    paths="$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // ""' "$file")"
    environment_files="$(jq -r '.[0].Config.Labels["com.docker.compose.project.environment_file"] // ""' "$file")"
    if [[ "$directory" != /* || ! -d "$directory" || -z "$paths" || "$paths$environment_files" == *$'\n'* ]]; then
        warn_condition "Skipping ${DOCKER_OWNER}: the original Compose directory or file metadata is unavailable."
        return 1
    fi
    DOCKER_COMPOSE=(compose --project-name "$project" --project-directory "$directory")
    IFS=, read -r -a files <<< "$paths"
    for path in "${files[@]}"; do
        if [[ "$path" != /* || ! -r "$path" ]]; then
            warn_condition "Skipping ${DOCKER_OWNER}: Compose file is unavailable: ${path}"
            return 1
        fi
        DOCKER_COMPOSE+=(-f "$path")
    done
    if [[ -n "$environment_files" ]]; then
        IFS=, read -r -a files <<< "$environment_files"
        for path in "${files[@]}"; do
            [[ "$path" == /* ]] || path="$directory/$path"
            if [[ ! -r "$path" ]]; then
                warn_condition "Skipping ${DOCKER_OWNER}: environment file is unavailable: ${path}"
                return 1
            fi
            DOCKER_COMPOSE+=(--env-file "$path")
        done
    fi
}

# The service hash excludes top-level resources. Check their effective identities separately.
docker_validate_resources() {
    local file="$1"
    if ! jq -e --slurpfile model "$TMP_DIR/config.json" --arg service "$DOCKER_SERVICE" '
        def simple_resource:
            .external == true or
            (with_entries(select(.value != null and .value != {} and .value != [])) |
                (keys - ["name", "external"]) | length == 0);
        $model[0] as $cfg | $cfg.services[$service] as $s |
        (($s.secrets // []) | length == 0) and (($s.configs // []) | length == 0) and
        (($s.volumes_from // []) | length == 0) and
        all([$s.network_mode, $s.ipc, $s.pid][]; . == null or (test("^(service|container):") | not)) and
        all($s.volumes[]?; (.type == "bind" or .type == "volume" or .type == "tmpfs") and
            (if .type == "volume" and .source then $cfg.volumes[.source] | simple_resource else true end)) and
        all(($s.networks // {}) | keys[]; $cfg.networks[.] | simple_resource) and
        all(.[]; . as $container |
            all($s.volumes[]?; . as $volume |
                any($container.Mounts[]; .Destination == $volume.target and .Type == $volume.type and
                    .RW == (($volume.read_only // false) | not) and
                    (if $volume.type == "bind" then .Source == $volume.source
                     elif $volume.type == "volume" and $volume.source then .Name == $cfg.volumes[$volume.source].name
                     else true end))) and
            (($container.NetworkSettings.Networks | keys | sort) ==
                (if $s.network_mode then [$s.network_mode] else
                    [($s.networks // {}) | keys[] | $cfg.networks[.].name] | sort end)))
        ' "$file" > /dev/null; then
        warn_condition "Skipping ${DOCKER_OWNER}: resource identities differ or require project-managed updates (custom networks/volumes, secrets, configs, or shared namespaces)."
        return 1
    fi
}

docker_validate_config() {
    local file="$1" hash expected_image configured_image
    docker_compose_context "$file" || return 1
    # Do not log rendered configuration: it can contain interpolated secrets.
    if ! docker_exec "${DOCKER_COMPOSE[@]}" config --format json "$DOCKER_SERVICE" > "$TMP_DIR/config.json" 2> "$TMP_DIR/config-error" ||
       ! hash="$(docker_exec "${DOCKER_COMPOSE[@]}" config --hash "$DOCKER_SERVICE" 2> "$TMP_DIR/config-error")"; then
        warn_condition "Skipping ${DOCKER_OWNER}: Compose configuration cannot be resolved. Check its files and environment."
        return 1
    fi
    hash="${hash##* }"
    if [[ -z "$hash" ]] || ! jq -e --arg hash "$hash" 'all(.[]; .Config.Labels["com.docker.compose.config-hash"] == $hash)' "$file" > /dev/null; then
        warn_condition "Skipping ${DOCKER_OWNER}: Compose settings differ from the deployed configuration; reconcile them explicitly first."
        return 1
    fi
    expected_image="$(jq -r '.[0].Config.Image' "$file")"
    configured_image="$(jq -r --arg service "$DOCKER_SERVICE" '.services[$service].image // ""' "$TMP_DIR/config.json")"
    if [[ "$expected_image" != "$configured_image" || "$expected_image" == sha256:* ]] ||
       jq -e --arg service "$DOCKER_SERVICE" '.services[$service].build != null' "$TMP_DIR/config.json" > /dev/null; then
        warn_condition "Skipping ${DOCKER_OWNER}: the image is locally built or differs from the deployed reference."
        return 1
    fi
    docker_validate_resources "$file"
}

action_update() {
    local group index=0 file image local_id platform running count current
    local -a eligible=() start_options=()
    docker_discover
    docker_select
    [[ "$(jq length "$DOCKER_SELECTED")" != 0 ]] || return 0
    docker_exec compose version > /dev/null
    jq -c 'group_by([.Config.Labels["com.docker.compose.project"] // .Id,
        .Config.Labels["com.docker.compose.service"] // .Id])[]' "$DOCKER_SELECTED" > "$TMP_DIR/groups"
    while IFS= read -r group; do
        file="$TMP_DIR/group-$index.json"
        index=$((index + 1))
        printf '%s\n' "$group" > "$file"
        if docker_validate_config "$file"; then
            eligible+=("$file")
            info "Eligible: ${DOCKER_OWNER} ($(jq -r '.[0].State.Status' "$file"), $(jq length "$file") container(s))."
        fi
    done < "$TMP_DIR/groups"
    if (( ${#eligible[@]} == 0 )); then
        info 'No selected services can be updated safely from their recorded Compose definitions.'
        return 0
    fi
    warn_note 'Changed images require container recreation. In-memory data, temporary storage, and writable container-layer changes are lost; persistent mounts are retained.'
    warn_note 'Stopped services stay stopped. Dependencies, image tags, and Compose files are not changed.'
    warn_note 'Compose is the source of truth. Record any manual docker update overrides in its files before proceeding.'
    if ! confirm_phrase 'Pull and apply image updates for the eligible services?' UPDATE; then
        info 'Update cancelled; no images pulled or containers changed.'
        return 0
    fi
    # Complete every pull before the first recreation: a registry failure cannot leave a partially restarted group.
    jq -s 'add' "${eligible[@]}" > "$TMP_DIR/eligible.json"
    docker_pull_images "$TMP_DIR/eligible.json"
    for file in "${eligible[@]}"; do
        # Detect external recreation and source edits while the user was choosing or images were downloading.
        docker_refresh_inventory
        jq --slurpfile selected "$file" '[.[] | select(.Id as $id | any($selected[0][]; .Id == $id))]' \
            "$DOCKER_INVENTORY" > "$TMP_DIR/current.json"
        # Health checks may change normally; compare only the settings/state we rely on.
        current='map({Id, Image, Config, running: .State.Running, status: .State.Status, HostConfig, Mounts}) | sort_by(.Id)'
        if [[ "$(jq -cS "$current" "$file")" != "$(jq -cS "$current" "$TMP_DIR/current.json")" ]]; then
            warn_condition 'Skipping service: its containers changed since discovery. Run the action again.'
            continue
        fi
        docker_validate_config "$file" || continue
        image="$(jq -r '.[0].Config.Image' "$file")"
        platform="$(docker_image_platform "$(jq -c '.[0]' "$file")")"
        local_id="$(docker_exec image inspect --platform "$platform" "$image" | jq -er '.[0].Id')"
        if jq -e --arg image "$local_id" 'all(.[]; .Image == $image)' "$file" > /dev/null; then
            success "${DOCKER_OWNER}: image unchanged; containers kept as they are."
            continue
        fi
        count="$(jq length "$file")"
        running="$(jq -r '.[0].State.Running' "$file")"
        if [[ "$running" == true ]]; then
            start_options=(-d --wait --wait-timeout "$DOCKER_WAIT_SECONDS")
        else
            start_options=(--no-start)
        fi
        docker_run "${DOCKER_COMPOSE[@]}" up "${start_options[@]}" --no-deps --no-build --pull never \
            --remove-orphans=false --scale "$DOCKER_SERVICE=$count" "$DOCKER_SERVICE"
        success "${DOCKER_OWNER}: image updated; ${count} container(s), previous running/stopped state preserved."
    done
}
