#!/bin/bash
# ═══════════════════════════════════════════════════════════
# P2P Wi-Fi Direct Setup
# Supported Devices: NXP i.MX8M | Jetson Nano | RPi (Zero 2W, 2/3/4/5)
#
# Kullanım:
#   ./setup.sh                    → interaktif mod
#   ./setup.sh --role host --device nxp
#   ./setup.sh --role client --device rpi
#   ./setup.sh --role client --device jetson
#   ./setup.sh --uninstall        → uninstall mod
# ═══════════════════════════════════════════════════════════
set -euo pipefail

# ── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Constants ─────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_CONF_DIR="/etc/wpa_supplicant"
INSTALL_ENV_FILE="/etc/default/video-node"
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_SYSTEMD_DIR="/etc/systemd/system"

# ── Helpers ──────────────────────────────────────────────
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
header()  { echo -e "\n${BOLD}${CYAN}$1${NC}\n$(printf '─%.0s' {1..55})"; }
die()     { error "$1"; exit 1; }

# Arguments
ROLE=""
DEVICE=""
UNINSTALL=false

# ── Argument Parsing ──────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role) ROLE="$2"; shift 2 ;;
            --device) DEVICE="$2"; shift 2 ;;
            --uninstall) UNINSTALL=true; shift ;;
            -h| --help) show_help; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

show_help() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0                    → interactive mode"
    echo "  $0 --role host --device nxp"
    echo "  $0 --role client --device rpi"
    echo "  $0 --role client --device jetson"
    echo "  $0 --uninstall        → uninstall mode"
    echo ""
    echo "Roles: host | client"
    echo "Devices: nxp | jetson | rpi"
}

# ── Root Check ──────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && die "Root privileges are required. Please run with 'sudo ./setup.sh'"
}

# ── Dependency Check ──────────────────────────────────────────────
check_deps() {
    header "Checking Dependencies"
    local missing=()

    for cmd in wpa_supplicant systemctl; do
        if command -v "$cmd" &> /dev/null; then
            log "Found: $cmd"
        else
            warn "Missing: $cmd"
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing Depndencies installing..."
        apt-get update -qq
        apt-get install -y wpasupplicant iw iputils-ping 2>/dev/null || \
        yum install -y wpa_supplicant iw iputils-ping 2>/dev/null || \
        die "Failed to install dependencies. Please install manually: ${missing[*]}"
    fi
}

# ── P2P support check ──────────────────────────────────────────────
check_p2p_support() {
    local iface="$1"
    info "P2P support check for interface: $iface"

    if ! iw dev "$iface" info &>/dev/null; then
        warn "$iface does not exist. Do you want to continue? (y/n)"
        read -r answer
        [[ "$answer" != "y" ]] && die "Aborting setup."
    fi

    if iw phy 2>/dev/null | grep -q "P2P-GO"; then
        log "P2P-Go support detected."
    else
        warn "P2P-Go support not detected. This device may not work as a host."
    fi 
}

# ── 5GHz support check ──────────────────────────────────────────────
check_5ghz_support() {
    local iface="$1"
    if iw phy 2>/dev/null | grep -qE "5[0-9]{3} MHz"; then
        log "5GHz support detected."
    else
        warn "5GHz support not detected. This device may have limited performance."
    fi
}


