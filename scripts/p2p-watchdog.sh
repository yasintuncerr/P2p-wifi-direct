#!/bin/bash
# ─────────────────────────────────────────
# P2P Wi-Fi Direct - Connection Watchdog
# Her WATCHDOG_INTERVAL sends ping each second.
# WATCHDOG_FAIL_THRESHOLD  If it will fail several times, it will trigger p2p-init.sh to restart the connection.
# ─────────────────────────────────────────
source /etc/default/video-node

TAG="p2p-watchdog"
STATE_FILE="/run/p2p-connected"
FAIL_COUNT=0

log() {logger -t "$TAG" "$1"; echo "[$(date '+%H:%M:%S')] [$TAG] $1"; }

# define ping target by role
if [ "$NODE_ROLE" = "host" ]; then
    PING_TARGET="$CLIENT_IP"
else
    PING_TARGET="$HOST_IP"
fi

log "Watchdog started"
log "Target: $PING_TARGET | Interface: $P2P_IFACE"
log "Check: every $WATCHDOG_INTERVAL seconds | fail threshold: $WATCHDOG_FAIL_THRESHOLD"

while true; do
    sleep "$WATCHDOG_INTERVAL"

    #wait until state file exists
    if [ ! -f "$STATE_FILE" ]; then
        log "Initialization not completed yet. State file $STATE_FILE not found."
        continue
    fi

    if ping -c 2 -w 2 -I "$P2P_IFACE" "$PING_TARGET" > /dev/null 2>&1; then
        # healthy
        if [ "$FAIL_COUNT" -gt 0 ]; then
            log "Connection recovered after $FAIL_COUNT failed attempts."
        fi
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "Ping failed (attempt $FAIL_COUNT/$WATCHDOG_FAIL_THRESHOLD)."

        if [ "$FAIL_COUNT" -ge "$WATCHDOG_FAIL_THRESHOLD" ]; then
            log "───────────────────────────────────────────────"
            log "Connection BROKEN. Restarting P2P connection..."
            log "───────────────────────────────────────────────"

            rm -f "$STATE_FILE"  # reset state
            FAIL_COUNT=0

            systemctl restart p2p-init.service

            log "Waiting for reconnection(15s)..."
            sleep 15
            log "Watchdog will resume monitoring..."
        fi
    fi
done