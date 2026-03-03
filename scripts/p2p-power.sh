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
CMD_PIPE="/run/p2p-power.cmd"
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
# mlan* → Marvell 88W8997 (NXP) — requires mlanutl
# wlan* → brcmfmac (RPi) or cfg80211 (Jetson) — iwconfig + iw
set_power_save() {
    local state="$1"   # "on" or "off"
    local mlanu_val
    [ "$state" = "on" ] && mlanu_val=1 || mlanu_val=0

    case "$P2P_IFACE" in
        mlan*)
            # Marvell 88W8997 (AzureWave) — mlanutl pscfg 0/1
            # NOTE: validate on device with: mlanutl mlan0 pscfg
            if command -v mlanutl &>/dev/null; then
                mlanutl "$P2P_IFACE" pscfg "$mlanu_val" 2>/dev/null || true
            else
                warn "mlanutl not found — power save not applied for $P2P_IFACE"
            fi
            ;;
        *)
            # brcmfmac (RPi): needs iwconfig
            iwconfig "$P2P_IFACE" power "$state" 2>/dev/null || true
            # cfg80211 (Jetson, others): needs iw
            iw dev "$P2P_IFACE" set power_save "$state" 2>/dev/null || true
            ;;
    esac
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

# ── Create named pipe for override commands ────────────────
setup_pipe() {
    rm -f "$CMD_PIPE"
    mkfifo "$CMD_PIPE"
    chmod 666 "$CMD_PIPE"
    log "Control pipe ready: $CMD_PIPE"
}

# ── Non-blocking command check ─────────────────────────────
check_cmd() {
    local cmd
    if read -r -t 0.1 cmd < "$CMD_PIPE" 2>/dev/null; then
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
                log "Unknown command: $cmd"
                ;;
        esac
    fi
}

# ── Main loop ──────────────────────────────────────────────
main_loop() {
    local prev_tx=0 idle_ticks=0

    log "Power manager started | iface=$P2P_IFACE | check=${CHECK_INTERVAL}s"
    log "Thresholds: start=${STREAM_START_THRESHOLD}B/s  stop=${STREAM_STOP_THRESHOLD}B/s  idle=${IDLE_COUNT_THRESHOLD} ticks"

    set_efficient

    while true; do
        sleep "$CHECK_INTERVAL"
        check_cmd

        if [ ! -f "$STATE_FILE" ]; then
            log "Waiting for connection..."
            prev_tx=0
            idle_ticks=0
            continue
        fi

        # Override active → skip auto logic
        [ -n "$OVERRIDE" ] && continue

        local cur_tx tx_rate
        cur_tx=$(get_tx_bytes)
        tx_rate=$(( (cur_tx - prev_tx) / CHECK_INTERVAL ))
        prev_tx=$cur_tx

        if [ "$tx_rate" -ge "$STREAM_START_THRESHOLD" ]; then
            idle_ticks=0
            set_performance
        else
            if [ "$CURRENT_MODE" = "performance" ]; then
                idle_ticks=$((idle_ticks + 1))
                log "Idle tick $idle_ticks/$IDLE_COUNT_THRESHOLD (TX: ${tx_rate}B/s)"
                if [ "$idle_ticks" -ge "$IDLE_COUNT_THRESHOLD" ]; then
                    idle_ticks=0
                    set_efficient
                fi
            fi
        fi
    done
}

# ── Entry point ────────────────────────────────────────────
# Called with argument → send command to running service
if [ -n "${1:-}" ]; then
    case "$1" in
        force-performance|force-efficient|auto)
            if [ -p "$CMD_PIPE" ]; then
                echo "$1" > "$CMD_PIPE"
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
setup_pipe
main_loop
