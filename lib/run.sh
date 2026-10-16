#!/usr/bin/env bash
set -Eeuo pipefail

# Runs one module action in its own process: run.sh MODULE ACTION. Called by maint after it
# validated both names, so only lib/common.sh and that module share this namespace.

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=/dev/null
source "${MAINT_ROOT}/modules/$1.sh"

initialize_runtime "$1" "${MODULE_TITLE} $2"
"action_$2"
show_completion_summary
