#!/usr/bin/env bash
set -Eeuo pipefail

# Removes what install.sh added: the `maint` command, its Tab completion, and the desktop launcher.
# Logs stay in this folder; delete the folder to remove everything.
# Run as your own user: sudo is requested only for /usr/local/bin.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMAND=/usr/local/bin/maint
COMPLETION="${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions/maint"
LAUNCHER="$(xdg-user-dir DESKTOP)/Maintenance.desktop"

if (( EUID == 0 )); then
    echo 'Run uninstall.sh as your own user, without sudo.' >&2
    exit 1
fi

# Only remove items that belong to this folder.
if [[ -L "$COMMAND" && "$(readlink -f -- "$COMMAND")" == "${ROOT}/maint" ]]; then
    sudo rm -- "$COMMAND"
    echo "Removed ${COMMAND}"
fi

if [[ -L "$COMPLETION" && "$(readlink -f -- "$COMPLETION")" == "${ROOT}/completion.bash" ]]; then
    rm -- "$COMPLETION"
    echo "Removed ${COMPLETION}"
fi

if [[ -f "$LAUNCHER" ]] && grep -qxF "Icon=${ROOT}/icons/maint.png" "$LAUNCHER"; then
    rm -- "$LAUNCHER"
    echo "Removed ${LAUNCHER}"
fi