# ═══════════════════════════════════════════════════════════
# İnteractive mode
# ═══════════════════════════════════════════════════════════
interactive_setup() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║    P2P Wi-Fi Direct Setup v1.0            ║"
    echo "  ║    NXP · Jetson Nano · RPi (Zero 2W, 3/4/5║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"

    # Role selection
    header "Select Role"
    echo "  [1] host    -> Host (Access Point)"
    echo "  [2] client  -> Client (Station)"
    echo ""
    while true; do
        read -rp "  Chose role (1/2): " role_choice
        case "$role_choice" in
            1) ROLE="host"; break ;;
            2) ROLE="client"; break ;;
            *) warn "Please enter 1 or 2." ;;
        esac
    done
    log "Role: $ROLE"


    # Device selection
    header "2. Cihaz Seçimi"
    echo "  [1] nxp    → NXP i.MX8M (AzureWave 88W8997 / mlan0)"
    echo "  [2] jetson → Jetson Nano"
    echo "  [3] rpi    → Raspberry Pi Zero / Zero 2W  (Only 2.4GHz!)"
    echo "  [4] rpi3bp → Raspberry Pi 3B+  (BCM43455 / 5GHz ✅)"
    echo "  [5] rpi4   → Raspberry Pi 4B   (BCM43455 / 5GHz ✅)"
    echo "  [6] rpi5   → Raspberry Pi 5    (CYW43455 / 5GHz ✅)"
    echo ""
    while true; do
        read -rp " Choose device (1-6): " device_choice
        case "$device_choice" in
            1) DEVICE="nxp"; break ;;
            2) DEVICE="jetson"; break ;;
            3) DEVICE="rpi"; break ;;
            4) DEVICE="rpi3bp"; break ;;
            5) DEVICE="rpi4"; break ;;
            6) DEVICE="rpi5"; break ;;
            *) warn "Please enter a number between 1 and 6." ;;
        esac
    done
    log "Device: $DEVICE"


    # ── Scenario check ──────────────────────────────────────────────
    header "Scenario Information"
    echo "  Which device pairs with which role?"
    echo "  [1] Host: NXP i.MX8M(client) ↔ NXP i.MX8M(host)"
    echo "  [2] Host: NXP i.MX8M(client) ↔ Jetson Nano(host)"
    echo "  [3] Host: NXP i.MX8M(client) ↔ RPi (Zero 2W(Only 2.4GHz), 3/4/5)(host)"
    echo "  [4] Host: Jetson Nano(client) ↔ NXP i.MX8M(host)"
    echo "  [5] Host: Jetson Nano(client) ↔ Jetson Nano(host)"
    echo "  [6] Host: Jetson Nano(client) ↔ RPi (Zero 2W(Only 2.4GHz), 3/4/5)(host)"
    echo "  [7] Host: RPi (Zero 2W(Only 2.4GHz), 3/4/5)(client) ↔ NXP i.MX8M(host)"
    echo "  [8] Host: RPi (Zero 2W(Only 2.4GHz), 3/4/5)(client) ↔ Jetson Nano(host)"
    echo "  [9] Host: RPi (Zero 2W(Only 2.4GHz), 3/4/5)(client) ↔ RPi (Zero 2W(Only 2.4GHz), 3/4/5)(host)"
    echo "  [0] Custom scenario (manual configuration)"
    echo ""
    while true; do
        read -rp "  Choose scenario (1-9): " scenario_choice
        case "$scenario_choice" in
            1) SCENARIO="nxp-nxp"; break ;;
            2) SCENARIO="nxp-jetson"; break ;;
            3) SCENARIO="nxp-rpi"; break ;;
            4) SCENARIO="jetson-nxp"; break ;;
            5) SCENARIO="jetson-jetson"; break ;;
            6) SCENARIO="jetson-rpi"; break ;;
            7) SCENARIO="rpi-nxp"; break ;;
            8) SCENARIO="rpi-jetson"; break ;;
            9) SCENARIO="rpi-rpi"; break ;;
            0) SCENARIO="custom"; break ;;
            *) warn "Please enter a number between 0 and 9." ;;
        esac
    done


    # ── Network identification(Optional) ──────────────────────────────────────────────
    header "Network Identification (Optional)"
    read -rp "  SSID [default: P2P-Direct]: " custom_ssid
    P2P_SSID="${custom_ssid:-P2P-Direct}"

    read -rp "  PSK (Password) [default: Str0ngP@ssword!]: " custom_psk
    echo ""
    P2P_PSK="${custom_psk:-Str0ngP@ssword!}"
    if [ ${#P2P_PSK} -lt 8 ]; then
        die "PSK must be at least 8 characters long."
    fi

    log "SSID: $P2P_SSID | PSK: (gizli)" 
}


# ═══════════════════════════════════════════════════════════
# Load Profile and Defining Parameters
# ═══════════════════════════════════════════════════════════
load_device_profile() {
    local profile="$REPO_DIR/device-profiles/${DEVICE}.env"
    [ -f "$profile" ] || die "Device Profile Not Found: $profile"
    source "$profile"
    log "Device profile loaded: $DEVICE"
}


generate_device_names() {
    # Device type + role → the name this device will publish in wpa_supplicant
    # Only 
    local prefix
    case "$DEVICE_TYPE" in
        nxp)    prefix="NXP"    ;;
        jetson) prefix="JETSON" ;;
        rpi)    prefix="RPI"    ;;
        rpi3bp) prefix="RPI3BP" ;;
        rpi4)   prefix="RPI4"   ;;
        rpi5)   prefix="RPI5"   ;;
        *)      prefix="NODE"   ;;
    esac

    if [ "$ROLE" = "host" ]; then
        P2P_THIS_DEVICE_NAME="${prefix}-HOST"
    else
        P2P_THIS_DEVICE_NAME="${prefix}-CLIENT"
    fi

    # fill both placeholder for  apply_conf 
    P2P_HOST_DEVICE_NAME="${prefix}-HOST"
    P2P_CLIENT_DEVICE_NAME="${prefix}-CLIENT"

    log "This Device Name: $P2P_THIS_DEVICE_NAME"
}

