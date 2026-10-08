#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu workstation maintenance.
# Conservative by design:
#   - normal APT upgrades are installed automatically
#   - Ubuntu phasing is respected unless explicitly overridden by the user
#   - full upgrades are simulated first and require explicit confirmation
#   - package removals require stronger confirmation
#   - firmware, autoremove, and NVIDIA branch changes require confirmation
#   - daily logs are retained for 90 days under <script-folder>/logs/update-system/

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REBOOT_RECOMMENDED=0
PHASED_OPTION="APT::Get::Always-Include-Phased-Updates=true"
MIN_ROOT_FREE_KIB=$((2 * 1024 * 1024)) # 2 GiB

simulate_to_file() {
    local output_file="$1"
    shift

    "$@" > "$output_file" 2>&1
}

check_apt_locks() {
    local lock

    for lock in \
        /var/lib/dpkg/lock-frontend \
        /var/lib/dpkg/lock \
        /var/lib/apt/lists/lock \
        /var/cache/apt/archives/lock; do

        [[ -e "$lock" ]] || continue

        if as_root fuser "$lock" >/dev/null 2>&1; then
            error "Another package-management process is using ${lock}."
            error "Wait for App Center, Software Updater, or unattended upgrades to finish."
            return 1
        fi
    done

    success "No conflicting package-management process was detected."
}

check_disk_space() {
    local available_kib
    local available_human

    available_kib="$(df --output=avail -k / | awk 'NR == 2 {print $1}')"
    available_human="$(df -h / | awk 'NR == 2 {print $4}')"

    info "Root filesystem free space: ${available_human}"

    if [[ "$available_kib" =~ ^[0-9]+$ ]] &&
       (( available_kib < MIN_ROOT_FREE_KIB )); then
        error "Less than 2 GiB is free on the root filesystem."
        return 1
    fi

    success "Disk-space check passed."
}

check_dpkg_state() {
    local audit_file="${TMP_DIR}/dpkg-audit.txt"

    info "Checking dpkg state..."
    dpkg --audit > "$audit_file" 2>&1 || true

    if [[ ! -s "$audit_file" ]]; then
        success "dpkg reports no interrupted or partially configured packages."
        return 0
    fi

    warn_condition "dpkg reports packages that may need attention:"
    cat "$audit_file" | tee -a "$LOG_FILE"

    if confirm "Run 'sudo dpkg --configure -a' now?"; then
        run_root dpkg --configure -a
        dpkg --audit > "$audit_file" 2>&1 || true

        if [[ -s "$audit_file" ]]; then
            cat "$audit_file" | tee -a "$LOG_FILE"
            error "dpkg still reports an unhealthy package state."
            return 1
        fi

        success "dpkg state is healthy after repair."
    else
        error "Stopping before upgrades because dpkg is not in a clean state."
        return 1
    fi
}

check_apt_health() {
    local phase="${1:-current}"

    info "Checking APT dependency health (${phase})..."

    if as_root apt-get check 2>&1 | tee -a "$LOG_FILE"; then
        success "APT dependency check passed (${phase})."
        return 0
    fi

    warn_condition "APT reported dependency problems (${phase})."

    if confirm "Run 'apt-get --fix-broken install' now?"; then
        run_root apt-get --fix-broken install

        if as_root apt-get check 2>&1 | tee -a "$LOG_FILE"; then
            success "APT dependency health was repaired."
            return 0
        fi

        error "APT dependency problems remain after repair."
        return 1
    fi

    error "Stopping because APT dependency health is not clean."
    return 1
}

report_manual_holds() {
    local holds_file="${TMP_DIR}/holds.txt"

    apt-mark showhold 2>/dev/null | sort -u > "$holds_file" || true

    if [[ ! -s "$holds_file" ]]; then
        success "No manually held APT packages are configured."
        return 0
    fi

    info "Manually held APT packages:"
    while IFS= read -r package; do
        [[ -n "$package" ]] && print_and_log "  - ${package}"
    done < "$holds_file"
}

