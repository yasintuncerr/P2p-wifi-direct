#!/bin/bash
# ═══════════════════════════════════════════════════════════
# P2P Wi-Fi Direct Setup
# Supported: NXP i.MX8M | Jetson Nano | RPi (Zero 2W, 3B+, 4B, 5)
#
# Usage:
#   sudo ./setup.sh                          → interactive
#   sudo ./setup.sh --role host --device nxp
#   sudo ./setup.sh --role client --device rpi
#   sudo ./setup.sh --role host --device rpi4 --freq 2.4
#   sudo ./setup.sh --uninstall
# ═══════════════════════════════════════════════════════════
set -euo pipefail

# ── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Constants ──────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_CONF_DIR="/etc/wpa_supplicant"
INSTALL_ENV_FILE="/etc/default/video-node"
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_SYSTEMD_DIR="/etc/systemd/system"

# ── Helpers ────────────────────────────────────────────────
log()    { echo -e "${GREEN}[✓]${NC} $1"; }
info()   { echo -e "${BLUE}[i]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}$1${NC}\n$(printf '─%.0s' {1..55})"; }
die()    { error "$1"; exit 1; }

# ── Arguments ──────────────────────────────────────────────
ROLE=""
DEVICE=""
UNINSTALL=false
ARG_SSID=""
ARG_PSK=""
ARG_FREQ=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)      ROLE="$2";     shift 2 ;;
            --device)    DEVICE="$2";   shift 2 ;;
            --ssid)      ARG_SSID="$2"; shift 2 ;;
            --psk)       ARG_PSK="$2";  shift 2 ;;
            --freq)      ARG_FREQ="$2"; shift 2 ;;
            --uninstall) UNINSTALL=true; shift ;;
            -h|--help)   show_help; exit 0 ;;
            *)           die "Unknown argument: $1" ;;
        esac
    done
}

show_help() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  sudo $0                              → interactive"
    echo "  sudo $0 --role host   --device nxp"
    echo "  sudo $0 --role client --device rpi"
    echo "  sudo $0 --role host   --device rpi4 --freq 2.4"
    echo "  sudo $0 --role host   --device nxp  --ssid MyNet --psk MyPass"
    echo "  sudo $0 --uninstall"
    echo ""
    echo "Roles:   host | client"
    echo "Devices: nxp | jetson | rpi | rpi3bp | rpi4 | rpi5"
    echo "Freq:    5 | 2.4  (5GHz-capable devices only)"
}

# ── Root check ─────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || die "Run with sudo: sudo ./setup.sh"
}

# ── Load defaults from template ────────────────────────────
load_template_defaults() {
    local tmpl="$REPO_DIR/config/video-node.env.template"
    [ -f "$tmpl" ] || die "Template not found: $tmpl"
    DEFAULT_SSID=$(grep "^P2P_SSID=" "$tmpl" | cut -d'"' -f2)
    DEFAULT_PSK=$(grep  "^P2P_PSK="  "$tmpl" | cut -d'"' -f2)
}

# ── Dependency check ───────────────────────────────────────
check_deps() {
    header "Checking Dependencies"
    local missing=()
    for cmd in wpa_supplicant systemctl iw; do
        if command -v "$cmd" &>/dev/null; then
            log "Found: $cmd"
        else
            warn "Missing: $cmd"
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Installing missing dependencies..."
        apt-get update -qq || true
        apt-get install -y wpasupplicant iw iputils-ping 2>/dev/null || \
        yum install -y wpa_supplicant iw iputils-ping 2>/dev/null || \
        die "Could not install: ${missing[*]}"
    fi
}

# ── P2P / AP support check ─────────────────────────────────
check_iface() {
    local iface="$1"
    if ! iw dev "$iface" info &>/dev/null; then
        warn "Interface $iface not found. Continue anyway? (y/n)"
        read -r ans
        [[ "$ans" == "y" ]] || die "Aborting."
    else
        log "Interface $iface found."
    fi
}