determine_frequency() {
    header "Determining Frequency Band"

    case "$SCENARIO" in
        nxp_rpi | jetson_rpi | rpi_nxp | rpi_jetson | rpi_rpi)
            #Rpi Zero 2W only supports 2.4GHz, so if it's in the scenario, we must use 2.4GHz
            if [[ "$DEVICE_TYPE" == "rpi" ]]; then
                P2P_CHANNEL="$P2P_CHANNEL_24"
                P2P_FREQ="$P2P_FREQ_24"
                P2P_REG_CLASS="$P2P_REG_CLASS_24"
            else 
                P2P_CHANNEL="$P2P_CHANNEL_5"
                P2P_FREQ="$P2P_FREQ_5"
                P2P_REG_CLASS="$P2P_REG_CLASS_5"
            fi
            ;;
        custom)
            echo "  [1] 5GHz - Channel 44 (5220 MHz) - Suggested"
            echo "  [2] 5GHz - Channel 36 (5180 MHz)"
            echo "  [3] 5GHz - Channel 149 (5745 MHz)"
            echo "  [4] 2.4GHz - Channel 6 (2437"
            read -rp "  Choose frequency (1-4):  f_choice"
            case "$f_choice" in
                1) P2P_CHANNEL=44; P2P_FREQ=5220; P2P_REG_CLASS=115 ;;
                2) P2P_CHANNEL=36; P2P_FREQ=5180; P2P_REG_CLASS=115 ;;
                3) P2P_CHANNEL=149; P2P_FREQ=5745; P2P_REG_CLASS=115 ;;
                4) P2P_CHANNEL=6; P2P_FREQ=2437; P2P_REG_CLASS=81 ;;
                *) P2P_CHANNEL=44; P2P_FREQ=5220; P2P_REG_CLASS=115 ;;
            esac
            ;;
        *)
            if [ "$SUPPORTS_5GHZ" = "true" ]; then
                log "5GHz using: Ch:$P2P_CHANNEL} ($P2P_FREQ MHz)"
            else
                P2P_CHANNEL="$P2P_CHANNEL_24"
                P2P_FREQ="$P2P_FREQ_24"
                P2P_REG_CLASS="$P2P_REG_CLASS_24"
                warn "5GHz not supported, falling back to 2.4GHz: Ch:$P2P_CHANNEL ($P2P_FREQ MHz)"
            fi
             ;;
        esac
}

