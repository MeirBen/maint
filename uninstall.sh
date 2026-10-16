#!/usr/bin/env bash
set -Eeuo pipefail

# Removes what install.sh added: the `maintenance` command and its desktop launcher.
# Logs stay in this folder; delete the folder to remove everything.
# Run as your own user: sudo is requested only to remove the link from /usr/local/bin.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMAND=/usr/local/bin/maintenance
LAUNCHER="$(xdg-user-dir DESKTOP)/Maintenance.desktop"

if (( EUID == 0 )); then
    echo 'Run uninstall.sh as your own user, without sudo.' >&2
    exit 1
fi

# Only remove items that belong to this folder.
if [[ -L "$COMMAND" && "$(readlink -f -- "$COMMAND")" == "${ROOT}/maintenance.sh" ]]; then
    sudo rm -- "$COMMAND"
    echo "Removed ${COMMAND}"
fi

if [[ -f "$LAUNCHER" ]] && grep -qxF "Icon=${ROOT}/icons/maintenance.png" "$LAUNCHER"; then
    rm -- "$LAUNCHER"
    echo "Removed ${LAUNCHER}"
fi