# ── Interactive setup ──────────────────────────────────────
interactive_setup() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║   P2P Wi-Fi Direct Setup v2.0               ║"
    echo "  ║   NXP · Jetson Nano · RPi (Zero 2W, 3/4/5)  ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Role
    header "1. Role"
    echo "  [1] host    → Access Point (Group Owner)"
    echo "  [2] client  → Station"
    echo ""
    while true; do
        read -rp "  Choose (1/2): " c
        case "$c" in
            1) ROLE="host";   break ;;
            2) ROLE="client"; break ;;
            *) warn "Enter 1 or 2." ;;
        esac
    done
    log "Role: $ROLE"

    # Device
    header "2. Device"
    echo "  [1] nxp    → NXP i.MX8M  (mlan0 / 5GHz ✅)"
    echo "  [2] jetson → Jetson Nano  (wlan0 / 5GHz ✅)"
    echo "  [3] rpi    → RPi Zero / Zero 2W  (wlan0 / 2.4GHz only ⚠️)"
    echo "  [4] rpi3bp → RPi 3B+  (wlan0 / 5GHz ✅)"
    echo "  [5] rpi4   → RPi 4B   (wlan0 / 5GHz ✅)"
    echo "  [6] rpi5   → RPi 5    (wlan0 / 5GHz ✅)"
    echo ""
    while true; do
        read -rp "  Choose (1-6): " c
        case "$c" in
            1) DEVICE="nxp";    break ;;
            2) DEVICE="jetson"; break ;;
            3) DEVICE="rpi";    break ;;
            4) DEVICE="rpi3bp"; break ;;
            5) DEVICE="rpi4";   break ;;
            6) DEVICE="rpi5";   break ;;
            *) warn "Enter 1-6." ;;
        esac
    done
    log "Device: $DEVICE"

    # Network identity
    header "3. Network Identity (press Enter for defaults)"
    read -rp "  SSID [${DEFAULT_SSID}]: " custom_ssid
    P2P_SSID="${custom_ssid:-$DEFAULT_SSID}"

    read -rp "  PSK  [${DEFAULT_PSK}]: " custom_psk
    echo ""
    P2P_PSK="${custom_psk:-$DEFAULT_PSK}"
    [ ${#P2P_PSK} -lt 8 ] && die "PSK must be at least 8 characters."

    log "SSID: $P2P_SSID | PSK: (hidden)"
}

# ── Load device profile ────────────────────────────────────
load_device_profile() {
    local profile="$REPO_DIR/device-profiles/${DEVICE}.env"
    [ -f "$profile" ] || die "Device profile not found: $profile"
    source "$profile"
    log "Device profile loaded: $DEVICE"
}

# ── Frequency selection ────────────────────────────────────
determine_frequency() {
    header "Frequency"

    if [ "$SUPPORTS_5GHZ" != "true" ]; then
        P2P_CHANNEL="$P2P_CHANNEL_24"
        P2P_FREQ="$P2P_FREQ_24"
        P2P_REG_CLASS="$P2P_REG_CLASS_24"
        warn "Device only supports 2.4GHz → Ch:$P2P_CHANNEL (${P2P_FREQ}MHz)"
        return
    fi

    if [ -n "$ARG_FREQ" ]; then
        case "$ARG_FREQ" in
            5)
                log "5GHz selected: Ch:$P2P_CHANNEL (${P2P_FREQ}MHz)"
                return
                ;;
            2.4)
                P2P_CHANNEL="$P2P_CHANNEL_24"
                P2P_FREQ="$P2P_FREQ_24"
                P2P_REG_CLASS="$P2P_REG_CLASS_24"
                log "2.4GHz selected: Ch:$P2P_CHANNEL (${P2P_FREQ}MHz)"
                return
                ;;
            *)
                warn "Unknown --freq '$ARG_FREQ'. Defaulting to 5GHz."
                return
                ;;
        esac
    fi

    echo "  [1] 5GHz   — Channel 44 (5220 MHz)  ← Recommended"
    echo "  [2] 2.4GHz — Channel 6  (2437 MHz)"
    echo ""
    while true; do
        read -rp "  Choose (1/2): " c
        case "$c" in
            1) log "5GHz: Ch:$P2P_CHANNEL (${P2P_FREQ}MHz)"; break ;;
            2)
                P2P_CHANNEL="$P2P_CHANNEL_24"
                P2P_FREQ="$P2P_FREQ_24"
                P2P_REG_CLASS="$P2P_REG_CLASS_24"
                log "2.4GHz: Ch:$P2P_CHANNEL (${P2P_FREQ}MHz)"
                break
                ;;
            *) warn "Enter 1 or 2." ;;
        esac
    done
}