# ═══════════════════════════════════════════════════════════
#  Install Files
# ═══════════════════════════════════════════════════════════
install_files() {
    header "Installing Configuration and Service Files"

    # ──  /etc/default/video-node  ───────────────────────────────────────────────
    local env_content
    env_content=$(cat "$REPO_DIR/config/video-node.env.template")
    env_content="${env_content//__ROLE__/$ROLE}"
    env_content="${env_content//__DEVICE__/$DEVICE_TYPE}"
    env_content="${env_content//__IFACE__/$P2P_IFACE}"
    env_content="${env_content//__CHANNEL__/$P2P_CHANNEL}"
    env_content="${env_content//__FREQ__/$P2P_FREQ}"
    env_content="${env_content//__REG_CLASS__/$P2P_REG_CLASS}"
    env_content="${env_content//__UBOOT__/$UBOOT_ENV_SUPPORT}"



    echo "$env_content" > "$INSTALL_ENV_FILE"
    # Update SSID and PSK
    sed -i "s|P2P_SSID=.*|P2P_SSID=\"${P2P_SSID:-DIRECT-NXPStream}\"|" "$INSTALL_ENV_FILE"
    sed -i "s|P2P_PSK=.*|P2P_PSK=\"${P2P_PSK:-Str0ngP@ssw0rd!}\"|" "$INSTALL_ENV_FILE"
    log "Configuration: $INSTALL_ENV_FILE"

    # ── wpa_supplicant confs ─────────────────────────────
    mkdir -p "$INSTALL_CONF_DIR"

    local apply_conf() { # inline func
        local src="$1" dst="$2"
        sed \
            -e "s/__CHANNEL__/$P2P_CHANNEL/g" \
            -e "s/__REG_CLASS__/$P2P_REG_CLASS/g" \
            -e "s/__FREQ__/$P2P_FREQ/g" \
            -e "s/__SSID__/${P2P_SSID:-DIRECT-NXPStream}/g" \
            -e "s/__PSK__/${P2P_PSK:-Str0ngP@ssw0rd!}/g" \
            "$src" > "$dst"
    }

    apply_conf "$REPO_DIR/config/p2p-host.conf"   "$INSTALL_CONF_DIR/p2p-host.conf"
    apply_conf "$REPO_DIR/config/p2p-client.conf" "$INSTALL_CONF_DIR/p2p-client.conf"
    log "wpa_supplicant conf: $INSTALL_CONF_DIR/p2p-{host,client}.conf"

    # ── Scripts  ────────────────────────────────────────────
    cp "$REPO_DIR/scripts/p2p-init.sh"     "$INSTALL_BIN_DIR/p2p-init.sh"
    cp "$REPO_DIR/scripts/p2p-watchdog.sh" "$INSTALL_BIN_DIR/p2p-watchdog.sh"
    chmod +x "$INSTALL_BIN_DIR/p2p-init.sh"
    chmod +x "$INSTALL_BIN_DIR/p2p-watchdog.sh"
    log "Scripts: $INSTALL_BIN_DIR/p2p-{init,watchdog}.sh"

    # ── Systemd ──────────────────────────────────────────────
    cp "$REPO_DIR/systemd/p2p-init.service"     "$INSTALL_SYSTEMD_DIR/"
    cp "$REPO_DIR/systemd/p2p-watchdog.service" "$INSTALL_SYSTEMD_DIR/"
    systemctl daemon-reload
    systemctl enable p2p-init.service
    systemctl enable p2p-watchdog.service
    log "Systemd services installed and enabled."
}


# ═══════════════════════════════════════════════════════════
# U-Boot env writer (NXP)
# ═══════════════════════════════════════════════════════════
write_uboot_env() {
    [ "$UBOOT_ENV_SUPPORT" != "true" ] && return
    command -v fw_setenv &>/dev/null || { warn "fw_setenv couldn't be found, U-Boot env not written."; return; }

    header "U-Boot Environment writing"
    fw_setenv node_role     "$ROLE"
    fw_setenv p2p_iface     "$P2P_IFACE"
    fw_setenv p2p_channel   "$P2P_CHANNEL"
    fw_setenv p2p_freq      "$P2P_FREQ"
    fw_setenv p2p_reg_class "$P2P_REG_CLASS"
    log "U-Boot env updated"
    info "Check: fw_printenv node_role p2p_iface p2p_channel p2p_freq p2p_reg_class"
}



# ═══════════════════════════════════════════════════════════
# Uninstall Function
# ═══════════════════════════════════════════════════════════
uninstall() {
    header "Uninstalling"
    warn "All P2P components will be removed!"
    read -rp "Are you sure? (y/n): " ans
    [ "$ans" != "y" ] && { info "Cancelled."; exit 0; }

    systemctl stop p2p-watchdog.service 2>/dev/null || true
    systemctl stop p2p-init.service 2>/dev/null || true
    systemctl disable p2p-watchdog.service 2>/dev/null || true
    systemctl disable p2p-init.service 2>/dev/null || true

    rm -f "$INSTALL_SYSTEMD_DIR/p2p-init.service"
    rm -f "$INSTALL_SYSTEMD_DIR/p2p-watchdog.service"
    rm -f "$INSTALL_BIN_DIR/p2p-init.sh"
    rm -f "$INSTALL_BIN_DIR/p2p-watchdog.sh"
    rm -f "$INSTALL_CONF_DIR/p2p-host.conf"
    rm -f "$INSTALL_CONF_DIR/p2p-client.conf"
    rm -f "$INSTALL_ENV_FILE"
    rm -f "/run/p2p-connected"

    systemctl daemon-reload
    log "All P2P components removed."
    exit 0
}



