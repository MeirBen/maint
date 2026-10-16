#!/usr/bin/env bash
set -Eeuo pipefail

# Installs the `maintenance` command and its desktop launcher. Re-run after moving this folder.
# Run as your own user: sudo is requested only to link the command into /usr/local/bin.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$(xdg-user-dir DESKTOP)/Maintenance.desktop"

if (( EUID == 0 )); then
    echo 'Run install.sh as your own user, without sudo.' >&2
    exit 1
fi

sudo ln -sfnT -- "${ROOT}/maintenance.sh" /usr/local/bin/maintenance

cat > "$LAUNCHER" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Maintenance
Comment=Ubuntu updates, drivers, firmware, and Local AI controls
Exec=/usr/local/bin/maintenance
Icon=${ROOT}/icons/maintenance.png
Terminal=true
Categories=System;
Keywords=update;upgrade;maintenance;drivers;firmware;cleanup;ai;
StartupNotify=true
EOF
chmod 755 "$LAUNCHER"
# GNOME launches desktop files only once they are marked trusted.
gio set -- "$LAUNCHER" metadata::trusted true

echo "Installed /usr/local/bin/maintenance and ${LAUNCHER}"
