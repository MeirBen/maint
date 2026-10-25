# shellcheck shell=bash
# Bash Tab completion for maint: modules, then their actions, read from `maint list`.

_maint() {
    local current="${COMP_WORDS[COMP_CWORD]}" words index options=1 help=0
    local -a arguments=()
    COMPREPLY=()
    for ((index = 1; index < COMP_CWORD; index++)); do
        if (( options )); then
            case "${COMP_WORDS[index]}" in
                -h|--help) help=1; continue ;;
                --no-color) continue ;;
                -V|--version) return 0 ;;
                --) options=0; continue ;;
                -*) return 0 ;;
            esac
        fi
        arguments+=("${COMP_WORDS[index]}")
    done
    if [[ "${arguments[0]:-}" == help ]]; then
        help=1
        arguments=("${arguments[@]:1}")
    fi
    if (( options )) && [[ "$current" == -* ]]; then
        words='-h --help --no-color --'
        if (( ${#arguments[@]} == 0 && ! help )); then words+=' -V --version'; fi
    else
        case "${#arguments[@]}" in
            0)
                words="list $(maint list 2>/dev/null | cut -f1 | uniq)"
                if (( ! help )); then words="help $words"; fi ;;
            1)
                [[ "${arguments[0]}" != list ]] || return 0
                words="$(maint list 2>/dev/null | awk -F'\t' -v module="${arguments[0]}" '$1 == module {print $2}')" ;;
            *) return 0 ;;
        esac
    fi
    mapfile -t COMPREPLY < <(compgen -W "$words" -- "$current")
}

complete -F _maint maint
