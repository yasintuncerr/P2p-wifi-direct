#!/bin/bash
# ─────────────────────────────────────────
# P2P Wi-Fi Direct - Connection Watchdog
# Pings the other side every WATCHDOG_INTERVAL seconds.
# After WATCHDOG_FAIL_THRESHOLD consecutive failures, restarts p2p-init.
# ─────────────────────────────────────────
source /etc/default/video-node

TAG="p2p-watchdog"
STATE_FILE="/run/p2p-connected"
FAIL_COUNT=0

log() { logger -t "$TAG" "$1"; echo "[$(date '+%H:%M:%S')] [$TAG] $1"; }

if [ "$DEVICE_ROLE" = "host" ]; then
    PING_TARGET="$CLIENT_IP"
else
    PING_TARGET="$HOST_IP"
fi

log "Watchdog started"
log "Target: $PING_TARGET | Interface: $P2P_IFACE"
log "Check: every ${WATCHDOG_INTERVAL}s | fail threshold: $WATCHDOG_FAIL_THRESHOLD"

while true; do
    sleep "$WATCHDOG_INTERVAL"

    if [ ! -f "$STATE_FILE" ]; then
        log "Waiting for p2p-init to complete..."
        continue
    fi

    if ping -c 2 -w 2 -I "$P2P_IFACE" "$PING_TARGET" > /dev/null 2>&1; then
        if [ "$FAIL_COUNT" -gt 0 ]; then
            log "Connection recovered after $FAIL_COUNT failed attempts."
        fi
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "Ping failed ($FAIL_COUNT/$WATCHDOG_FAIL_THRESHOLD)."

        if [ "$FAIL_COUNT" -ge "$WATCHDOG_FAIL_THRESHOLD" ]; then
            log "──────────────────────────────────────────"
            log "Connection LOST. Restarting p2p-init..."
            log "──────────────────────────────────────────"
            rm -f "$STATE_FILE"
            FAIL_COUNT=0
            systemctl restart p2p-init.service
            log "Waiting 15s for reconnection..."
            sleep 15
        fi
    fi
done