update_apt() {
    info "Updating APT package indexes..."
    run_root apt-get update

    info "Installing normal updates while respecting Ubuntu phasing..."
    run_root apt-get upgrade -y --with-new-pkgs --no-remove
}

extract_inst_packages() {
    awk '/^Inst / {print $2}' "$1" | sort -u
}

extract_remv_packages() {
    awk '/^Remv / {print $2}' "$1" | sort -u
}

handle_phased_updates() {
    local sim_file="${TMP_DIR}/phased-upgrade.sim"
    local count

    info "Checking for phased/deferred updates..."

    if ! simulate_to_file "$sim_file" \
        apt-get --simulate upgrade \
        --with-new-pkgs \
        --no-remove \
        -o "$PHASED_OPTION"; then
        cat "$sim_file" >> "$LOG_FILE"
        warn_condition "Could not simulate phased updates; continuing without overriding phasing."
        return 0
    fi

    count="$(extract_inst_packages "$sim_file" | wc -l)"

    if (( count == 0 )); then
        success "No updates become installable by overriding Ubuntu phasing."
        return 0
    fi

    warn_condition "${count} update(s) become installable when Ubuntu phasing is overridden:"
    while IFS= read -r package; do
        [[ -n "$package" ]] && print_and_log "  - ${package}"
    done < <(extract_inst_packages "$sim_file")

    warn_note "Installing these now bypasses Ubuntu's gradual rollout. The default is to leave them deferred."

    if confirm "Install these phased/deferred updates now?"; then
        run_root apt-get upgrade \
            -y \
            --with-new-pkgs \
            --no-remove \
            -o "$PHASED_OPTION"
    else
        info "Phased/deferred updates were left for Ubuntu's normal rollout."
    fi
}

handle_full_upgrade() {
    local sim_file="${TMP_DIR}/full-upgrade.sim"
    local install_count
    local remove_count

    info "Simulating a full upgrade..."

    if ! simulate_to_file "$sim_file" apt-get --simulate dist-upgrade; then
        cat "$sim_file" >> "$LOG_FILE"
        warn_condition "Could not simulate a full upgrade; no full upgrade will be attempted."
        return 0
    fi

    install_count="$(extract_inst_packages "$sim_file" | wc -l)"
    remove_count="$(extract_remv_packages "$sim_file" | wc -l)"

    if (( install_count == 0 && remove_count == 0 )); then
        success "No full-upgrade operation is needed."
        return 0
    fi

    warn_condition "Full upgrade proposes ${install_count} install/upgrade(s) and ${remove_count} removal(s)."

    if (( install_count > 0 )); then
        info "Packages a full upgrade would install or upgrade:"
        while IFS= read -r package; do
            [[ -n "$package" ]] && print_and_log "  + ${package}"
        done < <(extract_inst_packages "$sim_file")
    fi

    if (( remove_count > 0 )); then
        warn_note "Packages a full upgrade would REMOVE:"
        while IFS= read -r package; do
            [[ -n "$package" ]] && print_and_log "  - ${package}"
        done < <(extract_remv_packages "$sim_file")

        warn_note "Because removals are proposed, this action requires stronger confirmation."
        if confirm_phrase "Apply this full upgrade?" "APPLY"; then
            run_root apt-get dist-upgrade -y
        else
            info "Full upgrade was skipped."
        fi
        return 0
    fi

    if confirm "Apply this full upgrade?"; then
        run_root apt-get dist-upgrade -y
    else
        info "Full upgrade was skipped."
    fi
}

list_upgradable_packages() {
    apt list --upgradable 2>/dev/null |
        awk -F/ 'NR > 1 && $1 != "" {print $1}' |
        sort -u
}

package_installed_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || printf '%s' 'not-installed'
}

package_candidate_version() {
    local candidate
    candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    printf '%s' "${candidate:-unknown}"
}

