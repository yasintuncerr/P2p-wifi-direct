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

log()  { logger -t "$TAG" "$1"; echo "[$(date '+%H:%M:%S')] [$TAG] $1"; }
die()  { log "ERROR: $1"; exit 1; }
ok()   { log "OK: $1"; }
warn() { log "WARN: $1"; }

# ── U-Boot env override (NXP only) ────────────────────────────────
uboot_override() {
    [ "$UBOOT_ENV_SUPPORT" != "true" ] && return
    command -v fw_printenv &>/dev/null || return 0
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

# ── Stop any existing wpa_supplicant + release iface ──────────────
stop_wpa() {
    # 1. Release interface from dhcpcd so it stops managing wlan0
    if systemctl is-active dhcpcd.service &>/dev/null; then
        log "Releasing $P2P_IFACE from dhcpcd..."
        dhcpcd --release "$P2P_IFACE" 2>/dev/null || true
        sleep 0.5
    fi

    # 2. Kill any wpa_supplicant holding the interface
    if pgrep -x wpa_supplicant > /dev/null; then
        log "Stopping existing wpa_supplicant..."
        killall wpa_supplicant 2>/dev/null || true
        sleep 1
    fi

    # 3. Flush IP assigned by dhcpcd (e.g. 192.168.1.x)
    ip addr flush dev "$P2P_IFACE" 2>/dev/null || true

    # 4. Clean stale control sockets
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

    # NXP (mlan*) build does not support -f log file option
    if [[ "$P2P_IFACE" == mlan* ]]; then
        wpa_supplicant -B \
            -i "$P2P_IFACE" \
            -c "$conf" \
            -D nl80211 \
            || die "wpa_supplicant failed to start — check: logread | grep wpa"
    else
        wpa_supplicant -B \
            -i "$P2P_IFACE" \
            -c "$conf" \
            -D nl80211 \
            -f "$WPA_LOG" \
            || die "wpa_supplicant failed. See $WPA_LOG"
    fi

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
    # Derive broadcast: 192.168.77.x → 192.168.77.255
    local broadcast
    broadcast=$(echo "$ip" | awk -F. '{print $1"."$2"."$3".255"}')
    log "Assigning $ip/24 brd $broadcast → $P2P_IFACE"
    ip addr flush dev "$P2P_IFACE" 2>/dev/null || true
    ip addr add "$ip/24" broadcast "$broadcast" dev "$P2P_IFACE"
    ip link set "$P2P_IFACE" up
    ok "$P2P_IFACE → $ip/24 (brd $broadcast)"
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
        
        # Fail-fast on obvious connection rejection
        if [ "$state" = "INACTIVE" ] || [ "$state" = "DISCONNECTED" ]; then
            # Re-trigger scanning if it gave up early
            wpa_cli -i "$P2P_IFACE" reconnect > /dev/null 2>&1
        fi

        # Check for wrong password / auth failure
        if wpa_cli -i "$P2P_IFACE" status 2>/dev/null | grep -q "reason=WRONG_KEY"; then
            die "Authentication failed! Incorrect PSK."
        fi

        log "State: $state (waiting...)"
        sleep 1; elapsed=$((elapsed+1))
    done
    log "Timeout: not connected. Final state: $state"
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

    # Lock regulatory domain to TR so client's Country IE doesn't
    # trigger a regdom change and restart the AP mid-session.
    iw reg set TR 2>/dev/null || true

    start_wpa "$WPA_CONF_DIR/p2p-host.conf"

    # Wait until AP is actually running and wpa_supplicant is ready
    log "Waiting for AP to become active..."
    local timeout=10 elapsed=0
    until wpa_cli -i "$P2P_IFACE" status 2>/dev/null | grep -E -q "^wpa_state=(COMPLETED|SCANNING|INACTIVE)"; do
        sleep 1; elapsed=$((elapsed+1))
        [ $elapsed -ge $timeout ] && { warn "AP state verification timeout — continuing anyway."; break; }
    done

    # Double check link state
    if ! ip link show "$P2P_IFACE" | grep -q "RUNNING"; then
        warn "AP RUNNING flag not set on interface, but wpa_supplicant is responding."
    fi

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

    wait_connected || { log "Host not found — will retry via watchdog."; exit 0; }

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