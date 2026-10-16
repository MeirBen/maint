#!/usr/bin/env bash
set -Eeuo pipefail

# Maintenance: one entry point for every module in modules/.
#   maintenance                  menu of every action
#   maintenance MODULE           menu of one module's actions
#   maintenance MODULE ACTION    run one action
#   maintenance help             list every command

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "${SELF%/*}/lib/common.sh"

# Action registry in menu order, filled by load_modules.
ENTRY_MODULES=()
ENTRY_ACTIONS=()
ENTRY_DESCRIPTIONS=()
declare -A MODULE_TITLES=()

load_modules() {
    local file id rows title action description
    for file in "${MAINTENANCE_ROOT}"/modules/*.sh; do
        id="${file##*/}"
        id="${id%.sh}"
        if ! rows="$(describe_module "$file")"; then
            printf 'Skipping module %s: it failed to load.\n' "${file##*/}" >&2
            continue
        fi
        { read -r title
          MODULE_TITLES[$id]="$title"
          while IFS='|' read -r action description; do
              ENTRY_MODULES+=("$id")
              ENTRY_ACTIONS+=("$action")
              ENTRY_DESCRIPTIONS+=("$description")
          done
        } <<< "$rows"
    done
}

# Prints the module's title, then one "action|description" row per action.
# The subshell keeps modules from seeing or overriding each other.
describe_module() (
    local row
    # shellcheck source=/dev/null
    source "$1" || exit 1
    [[ -n "${MODULE_TITLE:-}" ]] && (( ${#MODULE_ACTIONS[@]} )) || exit 1
    printf '%s\n' "$MODULE_TITLE"
    for row in "${MODULE_ACTIONS[@]}"; do
        declare -F "action_${row%%|*}" > /dev/null || exit 1
        printf '%s\n' "$row"
    done
)

# Prints the registry index of MODULE ACTION, or fails when it is not registered.
find_entry() {
    local index
    for index in "${!ENTRY_MODULES[@]}"; do
        if [[ "${ENTRY_MODULES[index]}" == "$1" && "${ENTRY_ACTIONS[index]}" == "$2" ]]; then
            printf '%s\n' "$index"
            return 0
        fi
    done
    return 1
}

usage() {
    local index
    echo 'Usage: maintenance [MODULE [ACTION]]'
    echo
    echo 'Without arguments, opens the menu. With MODULE only, opens its menu.'
    echo
    for index in "${!ENTRY_MODULES[@]}"; do
        printf '  %-30s %s\n' "maintenance ${ENTRY_MODULES[index]} ${ENTRY_ACTIONS[index]}" \
            "${ENTRY_DESCRIPTIONS[index]}"
    done
}

run_action() {
    local module="$1" action="$2"
    # shellcheck source=/dev/null
    source "${MAINTENANCE_ROOT}/modules/${module}.sh"
    initialize_runtime "$module" "${MODULE_TITLES[$module]} ${action}"
    "action_${action}"
}

# Each choice runs in a child process, so its lock, traps, and temporary files
# are released before the menu returns.
run_menu() {
    local module_filter="${1:-}" index position choice status module
    local -a choices=()
    # Bash defers these until a running action exits, so it always cleans up first.
    trap 'exit 129' HUP
    trap 'exit 143' TERM
    for index in "${!ENTRY_MODULES[@]}"; do
        if [[ -z "$module_filter" || "${ENTRY_MODULES[index]}" == "$module_filter" ]]; then
            choices+=("$index")
        fi
    done

    while true; do
        echo
        echo 'Maintenance'
        module=""
        for position in "${!choices[@]}"; do
            index="${choices[position]}"
            if [[ "${ENTRY_MODULES[index]}" != "$module" ]]; then
                module="${ENTRY_MODULES[index]}"
                printf '\n%s\n' "${MODULE_TITLES[$module]}"
            fi
            printf '  %2d) %s\n' "$((position + 1))" "${ENTRY_DESCRIPTIONS[index]}"
        done
        printf '\n   0) Exit\n\n'

        while true; do
            read -r -p "Choose [0-${#choices[@]}]: " choice || return 0
            if [[ "$choice" == 0 ]]; then
                return 0
            fi
            if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#choices[@]} )); then
                break
            fi
            echo "Please choose a number from 0 to ${#choices[@]}."
        done

        index="${choices[choice - 1]}"
        status=0
        "$BASH" "$SELF" "${ENTRY_MODULES[index]}" "${ENTRY_ACTIONS[index]}" || status=$?
        case "$status" in
            129|130|143) return "$status" ;;
        esac
        if [[ -t 0 ]]; then
            echo
            read -r -p 'Press Enter to return to the menu...' || return 0
        fi
    done
}

main() {
    local index
    load_modules
    case "$#:${1:-}" in
        0:) run_menu ;;
        1:help|1:-h|1:--help) usage ;;
        1:*)
            if [[ -z "${MODULE_TITLES[$1]+set}" ]]; then
                usage >&2
                return 2
            fi
            run_menu "$1" ;;
        2:*)
            if ! index="$(find_entry "$1" "$2")"; then
                usage >&2
                return 2
            fi
            run_action "${ENTRY_MODULES[index]}" "${ENTRY_ACTIONS[index]}" ;;
        *)
            usage >&2
            return 2 ;;
    esac
}

main "$@"
