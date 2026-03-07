#!/bin/bash
# ==============================================================================
# P2P/Wi-Fi Direct Stress & Durability Test Script
#
# Usage:
#   sudo ./p2p-stress-test.sh loop     [--count N]
#   sudo ./p2p-stress-test.sh watchdog
#   sudo ./p2p-stress-test.sh load     --ip <addr> [--user <username>]
# ==============================================================================
set -uo pipefail

TEST_LOG="/var/log/p2p-stress.log"
_BG_PIDS=()

cleanup() {
    local code=$?
    for pid in "${_BG_PIDS[@]+"${_BG_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    [ $code -ne 0 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Script exited with code $code" | tee -a "$TEST_LOG" >&2
    exit $code
}
trap cleanup EXIT
trap 'echo "Interrupted."; exit 130' INT TERM

if [ -f /etc/default/video-node ]; then
    source /etc/default/video-node
else
    echo "ERROR: /etc/default/video-node not found. Run setup.sh first." >&2
    exit 1
fi

NODE_ROLE="${DEVICE_ROLE:-client}"
INTERFACE="${P2P_IFACE:-wlan0}"

if command -v fw_printenv &>/dev/null; then
    _r=$(fw_printenv -n node_role 2>/dev/null || true)
    _i=$(fw_printenv -n p2p_iface 2>/dev/null || true)
    [ -n "$_r" ] && NODE_ROLE="$_r"
    [ -n "$_i" ] && INTERFACE="$_i"
fi

log_info() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$TEST_LOG"; }
log_err()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$TEST_LOG" >&2; }
log_warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN]  $*" | tee -a "$TEST_LOG"; }
log_ok()   { echo "$(date '+%Y-%m-%d %H:%M:%S') [OK]    $*" | tee -a "$TEST_LOG"; }

svc_active()  { systemctl is-active --quiet "${1}.service" 2>/dev/null; }
iface_has_ip() { ip addr show "$INTERFACE" 2>/dev/null | grep -q 'inet '; }

wait_for_init() {
    local max="${1:-30}" elapsed=0
    while [ $elapsed -lt $max ]; do
        local sub
        sub=$(systemctl show -p SubState p2p-init.service 2>/dev/null | cut -d= -f2 || echo "unknown")
        case "$sub" in
            running|exited) return 0 ;;
            failed)         return 1 ;;
        esac
        sleep 1; elapsed=$((elapsed+1))
    done
    log_warn "wait_for_init timed out after ${max}s"
    return 1
}

default_ssh_user() {
    case "${DEVICE_TYPE:-}" in
        rpi|rpi3bp|rpi4|rpi5) echo "pi"     ;;
        jetson)                echo "jetson" ;;
        nxp)                   echo "root"   ;;
        *)                     echo "root"   ;;
    esac
}

ssh_run() {
    local user="$1" ip="$2"; shift 2
    ssh -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${user}@${ip}" "$@"
}

# ==============================================================================
# 1. Loop Test
# ==============================================================================
run_loop_test() {
    local max_loops="$1" success=0 fail=0

    log_info "========================================"
    log_info "Loop Test: $max_loops iterations | $INTERFACE | $NODE_ROLE"
    log_info "========================================"

    for (( i=1; i<=max_loops; i++ )); do
        log_info "--- Loop $i / $max_loops ---"

        if ! systemctl restart p2p-init.service; then
            log_err "Loop $i: systemctl restart failed"; fail=$((fail+1)); continue
        fi

        if ! wait_for_init 30; then
            log_err "Loop $i: p2p-init did not come up"; fail=$((fail+1))
            systemctl stop p2p-init.service 2>/dev/null || true; sleep 2; continue
        fi

        sleep 3

        if iface_has_ip; then
            local ip
            ip=$(ip -4 addr show "$INTERFACE" | awk '/inet /{print $2}' | head -n1)
            log_ok "Loop $i: Connected — $ip"; success=$((success+1))
        else
            log_err "Loop $i: No IP on $INTERFACE"; fail=$((fail+1))
        fi

        systemctl stop p2p-init.service 2>/dev/null || true
        sleep 2
    done

    log_info "========================================"
    log_info "Done — Total:$max_loops Success:$success Failed:$fail"
    log_info "========================================"
}

