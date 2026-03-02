#!/bin/bash

# ───────────────────────────────────────────────────────────────────
# P2P Wi-Fi Direct - Initializing Connection
# Role and parameters reads from /etc/default/video-node
# If U-Boot env are available, use them to override the parameters
# ───────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Load Base parameters from file ─────────────────────────────────
source /etc/default/video-node

TAG="p2p-init"
WPA_CONF_DIR="/etc/wpa_supplicant"
STATE_FILE="/run/p2p-connected"
WPA_LOG="/var/log/wpa_supplicant.log"

log() { logger -t "$TAG" "$1"; echo "[$(date '+%H:%M:%S')] [$TAG] $1"; }
die() { log "ERROR: $1"; exit 1; }
ok()  { log "OK: $1"; }

# ── U-Boot env override (NXP) -─────────────────────────────────────────
uboot_override() {
    [ "$UBOOT_ENV_SUPPORT" != "true" ] && return
    command -v fw_printenv &>/dev/null || return

    log "U-Boot env checking..."

    local _role _iface _channel _freq _req_class
    _role=$(fw_printenv -n node_role 2>/dev/null || true)
    _iface=$(fw_printenv -n p2p_iface 2>/dev/null || true)
    _channel=$(fw_printenv -n p2p_channel 2>/dev/null || true)
    _freq=$(fw_printenv -n p2p_freq 2>/dev/null || true)
    _req_class=$(fw_printenv -n p2p_req_class 2>/dev/null || true)

    [ -n "$_role" ]     && { NODE_ROLE="$_role";            log "U-Boot -> NODE_ROLE=$NODE_ROLE"; }
    [ -n "$_iface" ]    && { P2P_IFACE="$_iface";           log "U-Boot -> P2P_IFACE=$P2P_IFACE"; }
    [ -n "$_channel" ]  && { P2P_CHANNEL="$_channel";       log "U-Boot -> P2P_CHANNEL=$P2P_CHANNEL"; }
    [ -n "$_freq" ]     && { P2P_FREQ="$_freq";             log "U-Boot -> P2P_FREQ=$P2P_FREQ"; }
    [ -n "$_req_class" ] && { P2P_REQ_CLASS="$_req_class";   log "U-Boot -> P2P_REQ_CLASS=$P2P_REQ_CLASS"; }
}

# ── start wpa_supplicant  ──────────────────────────────────────────────
start_wpa() {
    local conf="$1"

    # Kill old processes if any
    if pgrep -x wpa_supplicant > /dev/null; then
        log "Old wpa_supplicant process found, cleaning up..."
        killall wpa_supplicant 2>/dev/null || true
        sleep 1
    fi

    # Clean up stale control sockets that prevent new instances from starting
    rm -f "/var/run/wpa_supplicant/$P2P_IFACE" 2>/dev/null || true


    # reset interface
    ip link set "$P2P_IFACE" down 2>/dev/null || true
    sleep 0.5
    ip link set "$P2P_IFACE" up 2>/dev/null || die "Failed to bring up interface $P2P_IFACE. Check the name of interface with 'iw dev' command."

    log "Starting wpa_supplicant..."
    wpa_supplicant -B \
        -i "$P2P_IFACE" \
        -c "$conf" \
        -D nl80211 \
        -f "$WPA_LOG" \
        || die "Failed to start wpa_supplicant. Check $WPA_LOG for details."

    #Ctrl wait for socket to be ready
    local timeout=10 elapsed=0
    until wpa_cli -i "$P2P_IFACE" ping &>/dev/null; do
        sleep 1; elapsed=$((elapsed+1))
        [ $elapsed -ge $timeout ] && die "wpa_supplicant ctrl socket not responding."
    done
    ok "wpa_supplicant started successfully."
}

# ── Assing Static IP  ───────────────────────────────────────────────
assign_ip() {
    local ip="$1"
    log "Ip assigning $ip/24"
    ip addr flush dev "$P2P_IFACE" 2>/dev/null || true
    ip addr add "$ip/24" dev "$P2P_IFACE"
    ip link set "$P2P_IFACE" up
    ok "IP assigned to $P2P_IFACE: $ip/24"
}

# ── Wait until connected  ───────────────────────────────────────────────
wait_connected() {
    local timeout=25 elapsed=0
    log "WPA state=COMPLETED waiting (max ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local state
        state=$(wpa_cli -i "$P2P_IFACE" status 2>/dev/null \
            | grep "^wpa_state=" | cut -d= -f2 || echo "UNKNOWN")
        [ "$state" = "COMPLETED" ] && { ok "Connection established."; return 0; }
        sleep 1; elapsed=$((elapsed+1))
    done
    log "Timeout: Connection not established."
    return 1
}