audit_remaining_apt_updates() {
    local pending_file="${TMP_DIR}/pending-upgrades.txt"
    local holds_file="${TMP_DIR}/pending-holds.txt"
    local phased_file="${TMP_DIR}/pending-phased.sim"
    local full_file="${TMP_DIR}/pending-full.sim"
    local phased_packages="${TMP_DIR}/pending-phased-packages.txt"
    local full_packages="${TMP_DIR}/pending-full-packages.txt"
    local count=0
    local unresolved_count=0
    local package
    local reason
    local installed
    local candidate

    info "Auditing packages that remain upgradable after APT maintenance..."

    list_upgradable_packages > "$pending_file" || true

    if [[ ! -s "$pending_file" ]]; then
        success "No APT packages remain upgradable."
        return 0
    fi

    apt-mark showhold 2>/dev/null | sort -u > "$holds_file" || true

    if simulate_to_file "$phased_file" \
        apt-get --simulate upgrade \
        --with-new-pkgs \
        --no-remove \
        -o "$PHASED_OPTION"; then
        extract_inst_packages "$phased_file" > "$phased_packages"
    else
        : > "$phased_packages"
    fi

    if simulate_to_file "$full_file" apt-get --simulate dist-upgrade; then
        extract_inst_packages "$full_file" > "$full_packages"
    else
        : > "$full_packages"
    fi

    count="$(wc -l < "$pending_file")"
    warn_condition "${count} APT package(s) still have a newer candidate version after maintenance:"

    while IFS= read -r package; do
        [[ -n "$package" ]] || continue

        if grep -Fxq -- "$package" "$holds_file"; then
            reason="manual APT hold"
        elif grep -Fxq -- "$package" "$phased_packages"; then
            reason="Ubuntu phased/deferred rollout"
        elif grep -Fxq -- "$package" "$full_packages"; then
            reason="requires a full-upgrade transaction that was not applied"
        else
            reason="candidate exists but APT cannot currently schedule it"
            unresolved_count=$((unresolved_count + 1))
        fi

        installed="$(package_installed_version "$package")"
        candidate="$(package_candidate_version "$package")"
        print_and_log "  - ${package}: ${installed} -> ${candidate} [${reason}]"
    done < "$pending_file"

    if (( unresolved_count > 0 )); then
        warn_note "${unresolved_count} package(s) are not installable even by the current full-upgrade simulation."
        warn_note "This commonly indicates a temporary repository/dependency transition. Do not force-install them unless you first inspect their dependency plan."
    fi
}

nvidia_branch() {
    local text="$1"

    if [[ "$text" =~ ([0-9]{3}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi

    return 0
}

active_nvidia_version() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0

    nvidia-smi \
        --query-gpu=driver_version \
        --format=csv,noheader \
        2>/dev/null |
        head -n 1 |
        tr -d '[:space:]' || true
}

recommended_nvidia_package() {
    command -v ubuntu-drivers >/dev/null 2>&1 || return 0

    ubuntu-drivers devices 2>/dev/null |
        awk '
            /recommended/ {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^nvidia-driver-[0-9]+(-open|-server|-server-open)?$/) {
                        print $i
                        exit
                    }
                }
            }
        ' || true
}