# ==============================================================================
# 2. Watchdog Recovery Test
# ==============================================================================
run_watchdog_test() {
    local wd_started=false wd_pid=""

    log_info "========================================"
    log_info "Watchdog Recovery Test"
    log_info "========================================"

    if ! svc_active p2p-init; then
        log_info "p2p-init not running — starting..."
        systemctl start p2p-init.service || { log_err "Failed to start p2p-init"; return 1; }
        wait_for_init 30             || { log_err "p2p-init failed to start";  return 1; }
        sleep 3
    fi

    iface_has_ip || { log_err "No IP on $INTERFACE. Is a peer connected?"; return 1; }

    if svc_active p2p-watchdog; then
        log_info "p2p-watchdog.service is active."
    else
        log_warn "p2p-watchdog.service not active — starting manually..."
        [ -x /usr/bin/p2p-watchdog ] || { log_err "/usr/bin/p2p-watchdog not found. Run setup.sh."; return 1; }
        /usr/bin/p2p-watchdog &
        wd_pid=$!
        _BG_PIDS+=("$wd_pid")
        wd_started=true
        sleep 2
    fi

    log_info "Detecting peer on $INTERFACE..."
    local target_ip="" n=0
    while [ -z "$target_ip" ] && [ $n -lt 15 ]; do
        target_ip=$(ip neigh show dev "$INTERFACE" 2>/dev/null \
            | awk '/REACHABLE|STALE|DELAY/{print $1}' | head -n1 || true)
        [ -z "$target_ip" ] && { sleep 1; n=$((n+1)); }
    done

    if [ -z "$target_ip" ]; then
        log_err "Could not detect peer after ${n}s."
        [ "$wd_started" = true ] && [ -n "$wd_pid" ] && kill "$wd_pid" 2>/dev/null || true
        return 1
    fi
    log_info "Peer: $target_ip"

    if ! ping -c 1 -W 2 -I "$INTERFACE" "$target_ip" &>/dev/null; then
        log_err "Peer $target_ip unreachable before test."
        [ "$wd_started" = true ] && [ -n "$wd_pid" ] && kill "$wd_pid" 2>/dev/null || true
        return 1
    fi
    log_ok "Pre-test ping OK."

    local wpa_pid
    wpa_pid=$(pgrep -x wpa_supplicant | head -n1 || true)
    if [ -z "$wpa_pid" ]; then
        log_err "wpa_supplicant not running."
        [ "$wd_started" = true ] && [ -n "$wd_pid" ] && kill "$wd_pid" 2>/dev/null || true
        return 1
    fi

    log_info "Killing wpa_supplicant PID $wpa_pid..."
    kill -9 "$wpa_pid"

    log_info "Waiting up to 90s for recovery..."
    local recovered=false
    for (( i=1; i<=90; i++ )); do
        if ping -c 1 -W 1 -I "$INTERFACE" "$target_ip" &>/dev/null; then
            log_ok "Recovered after ${i}s."; recovered=true; break
        fi
        sleep 1
    done

    [ "$wd_started" = true ] && [ -n "$wd_pid" ] && kill "$wd_pid" 2>/dev/null || true

    if [ "$recovered" = false ]; then
        log_err "Watchdog FAILED: $target_ip unreachable after 90s."
        return 1
    fi
}

