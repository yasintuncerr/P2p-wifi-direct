#!/bin/bash
# ═══════════════════════════════════════════════════════════
# P2P Wi-Fi Direct - Health Dashboard
# Provides a quick summary of the current P2P connection state.
# ═══════════════════════════════════════════════════════════

source /etc/default/video-node 2>/dev/null || { echo "Error: /etc/default/video-node not found."; exit 1; }

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

STATE_FILE="/run/p2p-connected"

echo -e "\n${BOLD}${CYAN}  P2P Wi-Fi Direct Health Dashboard ${NC}"
echo -e "  $(printf '─%.0s' {1..40})"

# 1. Basic Info
echo -e "${BOLD}Role:${NC}      $DEVICE_ROLE"
echo -e "${BOLD}Interface:${NC} $P2P_IFACE"

if [ "$DEVICE_ROLE" = "host" ]; then
    echo -e "${BOLD}IP:${NC}         $HOST_IP"
else
    echo -e "${BOLD}IP:${NC}         $CLIENT_IP (Target: $HOST_IP)"
fi

# 2. Service Status
init_state=$(systemctl is-active p2p-init.service 2>/dev/null || echo "inactive")
wd_state=$(systemctl is-active p2p-watchdog.service 2>/dev/null || echo "inactive")
pwr_state=$(systemctl is-active p2p-power.service 2>/dev/null || echo "inactive")

echo -e "\n${BOLD}Services:${NC}"
printf "  init: %-10s watchdog: %-10s power: %-10s\n" \
    "$( [ "$init_state" = "active" ] && echo -e "${GREEN}active${NC}" || echo -e "${RED}$init_state${NC}" )" \
    "$( [ "$wd_state" = "active" ] && echo -e "${GREEN}active${NC}" || echo -e "${RED}$wd_state${NC}" )" \
    "$( [ "$pwr_state" = "active" ] && echo -e "${GREEN}active${NC}" || echo -e "${RED}$pwr_state${NC}" )"

# 3. Connection State
echo -e "\n${BOLD}Connection:${NC}"
if [ -f "$STATE_FILE" ]; then
    echo -e "  Status:      ${GREEN}Connected${NC}"
else
    echo -e "  Status:      ${RED}Disconnected / Connecting...${NC}"
fi

wpa_state=$(wpa_cli -i "$P2P_IFACE" status 2>/dev/null | grep "^wpa_state=" | cut -d= -f2 || echo "UNKNOWN")
echo -e "  WPA State:   $wpa_state"

if [ "$wpa_state" = "COMPLETED" ]; then
    freq=$(wpa_cli -i "$P2P_IFACE" status 2>/dev/null | grep "^freq=" | cut -d= -f2 || echo "N/A")
    echo -e "  Frequency:   ${freq} MHz"
    
    # Signal Info (STA mode only usually, some APs support it per-station)
    if [ "$DEVICE_ROLE" = "client" ]; then
        sig=$(iw dev "$P2P_IFACE" link 2>/dev/null | grep "signal" | awk '{print $2, $3}')
        echo -e "  Signal:      ${sig:-N/A}"
    fi
fi

# 4. Watchdog Error Count
if [ "$wd_state" = "active" ]; then
    wd_fails=$(journalctl -u p2p-watchdog.service -n 50 --no-pager | grep "Ping failed" | tail -n 1 | grep -Eo "\([0-9]+/[0-9]+\)" || echo "(0/0)")
    echo -e "  WD Fails:    ${YELLOW}${wd_fails}${NC} (Recent)"
fi

# 5. Traffic Stats
echo -e "\n${BOLD}Traffic Stats:${NC}"
rx_bytes=$(cat /sys/class/net/"$P2P_IFACE"/statistics/rx_bytes 2>/dev/null || echo 0)
tx_bytes=$(cat /sys/class/net/"$P2P_IFACE"/statistics/tx_bytes 2>/dev/null || echo 0)

rx_mb=$(awk "BEGIN {printf \"%.2f\", $rx_bytes/1048576}")
tx_mb=$(awk "BEGIN {printf \"%.2f\", $tx_bytes/1048576}")

echo -e "  RX: ${rx_mb} MB"
echo -e "  TX: ${tx_mb} MB"

echo -e "\n  $(printf '─%.0s' {1..40})"
echo -e "  Run 'journalctl -fu p2p-init' for live logs.\n"
