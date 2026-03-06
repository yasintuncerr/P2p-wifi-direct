#!/bin/bash
# ─────────────────────────────────────────
# P2P Wi-Fi Direct - Connection Watchdog
# Pings the other side every WATCHDOG_INTERVAL seconds.
# Implements Graceful Recovery:
#   1. Loss -> wpa_cli reconnect (soft recovery)
#   2. Repeated Loss -> systemctl restart p2p-init (hard recovery)
# ─────────────────────────────────────────
source /etc/default/video-node

TAG="p2p-watchdog"
STATE_FILE="/run/p2p-connected"

log() { logger -t "$TAG" "$1"; echo "[$(date '+%H:%M:%S')] [$TAG] $1"; }

if [ "$DEVICE_ROLE" = "host" ]; then
    PING_TARGET="$CLIENT_IP"
else
    PING_TARGET="$HOST_IP"
fi

log "Watchdog started"
log "Target: $PING_TARGET | Interface: $P2P_IFACE"
log "Check: every ${WATCHDOG_INTERVAL}s | fail threshold: $WATCHDOG_FAIL_THRESHOLD"

NO_STATE_COUNT=0
NO_STATE_THRESHOLD=6
FAIL_COUNT=0
SOFT_RECOVERY_ATTEMPTED=false

while true; do
    sleep "$WATCHDOG_INTERVAL"

    # 1. Check if p2p-init is currently doing its job (activating)
    # If it's still starting up, be patient, don't increment failure counters.
    init_state=$(systemctl show -p ActiveState -p SubState p2p-init.service 2>/dev/null || true)
    if echo "$init_state" | grep -q "SubState=start"; then
        log "p2p-init is currently starting... waiting."
        NO_STATE_COUNT=0
        continue
    fi

    # 2. Wait for successful initial connection (STATE_FILE)
    if [ ! -f "$STATE_FILE" ]; then
        NO_STATE_COUNT=$((NO_STATE_COUNT + 1))
        log "No connection yet ($NO_STATE_COUNT/$NO_STATE_THRESHOLD)..."
        if [ "$NO_STATE_COUNT" -ge "$NO_STATE_THRESHOLD" ]; then
            log "Timeout waiting for initial connection. Restarting p2p-init..."
            NO_STATE_COUNT=0
            systemctl restart --no-block p2p-init.service
            sleep 15
        fi
        continue
    fi

    NO_STATE_COUNT=0

    # 3. Connection established, monitor health via Ping
    if ping -c 2 -w 2 -I "$P2P_IFACE" "$PING_TARGET" > /dev/null 2>&1; then
        if [ "$FAIL_COUNT" -gt 0 ]; then
            log "Connection recovered after $FAIL_COUNT failed attempts."
        fi
        FAIL_COUNT=0
        SOFT_RECOVERY_ATTEMPTED=false
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "Ping failed ($FAIL_COUNT/$WATCHDOG_FAIL_THRESHOLD)."

        if [ "$FAIL_COUNT" -ge "$WATCHDOG_FAIL_THRESHOLD" ]; then
            log "──────────────────────────────────────────"
            log "Connection LOST ($FAIL_COUNT fails)."

            # Graceful Recovery Strategy
            # Check if wpa_supplicant is still alive before nuking the service
            if wpa_cli -i "$P2P_IFACE" ping &>/dev/null; then
                if [ "$SOFT_RECOVERY_ATTEMPTED" = false ]; then
                    log "wpa_supplicant is alive. Attempting soft reconnect..."
                    wpa_cli -i "$P2P_IFACE" reconnect > /dev/null 2>&1
                    SOFT_RECOVERY_ATTEMPTED=true
                    
                    # Reset fail count partially to give soft recovery time to work
                    # E.g. drops from 6 -> 3. If it fails 3 more times, hard restart triggers.
                    FAIL_COUNT=$((WATCHDOG_FAIL_THRESHOLD / 2))
                    continue
                else
                    log "Soft recovery failed."
                fi
            else
                log "wpa_supplicant is dead or unresponsive."
            fi

            # Hard Recovery (Nuclear Option)
            log "Executing HARD RESTART (systemctl restart p2p-init)..."
            log "──────────────────────────────────────────"
            rm -f "$STATE_FILE"
            FAIL_COUNT=0
            SOFT_RECOVERY_ATTEMPTED=false
            systemctl restart --no-block p2p-init.service
            
            log "Waiting 15s for reconnection..."
            sleep 15
        fi
    fi
done