# ==============================================================================
# 3. Load Test (iperf3 + ping flood)
# ==============================================================================
run_load_test() {
    local target_ip="$1" remote_user="$2" duration=60

    [ -z "$target_ip" ] && { log_err "--ip required."; return 1; }
    command -v iperf3 &>/dev/null || { log_err "iperf3 not installed: apt-get install iperf3"; return 1; }

    log_info "Verifying SSH to ${remote_user}@${target_ip}..."
    ssh_run "$remote_user" "$target_ip" "echo ok" &>/dev/null \
        || { log_err "SSH failed. Check --user / IP."; return 1; }
    log_ok "SSH OK."

    ssh_run "$remote_user" "$target_ip" "command -v iperf3" &>/dev/null \
        || { log_err "iperf3 not found on $target_ip."; return 1; }

    local local_ip
    local_ip=$(ip -4 addr show "$INTERFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
    [ -z "$local_ip" ] && { log_err "No IP on $INTERFACE."; return 1; }

    log_info "========================================"
    log_info "Load Test: ${duration}s | $local_ip → $target_ip | Role: $NODE_ROLE"
    log_info "========================================"

    ping -f -s 1400 -I "$INTERFACE" "$target_ip" > /tmp/p2p-ping-flood.log 2>&1 &
    local ping_pid=$!
    _BG_PIDS+=("$ping_pid")

    local ok=false

    if [ "$NODE_ROLE" = "host" ]; then
        iperf3 -s --one-off &
        local srv_pid=$!
        _BG_PIDS+=("$srv_pid")
        sleep 1

        if ssh_run "$remote_user" "$target_ip" \
                "iperf3 -c $local_ip -t $duration -i 10" 2>&1 | tee -a "$TEST_LOG"; then
            ok=true
        else
            log_err "Remote iperf3 client failed."
        fi
        kill "$srv_pid" 2>/dev/null || true

    else
        ssh_run "$remote_user" "$target_ip" \
            "nohup iperf3 -s --one-off > /tmp/iperf3-server.log 2>&1 &" || {
            log_err "Failed to start remote iperf3 server."
            kill "$ping_pid" 2>/dev/null || true
            return 1
        }
        sleep 2

        if iperf3 -c "$target_ip" -t "$duration" -i 10 2>&1 | tee -a "$TEST_LOG"; then
            ok=true
        else
            log_err "Local iperf3 client failed."
        fi

        ssh_run "$remote_user" "$target_ip" "pkill -x iperf3 2>/dev/null || true" || true
    fi

    kill "$ping_pid" 2>/dev/null || true
    log_info "--- Ping flood summary ---"
    tail -n 5 /tmp/p2p-ping-flood.log || true

    if [ "$ok" = true ]; then
        log_ok "Load Test PASSED."
    else
        log_err "Load Test FAILED."
        return 1
    fi
}

# ==============================================================================
# Main
# ==============================================================================
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root: sudo $0 $*" >&2; exit 1; }

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    loop)
        COUNT=50
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --count) COUNT="$2"; shift 2 ;;
                *) echo "Unknown: $1" >&2; exit 1 ;;
            esac
        done
        [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --count must be a positive integer" >&2; exit 1; }
        run_loop_test "$COUNT"
        ;;

    watchdog)
        run_watchdog_test
        ;;

    load)
        TARGET_IP=""
        REMOTE_USER="$(default_ssh_user)"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --ip)   TARGET_IP="$2";   shift 2 ;;
                --user) REMOTE_USER="$2"; shift 2 ;;
                *) echo "Unknown: $1" >&2; exit 1 ;;
            esac
        done
        run_load_test "$TARGET_IP" "$REMOTE_USER"
        ;;

    ""|--help|-h)
        cat <<EOF
Usage: $0 {loop|watchdog|load} [options]

  loop --count N
      systemctl restart/stop N kez, her seferinde IP kontrol eder.

  watchdog
      Kills wpa_supplicant, tests watchdog recovery.

  load --ip <addr> [--user <username>]
      60s iperf3 + ping flood. SSH asks for password.
      Default user — rpi*:pi | jetson:jetson | nxp:root
      This device: ${DEVICE_TYPE:-unknown} → default: $(default_ssh_user)
EOF
        exit 0
        ;;

    *)
        echo "Unknown command: '$COMMAND'. Use --help." >&2
        exit 1
        ;;
esac