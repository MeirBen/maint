#!/usr/bin/env bash
# Presentation helpers only: safe to load without starting an action runtime.

terminal_setup() {
    local size="" columns="${COLUMNS:-80}"
    if [[ -t 1 ]]; then
        # Preserve the terminal descriptor before command substitution redirects stdout.
        { size="$(stty size <&3 2>/dev/null)" || size=""; } 3<&1
        if [[ "$size" =~ ^[0-9]+\ ([1-9][0-9]*)$ ]]; then
            columns="${BASH_REMATCH[1]}"
        fi
    fi
    [[ "$columns" =~ ^[1-9][0-9]{0,3}$ ]] || columns=80
    TERMINAL_WIDTH="$columns"
    TERMINAL_BOLD="" TERMINAL_ACCENT="" TERMINAL_RESET=""
    if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
        TERMINAL_BOLD=$'\033[1m'
        TERMINAL_ACCENT=$'\033[1;36m'
        TERMINAL_RESET=$'\033[0m'
    fi
}

terminal_rule() {
    local line width="$1"
    (( width >= 0 )) || width=0
    printf -v line '%*s' "$width" ''
    printf '  %s\n' "${line// /-}"
}

# Wrap under the text, not under its number or field label. Long identifiers are
# continued in full so image tags and Compose ownership are never truncated.
terminal_wrap() {
    local prefix="$1" text="$2" columns="$3" indent width chunk
    (( columns > 0 )) || columns=1
    printf -v indent '%*s' "${#prefix}" ''
    width=$((columns - ${#prefix}))
    if (( width < 1 )); then
        prefix="" indent="" width="$columns"
    fi
    while (( ${#text} > width )); do
        chunk="${text:0:width}"
        if [[ "$chunk" == *' '* && "${text:width:1}" != ' ' ]]; then
            chunk="${chunk% *}"
        fi
        printf '%s%s\n' "$prefix" "$chunk"
        text="${text:${#chunk}}"
        while [[ "$text" == ' '* ]]; do text="${text:1}"; done
        prefix="$indent"
    done
    printf '%s%s\n' "$prefix" "$text"
}