package_is_installed() {
    [[ "$(
        dpkg-query -W \
            -f='${db:Status-Abbrev}' \
            "$1" \
            2>/dev/null || true
    )" == ii* ]]
}

install_recommended_nvidia_driver() {
    if ubuntu-drivers install --help >/dev/null 2>&1; then
        run_root ubuntu-drivers install
        REBOOT_RECOMMENDED=1
    else
        warn_condition "This ubuntu-drivers version does not provide the 'install' command."
    fi
}

handle_nvidia() {
    local active_version
    local active_branch
    local recommended_package
    local recommended_branch
    local installed_version
    local candidate_version

    if ! command -v ubuntu-drivers >/dev/null 2>&1; then
        info "ubuntu-drivers is unavailable; skipping NVIDIA recommendation checks."
        return 0
    fi

    info "Checking NVIDIA driver recommendation..."
    info "Running kernel: $(uname -r)"

    active_version="$(active_nvidia_version)"
    active_branch="$(nvidia_branch "$active_version")"
    recommended_package="$(recommended_nvidia_package)"
    recommended_branch="$(nvidia_branch "$recommended_package")"

    if [[ -n "$active_version" ]]; then
        info "Active NVIDIA driver version: ${active_version}"
    else
        warn_condition "The active NVIDIA driver could not be queried with nvidia-smi."
    fi

    if [[ -z "$recommended_package" ]]; then
        info "Ubuntu did not report a recommended NVIDIA package."
        return 0
    fi

    info "Ubuntu-recommended NVIDIA package: ${recommended_package}"

    installed_version="$(package_installed_version "$recommended_package")"
    candidate_version="$(package_candidate_version "$recommended_package")"
    info "Recommended package version: installed=${installed_version}, candidate=${candidate_version}"

    if [[ -n "$active_branch" && "$active_branch" == "$recommended_branch" ]]; then
        success "The active NVIDIA branch matches Ubuntu's recommendation."
        return 0
    fi

    if package_is_installed "$recommended_package"; then
        success "The recommended NVIDIA package is already installed."
        warn_condition "It is not currently active; reboot before attempting a reinstall."
        REBOOT_RECOMMENDED=1
        return 0
    fi

    warn_condition "The active/installed NVIDIA driver branch does not match Ubuntu's recommendation."

    if confirm "Install Ubuntu's recommended NVIDIA driver now?"; then
        install_recommended_nvidia_driver
    else
        info "NVIDIA driver installation was skipped."
    fi
}

handle_firmware() {
    local output
    local exit_code

    if ! command -v fwupdmgr >/dev/null 2>&1; then
        info "fwupd is not installed; skipping firmware checks."
        return 0
    fi

    info "Refreshing firmware metadata..."

    if output="$(fwupdmgr refresh 2>&1)"; then
        exit_code=0
    else
        exit_code=$?
    fi

    printf '%s\n' "$output" | tee -a "$LOG_FILE"

    case "$exit_code" in
        0) success "Firmware metadata refreshed." ;;
        2) success "Firmware metadata is already up to date." ;;
        *) warn_condition "Firmware metadata refresh failed with exit code ${exit_code}; continuing." ;;
    esac

    info "Checking for firmware updates..."

    if output="$(fwupdmgr get-updates 2>&1)"; then
        exit_code=0
    else
        exit_code=$?
    fi

    printf '%s\n' "$output" | tee -a "$LOG_FILE"

    case "$exit_code" in
        0)
            warn_condition "Firmware updates are available. Connect the laptop to AC power before applying them."

            if confirm "Install available firmware updates now?"; then
                if output="$(as_root fwupdmgr update 2>&1)"; then
                    exit_code=0
                else
                    exit_code=$?
                fi

                printf '%s\n' "$output" | tee -a "$LOG_FILE"

                case "$exit_code" in
                    0)
                        success "Firmware update command completed."
                        REBOOT_RECOMMENDED=1
                        ;;
                    2)
                        success "No firmware action was needed."
                        ;;
                    3)
                        warn_condition "Firmware resource was not found."
                        ;;
                    *)
                        warn_condition "Firmware update failed with exit code ${exit_code}."
                        ;;
                esac
            else
                info "Firmware updates were skipped."
            fi
            ;;
        2)
            success "No supported firmware updates are available."
            ;;
        3)
            info "No supported firmware update resource was found."
            ;;
        *)
            warn_condition "Firmware update check failed with exit code ${exit_code}; continuing."
            ;;
    esac
}