# ═══════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════
print_summary() {
    header "Installation Complete"
    echo -e "  ${BOLD}Role:${NC}       $ROLE"
    echo -e "  ${BOLD}Device:${NC}     $DEVICE_TYPE"
    echo -e "  ${BOLD}Interface:${NC}    $P2P_IFACE"
    echo -e "  ${BOLD}Frequency:${NC}   ${P2P_FREQ}MHz (Channel ${P2P_CHANNEL})"
    echo -e "  ${BOLD}SSID:${NC}      ${P2P_SSID:-DIRECT-NXPStream}"
    echo -e "  ${BOLD}Host IP:${NC}   192.168.77.1"
    echo -e "  ${BOLD}Client IP:${NC} 192.168.77.2"
    echo ""
    echo -e "  ${CYAN}To start:${NC}"
    echo "    systemctl start p2p-init.service"
    echo "    systemctl start p2p-watchdog.service"
    echo ""
    echo -e "  ${CYAN}To monitor logs:${NC}"
    echo "    journalctl -fu p2p-init.service"
    echo "    journalctl -fu p2p-watchdog.service"
    echo ""
    echo -e "  ${CYAN}Connection status:${NC}"
    echo "    ls /run/p2p-connected   # file exists if connected"
    echo "    wpa_cli -i $P2P_IFACE status"
    echo ""
}



# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════
main() {
    parse_args "$@"
    check_root

    if [ "$UNINSTALL" = true ]; then
        uninstall
    fi

    # SSID/PSK default values (non-interaktif modda)
    P2P_SSID="${P2P_SSID:-DIRECT-NXPStream}"
    P2P_PSK="${P2P_PSK:-Str0ngP@ssw0rd!}"
    SCENARIO="${SCENARIO:-default}"

    # If any missing arguments, fallback to interactive setup 
    if [ -z "$ROLE" ] || [ -z "$DEVICE" ]; then
        interactive_setup
    else
        # Non-interaktif: comes from args, decide scenario automatically
        case "${ROLE}-${DEVICE}" in
            host-nxp|client-jetson)  SCENARIO="nxp_jetson" ;;
            host-nxp|client-rpi)     SCENARIO="nxp_rpi" ;;
            host-nxp|client-nxp)     SCENARIO="nxp_nxp" ;;
            host-jetson|client-nxp) SCENARIO="jetson_nxp" ;;
            host-jetson|client-jetson) SCENARIO="jetson_jetson" ;;
            host-jetson|client-rpi)     SCENARIO="jetson_rpi" ;;
            host-rpi|client-nxp)     SCENARIO="rpi_nxp" ;;
            host-rpi|client-jetson) SCENARIO="rpi_jetson" ;;
            host-rpi|client-rpi)    SCENARIO="rpi_rpi" ;;
            *) SCENARIO="custom" ;;
        esac
        info "Argüman modu: rol=$ROLE, cihaz=$DEVICE"
    fi

    check_deps
    load_device_profile
    generate_device_names
    determine_frequency
    check_p2p_support "$P2P_IFACE"
    install_files
    write_uboot_env
    print_summary
}

# inline func tanımı için bash 4.x uyumluluk
apply_conf() {
    local src="$1" dst="$2"
    sed \
        -e "s/__CHANNEL__/$P2P_CHANNEL/g" \
        -e "s/__REG_CLASS__/$P2P_REG_CLASS/g" \
        -e "s/__FREQ__/$P2P_FREQ/g" \
        -e "s|__SSID__|${P2P_SSID:-DIRECT-NXPStream}|g" \
        -e "s|__PSK__|${P2P_PSK:-Str0ngP@ssw0rd!}|g" \
        -e "s/__HOST_DEVICE_NAME__/${P2P_HOST_DEVICE_NAME:-P2P-HOST-NODE}/g" \
        -e "s/__CLIENT_DEVICE_NAME__/${P2P_CLIENT_DEVICE_NAME:-P2P-CLIENT-NODE}/g" \
        "$src" > "$dst"
}

main "$@"