# ── apply_conf: fill placeholders ─────────────────────────
apply_conf() {
    local src="$1" dst="$2"
    sed \
        -e "s/__CHANNEL__/$P2P_CHANNEL/g" \
        -e "s/__REG_CLASS__/$P2P_REG_CLASS/g" \
        -e "s/__FREQ__/$P2P_FREQ/g" \
        -e "s|__SSID__|${P2P_SSID}|g" \
        -e "s|__PSK__|${P2P_PSK}|g" \
        "$src" > "$dst"
}

# ── Purge existing wpa_supplicant configs ─────────────────
# Prevents the client from connecting to a previously configured
# network (e.g. home Wi-Fi baked into the OS image).
purge_wpa_configs() {
    header "Cleaning Existing wpa_supplicant Configs"

    # Stop wpa_supplicant if running
    if pgrep -x wpa_supplicant > /dev/null; then
        log "Stopping wpa_supplicant..."
        killall wpa_supplicant 2>/dev/null || true
        sleep 1
    fi

    # Remove the system-wide default config (RPi, Ubuntu, Debian all use this)
    if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        warn "Removing /etc/wpa_supplicant/wpa_supplicant.conf"
        rm -f /etc/wpa_supplicant/wpa_supplicant.conf
    fi

    # Remove any per-interface configs (wpa_supplicant-wlan0.conf etc.)
    for f in /etc/wpa_supplicant/wpa_supplicant-*.conf; do
        [ -f "$f" ] || continue
        warn "Removing $f"
        rm -f "$f"
    done

    # Disable wpa_supplicant system service and per-interface variants
    for svc in wpa_supplicant.service "wpa_supplicant@${P2P_IFACE}.service"; do
        if systemctl is-enabled "$svc" &>/dev/null; then
            warn "Disabling $svc"
            systemctl disable "$svc" 2>/dev/null || true
            systemctl stop    "$svc" 2>/dev/null || true
        fi
    done

    # ── dhcpcd: stop it from touching the Wi-Fi interface ──
    # On RPi, dhcpcd spawns its own wpa_supplicant and grabs wlan0
    # before our service starts. We tell dhcpcd to see the interface
    # but do absolutely nothing with it — no wpa_supplicant, no DHCP.
    if [ -f /etc/dhcpcd.conf ]; then
        if ! grep -q "^interface $P2P_IFACE" /etc/dhcpcd.conf; then
            warn "Configuring dhcpcd to ignore $P2P_IFACE..."
            cat >> /etc/dhcpcd.conf << DHCPEOF

# p2p-wifi-direct: do not manage $P2P_IFACE
interface $P2P_IFACE
    nohook wpa_supplicant
    nodhcp
    noipv6
DHCPEOF
            log "dhcpcd configured for $P2P_IFACE"
        else
            log "dhcpcd already configured for $P2P_IFACE"
        fi
        systemctl restart dhcpcd.service 2>/dev/null || true
    fi

    # NetworkManager: tell it to ignore the interface too
    if command -v nmcli &>/dev/null; then
        warn "NetworkManager detected — setting $P2P_IFACE unmanaged"
        nmcli device set "$P2P_IFACE" managed no 2>/dev/null || true
    fi

    # Clean up stale control sockets
    rm -f /var/run/wpa_supplicant/* 2>/dev/null || true

    log "wpa_supplicant slate wiped clean."
}

# ── Install all files ──────────────────────────────────────
install_files() {
    header "Installing Files"

    # /etc/default/video-node
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
    sed -i "s|P2P_SSID=.*|P2P_SSID=\"${P2P_SSID}\"|" "$INSTALL_ENV_FILE"
    sed -i "s|P2P_PSK=.*|P2P_PSK=\"${P2P_PSK}\"|"     "$INSTALL_ENV_FILE"
    log "Config: $INSTALL_ENV_FILE"

    # wpa_supplicant configs
    mkdir -p "$INSTALL_CONF_DIR"
    apply_conf "$REPO_DIR/config/p2p-host.conf"   "$INSTALL_CONF_DIR/p2p-host.conf"
    apply_conf "$REPO_DIR/config/p2p-client.conf" "$INSTALL_CONF_DIR/p2p-client.conf"
    log "wpa_supplicant: $INSTALL_CONF_DIR/p2p-{host,client}.conf"

    # Scripts
    cp "$REPO_DIR/scripts/p2p-init.sh"     "$INSTALL_BIN_DIR/"
    cp "$REPO_DIR/scripts/p2p-watchdog.sh" "$INSTALL_BIN_DIR/"
    cp "$REPO_DIR/scripts/p2p-power.sh"    "$INSTALL_BIN_DIR/"
    chmod +x "$INSTALL_BIN_DIR/p2p-init.sh"
    chmod +x "$INSTALL_BIN_DIR/p2p-watchdog.sh"
    chmod +x "$INSTALL_BIN_DIR/p2p-power.sh"
    log "Scripts: $INSTALL_BIN_DIR/p2p-{init,watchdog,power}.sh"

    # Systemd
    cp "$REPO_DIR/systemd/p2p-init.service"     "$INSTALL_SYSTEMD_DIR/"
    cp "$REPO_DIR/systemd/p2p-watchdog.service" "$INSTALL_SYSTEMD_DIR/"
    cp "$REPO_DIR/systemd/p2p-power.service"    "$INSTALL_SYSTEMD_DIR/"
    systemctl daemon-reload
    systemctl enable p2p-init.service
    systemctl enable p2p-watchdog.service
    systemctl enable p2p-power.service
    log "Systemd: p2p-init, p2p-watchdog, p2p-power enabled."
}

# ── U-Boot env (NXP only) ──────────────────────────────────
write_uboot_env() {
    [ "$UBOOT_ENV_SUPPORT" != "true" ] && return
    command -v fw_setenv &>/dev/null || { warn "fw_setenv not found, skipping U-Boot env."; return; }
    header "U-Boot Environment"
    fw_setenv node_role     "$ROLE"
    fw_setenv p2p_iface     "$P2P_IFACE"
    fw_setenv p2p_channel   "$P2P_CHANNEL"
    fw_setenv p2p_freq      "$P2P_FREQ"
    fw_setenv p2p_reg_class "$P2P_REG_CLASS"
    log "U-Boot env written."
    info "Verify: fw_printenv node_role p2p_iface p2p_channel p2p_freq p2p_reg_class"
}

# ── Uninstall ──────────────────────────────────────────────
uninstall() {
    header "Uninstall"
    warn "All P2P components will be removed!"
    read -rp "Are you sure? (y/n): " ans
    [ "$ans" != "y" ] && { info "Cancelled."; exit 0; }

    for svc in p2p-power p2p-watchdog p2p-init; do
        systemctl stop    "${svc}.service" 2>/dev/null || true
        systemctl disable "${svc}.service" 2>/dev/null || true
    done

    rm -f "$INSTALL_SYSTEMD_DIR/p2p-init.service"
    rm -f "$INSTALL_SYSTEMD_DIR/p2p-watchdog.service"
    rm -f "$INSTALL_SYSTEMD_DIR/p2p-power.service"
    rm -f "$INSTALL_BIN_DIR/p2p-init.sh"
    rm -f "$INSTALL_BIN_DIR/p2p-watchdog.sh"
    rm -f "$INSTALL_BIN_DIR/p2p-power.sh"
    rm -f "$INSTALL_CONF_DIR/p2p-host.conf"
    rm -f "$INSTALL_CONF_DIR/p2p-client.conf"
    rm -f "$INSTALL_ENV_FILE"
    rm -f "/run/p2p-connected"
    rm -f "/run/p2p-power.cmd"
    rm -f "/var/log/wpa_supplicant.log"

    # Restore dhcpcd.conf — remove the block we added
    if [ -f /etc/dhcpcd.conf ]; then
        sed -i "/# p2p-wifi-direct: do not manage/,/    noipv6/d" /etc/dhcpcd.conf
        systemctl restart dhcpcd.service 2>/dev/null || true
        log "dhcpcd.conf restored."
    fi

    systemctl daemon-reload
    log "All P2P components removed."
    exit 0
}

# ── Summary ────────────────────────────────────────────────
print_summary() {
    header "Installation Complete"
    echo -e "  ${BOLD}Role:${NC}       $ROLE"
    echo -e "  ${BOLD}Device:${NC}     $DEVICE_TYPE"
    echo -e "  ${BOLD}Interface:${NC}  $P2P_IFACE"
    echo -e "  ${BOLD}Frequency:${NC}  ${P2P_FREQ}MHz (Channel ${P2P_CHANNEL})"
    echo -e "  ${BOLD}SSID:${NC}       $P2P_SSID"
    echo -e "  ${BOLD}Host IP:${NC}    192.168.77.1"
    echo -e "  ${BOLD}Client IP:${NC}  192.168.77.2"
    echo ""
    echo -e "  ${CYAN}Start:${NC}"
    echo "    systemctl start p2p-init.service"
    echo "    systemctl start p2p-watchdog.service"
    echo "    systemctl start p2p-power.service"
    echo ""
    echo -e "  ${CYAN}Logs:${NC}"
    echo "    journalctl -fu p2p-init.service"
    echo "    journalctl -fu p2p-watchdog.service"
    echo "    journalctl -fu p2p-power.service"
    echo ""
    echo -e "  ${CYAN}Status:${NC}"
    echo "    ls /run/p2p-connected     # exists = connected"
    echo "    wpa_cli -i $P2P_IFACE status"
    echo ""
    echo -e "  ${CYAN}Power override (optional):${NC}"
    echo "    p2p-power force-performance"
    echo "    p2p-power force-efficient"
    echo "    p2p-power auto"
    echo ""
}

# ── Main ───────────────────────────────────────────────────
main() {
    parse_args "$@"
    check_root
    load_template_defaults

    if [ "$UNINSTALL" = true ]; then
        uninstall
    fi

    # Preserve existing credentials on re-run
    if [ -f "$INSTALL_ENV_FILE" ]; then
        info "Existing config found — preserving credentials..."
        local prev_ssid prev_psk
        prev_ssid=$(grep "^P2P_SSID=" "$INSTALL_ENV_FILE" | cut -d'"' -f2 || true)
        prev_psk=$(grep  "^P2P_PSK="  "$INSTALL_ENV_FILE" | cut -d'"' -f2 || true)
        [ -n "$prev_ssid" ] && DEFAULT_SSID="$prev_ssid"
        [ -n "$prev_psk"  ] && DEFAULT_PSK="$prev_psk"
    fi

    if [ -z "$ROLE" ] || [ -z "$DEVICE" ]; then
        interactive_setup
    else
        P2P_SSID="${ARG_SSID:-$DEFAULT_SSID}"
        P2P_PSK="${ARG_PSK:-$DEFAULT_PSK}"
        info "Non-interactive: role=$ROLE device=$DEVICE SSID=$P2P_SSID"
    fi

    check_deps
    load_device_profile
    determine_frequency
    check_iface "$P2P_IFACE"
    purge_wpa_configs
    install_files
    write_uboot_env
    print_summary
}

main "$@"