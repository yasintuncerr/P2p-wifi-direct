#!/bin/bash
# ───────────────────────────────────────────────────────────────────
# P2P Wi-Fi Direct - Init
# Host: AP (mode=2), Client: STA (mode=0)
# Physical interface only — no virtual interfaces, no P2P overhead.
# Power management is handled by p2p-power.service, not here.
# ───────────────────────────────────────────────────────────────────

set -euo pipefail

source /etc/default/video-node

TAG="p2p-init"
WPA_CONF_DIR="/etc/wpa_supplicant"
STATE_FILE="/run/p2p-connected"
WPA_LOG="/var/log/wpa_supplicant.log"

log() { logger -t "$TAG" "$1"; echo "[$(date '+%H:%M:%S')] [$TAG] $1"; }
die() { log "ERROR: $1"; exit 1; }
ok()  { log "OK: $1"; }

# ── U-Boot env override (NXP only) ────────────────────────────────
uboot_override() {
    [ "$UBOOT_ENV_SUPPORT" != "true" ] && return
    command -v fw_printenv &>/dev/null || return
    log "Checking U-Boot env..."
    local _role _iface _channel _freq _reg_class
    _role=$(fw_printenv -n node_role 2>/dev/null || true)
    _iface=$(fw_printenv -n p2p_iface 2>/dev/null || true)
    _channel=$(fw_printenv -n p2p_channel 2>/dev/null || true)
    _freq=$(fw_printenv -n p2p_freq 2>/dev/null || true)
    _reg_class=$(fw_printenv -n p2p_reg_class 2>/dev/null || true)
    [ -n "$_role" ]      && { NODE_ROLE="$_role";          log "U-Boot -> NODE_ROLE=$NODE_ROLE"; }
    [ -n "$_iface" ]     && { P2P_IFACE="$_iface";         log "U-Boot -> P2P_IFACE=$P2P_IFACE"; }
    [ -n "$_channel" ]   && { P2P_CHANNEL="$_channel";     log "U-Boot -> P2P_CHANNEL=$P2P_CHANNEL"; }
    [ -n "$_freq" ]      && { P2P_FREQ="$_freq";           log "U-Boot -> P2P_FREQ=$P2P_FREQ"; }
    [ -n "$_reg_class" ] && { P2P_REG_CLASS="$_reg_class"; log "U-Boot -> P2P_REG_CLASS=$P2P_REG_CLASS"; }
}


# ── Stop any existing wpa_supplicant ──────────────────────────────
stop_wpa() {
    if pgrep -x wpa_supplicant > /dev/null; then
        log "Stopping existing wpa_supplicant..."
        killall wpa_supplicant 2>/dev/null || true
        sleep 1
    fi
    rm -f "/var/run/wpa_supplicant/$P2P_IFACE" 2>/dev/null || true
}

# ── Reset interface ────────────────────────────────────────────────
reset_iface() {
    ip link set "$P2P_IFACE" down 2>/dev/null || true
    sleep 0.3
    ip link set "$P2P_IFACE" up || die "Cannot bring up $P2P_IFACE — check 'iw dev'"
}


# ── Start wpa_supplicant ──────────────────────────────────────────
start_wpa() {
    local conf="$1"
    log "Starting wpa_supplicant ($conf)..."
    wpa_supplicant -B \
        -i "$P2P_IFACE" \
        -c "$conf" \
        -D nl80211 \
        -f "$WPA_LOG" \
        || die "wpa_supplicant failed. See $WPA_LOG"

    local timeout=10 elapsed=0
    until wpa_cli -i "$P2P_IFACE" ping &>/dev/null; do
        sleep 1; elapsed=$((elapsed+1))
        [ $elapsed -ge $timeout ] && die "wpa_supplicant ctrl socket timeout."
    done
    ok "wpa_supplicant running."
}


# ── Assign static IP ──────────────────────────────────────────────
assign_ip() {
    local ip="$1"
    log "Assigning $ip/24 → $P2P_IFACE"
    ip addr flush dev "$P2P_IFACE" 2>/dev/null || true
    ip addr add "$ip/24" dev "$P2P_IFACE"
    ip link set "$P2P_IFACE" up
    ok "$P2P_IFACE → $ip/24"
}

# ── Wait for STA association (client) ─────────────────────────────
wait_connected() {
    local timeout=25 elapsed=0
    log "Waiting for COMPLETED state (max ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local state
        state=$(wpa_cli -i "$P2P_IFACE" status 2>/dev/null \
            | grep "^wpa_state=" | cut -d= -f2 || echo "UNKNOWN")
        [ "$state" = "COMPLETED" ] && { ok "Connected."; return 0; }
        sleep 1; elapsed=$((elapsed+1))
    done
    log "Timeout: not connected."
    return 1
}


# ── HOST ──────────────────────────────────────────────────────────
start_host() {
    log "======================================"
    log "Role: HOST (AP)"
    log "Device: $DEVICE_TYPE | Interface: $P2P_IFACE"
    log "Frequency: ${P2P_FREQ}MHz (Ch${P2P_CHANNEL}) | IP: $HOST_IP"
    log "======================================"

    stop_wpa
    reset_iface
    start_wpa "$WPA_CONF_DIR/p2p-host.conf"

    sleep 1
    assign_ip "$HOST_IP"

    touch "$STATE_FILE"
    ok "Host AP ready — waiting for clients."
}


# ── CLIENT ────────────────────────────────────────────────────────
start_client() {
    log "======================================"
    log "Role: CLIENT (STA)"
    log "Device: $DEVICE_TYPE | Interface: $P2P_IFACE"
    log "Frequency: ${P2P_FREQ}MHz (Ch${P2P_CHANNEL}) | IP: $CLIENT_IP"
    log "HOST: $HOST_IP"
    log "======================================"

    stop_wpa
    reset_iface
    start_wpa "$WPA_CONF_DIR/p2p-client.conf"

    wait_connected || { log "Connection failed — watchdog will retry."; exit 1; }

    assign_ip "$CLIENT_IP"

    touch "$STATE_FILE"
    ok "Client connected. IP: $CLIENT_IP | Host: $HOST_IP"
}

# ── Main ──────────────────────────────────────────────────────────
rm -f "$STATE_FILE"

NODE_ROLE="${DEVICE_ROLE:-}"
uboot_override

[ -z "$NODE_ROLE" ] && die "NODE_ROLE/DEVICE_ROLE is empty."

case "$NODE_ROLE" in
    host)   start_host ;;
    client) start_client ;;
    *) die "Invalid NODE_ROLE: '$NODE_ROLE'. Must be 'host' or 'client'." ;;
esac
