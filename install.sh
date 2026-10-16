#!/usr/bin/env bash
set -Eeuo pipefail

# Installs the `maint` command, its Tab completion, and the Maintenance desktop launcher.
# Re-run after moving this folder. Run as your own user: sudo is requested only for /usr/local/bin.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMAND=/usr/local/bin/maint
COMPLETION="${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions/maint"
LAUNCHER="$(xdg-user-dir DESKTOP)/Maintenance.desktop"

if (( EUID == 0 )); then
    echo 'Run install.sh as your own user, without sudo.' >&2
    exit 1
fi

sudo ln -sfnT -- "${ROOT}/maint" "$COMMAND"

mkdir -p -- "${COMPLETION%/*}"
ln -sfnT -- "${ROOT}/completion.bash" "$COMPLETION"

cat > "$LAUNCHER" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Maintenance
Comment=Ubuntu updates, drivers, firmware, and Local AI controls
Exec=${COMMAND}
Icon=${ROOT}/icons/maint.png
Terminal=true
Categories=System;
Keywords=maint;update;upgrade;maintenance;drivers;firmware;cleanup;ai;
StartupNotify=true
EOF
chmod 755 "$LAUNCHER"
# GNOME launches desktop files only once they are marked trusted.
gio set -- "$LAUNCHER" metadata::trusted true

echo "Installed ${COMMAND}, Tab completion, and the Maintenance desktop launcher."
echo "Open a new terminal for Tab completion, then run: maint help"