# ── Find Persistent Group  ───────────────────────────────────────────────
get_net_id() {
    wpa_cli -i "$P2P_IFACE" list_networks 2>/dev/null \
        | awk -v ssid="$P2P_SSID" '$2 == ssid {print $1}' \
        | head -1 || echo ""
}

 
# ── Host Stream  ───────────────────────────────────────────────
start_host() {
    log "======================================"
    log "Role: HOST (Group Owner)"
    log "Device: $DEVICE_TYPE | Interface: $P2P_IFACE" 
    log "Freaquency: ${P2P_FREQ}MHz | (Ch${P2P_CHANNEL}) | IP: $HOST_IP"
    log "======================================"

    start_wpa "$WPA_CONF_DIR/p2p-host.conf"

    local net_id
    net_id=$(get_net_id)

    if [ -n "$net_id" ]; then
        log "Persistent group found (id=$net_id) -> starting direct..."
        wpa_cli -i "$P2P_IFACE" p2p_group_add persistent="$net_id" freq="$P2P_FREQ"
    else
        log "First time setup -> creating new group..."
        wpa_cli -i "$P2P_IFACE" p2p_group_add persistent freq="$P2P_FREQ"
    fi

    sleep 2
    assign_ip "$HOST_IP"

    #Stop unnecessary scanning except for Beacon
    wpa_cli -i "$P2P_IFACE" p2p_stop_find

    touch "$STATE_FILE"
    ok "Host setup complete. Waiting for clients to connect..."
}

# ── Client Stream  ───────────────────────────────────────────────
start_client() {
    log "======================================"
    log "Role: CLIENT (Group Member)"
    log "Device: $DEVICE_TYPE | Interface: $P2P_IFACE"
    log "Freaquency: ${P2P_FREQ}MHz | (Ch${P2P_CHANNEL}) | IP: $CLIENT_IP"
    log "HOST: $HOST_IP"
    log "======================================"

    start_wpa "$WPA_CONF_DIR/p2p-client.conf"

    local net_id
    net_id=$(get_net_id)

    if [ -n "$net_id" ]; then
        log "Persistent group found (id=$net_id) -> Looking for host..."
        wpa_cli -i "$P2P_IFACE" p2p_find type=progressive

        # Look P2P peer list until the host is found
        local go_mac="" elapsed=0 timeout=15
        while [ -z "$go_mac" ] && [ $elapsed -lt $timeout ]; do
            sleep 1; elapsed=$((elapsed+1))
            go_mac=$(wpa_cli -i "$P2P_IFACE" p2p_peers 2>/dev/null \
                | while read -r mac; do
                    is_go=$(wpa_cli -i "$P2P_IFACE" p2p_peer "$mac" 2>/dev/null \
                        | grep "is_go=" | cut -d= -f2)
                    [ "$is_go" = "1" ] && echo "$mac" && break
                done || true)
        done

        if [ -n "$go_mac" ]; then
            ok "Host found: $go_mac"
            wpa_cli -i "$P2P_IFACE" p2p_stop_find
            wpa_cli -i "$P2P_IFACE" p2p_connect "$go_mac" pbc persistent go_intent=0
        else
            log "Host peer not found. Trying to connect with PBC broadcast..."
            wpa_cli -i "$P2P_IFACE" p2p_stop_find
            wpa_cli -i "$P2P_IFACE" p2p_connect any pbc persistent go_intent=0
        fi
    else
        log "First setup -> Host Waiting for connection, Connecting with PBC broadcast..."
        wpa_cli -i "$P2P_IFACE" p2p_find type=progressive
        wpa_cli -i "$P2P_IFACE" p2p_connect any pbc persistent go_intent=0
    fi

    wait_connected || { log "Connection failed.. Watchdog will take over."; exit 1; }

    assign_ip "$CLIENT_IP"
    wpa_cli -i "$P2P_IFACE" p2p_stop_find

    touch "$STATE_FILE"
    ok "CLIENT ready. IP: $CLIENT_IP | Gateway: $HOST_IP"
}

# ── Main Execution  ───────────────────────────────────────────────
rm -f "$STATE_FILE"

# Default to DEVICE_ROLE from config file, let uboot_override override NODE_ROLE if needed
NODE_ROLE="${DEVICE_ROLE:-}"
uboot_override

if [ -z "$NODE_ROLE" ]; then
    die "NODE_ROLE/DEVICE_ROLE is empty."
fi

case "$NODE_ROLE" in
    host)   start_host ;;
    client) start_client ;;
    *) die "Invalid NODE_ROLE: $NODE_ROLE. Must be 'host' or 'client'." ;;
esac