handle_autoremove() {
    local sim_file="${TMP_DIR}/autoremove.sim"
    local packages_file="${TMP_DIR}/autoremove-packages.txt"
    local remove_count

    info "Checking for unused automatically installed packages..."

    if ! simulate_to_file "$sim_file" apt-get --simulate autoremove --purge; then
        cat "$sim_file" >> "$LOG_FILE"
        warn_condition "Could not simulate autoremove; continuing without removing packages."
        return 0
    fi

    extract_remv_packages "$sim_file" > "$packages_file"
    remove_count="$(wc -l < "$packages_file")"

    if (( remove_count == 0 )); then
        success "No unused APT packages need removal."
        return 0
    fi

    warn_condition "${remove_count} unused package(s) can be removed:"
    while IFS= read -r package; do
        [[ -n "$package" ]] && print_and_log "  - ${package}"
    done < "$packages_file"

    if grep -Eq '^(linux-(image|headers|modules)|nvidia-)' "$packages_file"; then
        warn_note "The autoremove proposal contains kernel and/or NVIDIA packages. Review the list carefully before approving it."
    fi

    if confirm "Run APT autoremove with purge now?"; then
        run_root apt-get autoremove -y --purge
    else
        info "APT autoremove was skipped."
    fi
}

update_other_packages() {
    info "Removing obsolete cached APT packages..."
    run_root apt-get autoclean -y

    if command -v flatpak >/dev/null 2>&1; then
        info "Updating Flatpak applications and runtimes..."
        run flatpak update -y

        info "Removing unused Flatpak runtimes..."
        run flatpak uninstall --unused -y
    else
        info "Flatpak is not installed; skipping."
    fi

    if command -v snap >/dev/null 2>&1; then
        info "Refreshing Snap packages..."
        run_root snap refresh
    else
        info "Snap is not installed; skipping."
    fi
}

reboot_is_required() {
    [[ -f /run/reboot-required || -f /var/run/reboot-required ]]
}

show_status() {
    info "Running kernel: $(uname -r)"

    if package_is_installed unattended-upgrades &&
       systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
        success "unattended-upgrades is installed and the APT daily-upgrade timer is enabled."
    else
        warn_condition "Automatic APT security-update scheduling could not be confirmed."
    fi

    if reboot_is_required; then
        warn_condition "Ubuntu reports that a reboot is required."
        REBOOT_RECOMMENDED=1
    else
        success "Ubuntu does not currently require a reboot."
    fi

    info "Hybrid GPU status:"

    if command -v prime-select >/dev/null 2>&1; then
        info "PRIME profile: $(prime-select query 2>/dev/null || echo unknown)"
    fi

    if command -v glxinfo >/dev/null 2>&1; then
        local renderer

        renderer="$(
            glxinfo 2>/dev/null |
                awk -F': ' '/OpenGL renderer string/ {print $2; exit}' || true
        )"

        if [[ -n "$renderer" ]]; then
            info "Desktop renderer: ${renderer}"
        fi
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu

        gpu="$(
            nvidia-smi \
                --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total \
                --format=csv,noheader \
                2>/dev/null || true
        )"

        if [[ -n "$gpu" ]]; then
            info "NVIDIA: ${gpu}"
        else
            warn_condition "nvidia-smi could not query the NVIDIA GPU."
        fi
    fi
}

offer_reboot() {
    (( REBOOT_RECOMMENDED == 1 )) || return 0

    if confirm "Restart the computer now?"; then
        info "Requesting restart in 5 seconds..."
        sleep 5
        if run_root reboot; then
            success "Restart request accepted."
        else
            local exit_code=$?
            error "Restart request failed (exit code ${exit_code}). See the reason above and in ${LOG_FILE}."
            return "$exit_code"
        fi
    else
        info "Reboot skipped. Restart later to complete pending changes."
    fi
}

main() {
    initialize_runtime "$SCRIPT_DIR" update-system 'Ubuntu system maintenance'
    require_commands \
        apt apt-cache apt-get apt-mark awk df dpkg dpkg-query \
        fuser grep head mktemp sed sort systemctl tee tr uname
    create_temp_dir
    require_sudo
    check_apt_locks
    check_disk_space
    check_dpkg_state
    check_apt_health "before upgrades"
    report_manual_holds

    export DEBIAN_FRONTEND=noninteractive

    update_apt
    handle_phased_updates
    handle_full_upgrade
    check_apt_health "after upgrades"
    audit_remaining_apt_updates
    handle_nvidia
    handle_firmware
    handle_autoremove
    update_other_packages
    show_status

    show_completion_summary
    offer_reboot
}

main "$@"
