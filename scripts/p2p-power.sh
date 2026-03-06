#!/bin/bash
# ═══════════════════════════════════════════════════════════
# P2P Wi-Fi Power Manager — Closed Box
#
# Monitors TX traffic and switches modes automatically:
#   TX > STREAM_START_THRESHOLD  →  performance (power save off)
#   TX < STREAM_STOP_THRESHOLD for N ticks  →  efficient (power save on)
#
# Optional override (does not break auto unless forced):
#   p2p-power force-performance
#   p2p-power force-efficient
#   p2p-power auto
#
# Or from any language:
#   echo "force-performance" > /run/p2p-power.cmd
# ═══════════════════════════════════════════════════════════
source /etc/default/video-node

TAG="p2p-power"
CMD_FILE="/run/p2p-power.cmd"
STATE_FILE="/run/p2p-connected"
CURRENT_MODE=""
OVERRIDE=""

# ── Thresholds ─────────────────────────────────────────────
STREAM_START_THRESHOLD=102400   # 100 KB/s → stream started
STREAM_STOP_THRESHOLD=10240     # 10 KB/s
IDLE_COUNT_THRESHOLD=6          # 6 × CHECK_INTERVAL = 30s silence → efficient
CHECK_INTERVAL=5                # seconds between checks

# ── Helpers ────────────────────────────────────────────────
log() { logger -t "$TAG" "$1"; echo "[$(date '+%H:%M:%S')] [$TAG] $1"; }

# ── Driver-aware power save toggle ────────────────────────
set_power_save() {
    local state="$1"   # "on" or "off"

    # Standard tools (works for most embedded Linux including RPi/Jetson, and NXP mlan0)
    iwconfig "$P2P_IFACE" power "$state" 2>/dev/null || true
    iw dev "$P2P_IFACE" set power_save "$state" 2>/dev/null || true
    
    # Verify the state actually applied
    sleep 0.2
    local actual_state
    actual_state=$(iw dev "$P2P_IFACE" get power_save 2>/dev/null | grep -Eo "on|off" || echo "unknown")
    
    if [ "$actual_state" != "unknown" ] && [ "$actual_state" != "$state" ]; then
        warn "Driver rejected power_save $state! (Current: $actual_state)"
    # else
    #    log "power_save successfully set to $state"
    fi
}

# ── Performance mode: power save off, low-latency TX queue ─
set_performance() {
    [ "$CURRENT_MODE" = "performance" ] && return
    log "→ PERFORMANCE mode (stream active)"
    set_power_save off
    tc qdisc replace dev "$P2P_IFACE" root pfifo_fast 2>/dev/null || true
    CURRENT_MODE="performance"
}

# ── Efficient mode: power save on ─────────────────────────
set_efficient() {
    [ "$CURRENT_MODE" = "efficient" ] && return
    log "→ EFFICIENT mode (stream idle)"
    set_power_save on
    CURRENT_MODE="efficient"
}

# ── TX bytes from kernel ───────────────────────────────────
get_tx_bytes() {
    cat "/sys/class/net/$P2P_IFACE/statistics/tx_bytes" 2>/dev/null || echo 0
}

# ── Create command file (no named pipe to avoid bash hangs) ──
setup_cmd_file() {
    rm -f "$CMD_FILE"
    touch "$CMD_FILE"
    chmod 666 "$CMD_FILE"
    log "Control file ready: $CMD_FILE"
}

# ── Non-blocking command check ─────────────────────────────
check_cmd() {
    local cmd
    # Read the first line if exists
    if [ -s "$CMD_FILE" ]; then
        read -r cmd < "$CMD_FILE" || true
        # Clear the file immediately so we don't re-process
        > "$CMD_FILE"

        case "$cmd" in
            force-performance)
                log "Override: force-performance"
                OVERRIDE="performance"
                set_performance
                ;;
            force-efficient)
                log "Override: force-efficient"
                OVERRIDE="efficient"
                set_efficient
                ;;
            auto)
                log "Override cleared — back to auto"
                OVERRIDE=""
                ;;
            *)
                [ -n "$cmd" ] && log "Unknown command: $cmd"
                ;;
        esac
    fi
}

# ── Main loop ──────────────────────────────────────────────
main_loop() {
    local prev_tx=0 idle_ticks=0 first_tx_read=true

    log "Power manager started | iface=$P2P_IFACE | check=${CHECK_INTERVAL}s"
    log "Thresholds: start=${STREAM_START_THRESHOLD}B/s  stop=${STREAM_STOP_THRESHOLD}B/s  idle=${IDLE_COUNT_THRESHOLD} ticks"

    set_efficient

    while true; do
        sleep "$CHECK_INTERVAL"
        check_cmd

        if [ ! -f "$STATE_FILE" ]; then
            # Not connected yet. Reset state so we don't start with bad math when connected.
            prev_tx=0
            idle_ticks=0
            first_tx_read=true
            continue
        fi

        # Override active → skip auto logic
        [ -n "$OVERRIDE" ] && continue

        local cur_tx tx_rate
        cur_tx=$(get_tx_bytes)

        # On the very first check after connection, just record the value.
        # Otherwise tx_rate becomes (total_bytes_since_boot - 0) / 5 = huge spike!
        if [ "$first_tx_read" = true ]; then
            prev_tx=$cur_tx
            first_tx_read=false
            continue
        fi

        tx_rate=$(( (cur_tx - prev_tx) / CHECK_INTERVAL ))
        prev_tx=$cur_tx

        if [ "$tx_rate" -ge "$STREAM_START_THRESHOLD" ]; then
            idle_ticks=0
            set_performance
        elif [ "$tx_rate" -lt "$STREAM_STOP_THRESHOLD" ]; then
            if [ "$CURRENT_MODE" = "performance" ]; then
                idle_ticks=$((idle_ticks + 1))
                log "Idle tick $idle_ticks/$IDLE_COUNT_THRESHOLD (TX: ${tx_rate}B/s < $STREAM_STOP_THRESHOLD)"
                if [ "$idle_ticks" -ge "$IDLE_COUNT_THRESHOLD" ]; then
                    idle_ticks=0
                    set_efficient
                fi
            fi
        else
            # We are in the hysteresis zone (between STOP and START threshold)
            # e.g. a stream is playing but currently buffering or low bitrate
            # We maintain the current state and reset the idle counter just in case
            if [ "$CURRENT_MODE" = "performance" ] && [ "$idle_ticks" -gt 0 ]; then
                log "Stream recovered to ${tx_rate}B/s (resetting idle ticks)"
                idle_ticks=0
            fi
        fi
    done
}

# ── Entry point ────────────────────────────────────────────
# Called with argument → send command to running service
if [ -n "${1:-}" ]; then
    case "$1" in
        force-performance|force-efficient|auto)
            if [ -f "$CMD_FILE" ]; then
                echo "$1" > "$CMD_FILE"
                echo "Command sent: $1"
            else
                echo "Error: p2p-power service is not running."
                exit 1
            fi
            ;;
        status)
            echo "Current mode: $CURRENT_MODE | Override: ${OVERRIDE:-none}"
            ;;
        *)
            echo "Usage: p2p-power [force-performance|force-efficient|auto|status]"
            exit 1
            ;;
    esac
    exit 0
fi

# Running as service
setup_cmd_file
main_loop
