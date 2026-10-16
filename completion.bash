# shellcheck shell=bash
# Bash Tab completion for maint: modules, then their actions, read from `maint list`.

_maint() {
    local current="${COMP_WORDS[COMP_CWORD]}" words
    case "$COMP_CWORD" in
        1) words="help list $(maint list 2>/dev/null | cut -f1 | uniq)" ;;
        2) words="$(maint list 2>/dev/null | awk -F'\t' -v module="${COMP_WORDS[1]}" '$1 == module {print $2}')" ;;
        *) return 0 ;;
    esac
    mapfile -t COMPREPLY < <(compgen -W "$words" -- "$current")
}

complete -F _maint maint
