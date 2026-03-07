#!/bin/bash
# ==============================================================================
# P2P/Wi-Fi Direct Stress & Durability Test Script
# 
# Usage:
#   ./p2p-stress-test.sh [test_type] [options]
#
# Examples:
#   ./p2p-stress-test.sh loop --count 50     # Run connect/disconnect 50 times
#   ./p2p-stress-test.sh watchdog            # Test watchdog recovery (auto detects peer)
#   ./p2p-stress-test.sh load --ip <addr>    # Run iperf3 throughput & ping flood
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
P2P_INIT="$SCRIPT_DIR/p2p-init.sh"
P2P_WATCHDOG="$SCRIPT_DIR/p2p-watchdog.sh"

TEST_LOG="/var/log/p2p-stress.log"

# ----- Init Environment  -----
if [ -f /etc/default/video-node ]; then
    source /etc/default/video-node
fi

NODE_ROLE="${DEVICE_ROLE:-client}"
INTERFACE="${P2P_IFACE:-wlan0}"

if command -v fw_printenv &>/dev/null; then
    _role=$(fw_printenv -n node_role 2>/dev/null || true)
    _iface=$(fw_printenv -n p2p_iface 2>/dev/null || true)
    [ -n "$_role" ]  && NODE_ROLE="$_role"
    [ -n "$_iface" ] && INTERFACE="$_iface"
fi
log_info() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" | tee -a "$TEST_LOG"; }
log_err()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$TEST_LOG"; }
log_warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" | tee -a "$TEST_LOG"; }

# ------------------------------------------------------------------------------
# 1. Connection/Disconnection Loop Test
# ------------------------------------------------------------------------------
run_loop_test() {
    local max_loops=$1
    local success_count=0
    local fail_count=0
    
    log_info "Starting Loop Test ($max_loops iterations)..."
    
    for (( i=1; i<=max_loops; i++ )); do
        log_info "--- Loop $i of $max_loops ---"
        
        # Start connection
        $P2P_INIT start
        sleep 5  # Give it some time to settle
        
        # Check if connected (check for IP address or wpa_state)
        # Assuming wpa_cli status or ip addr is the source of truth
        if ip addr show $INTERFACE | grep -q 'inet '; then
            log_info "Loop $i: Connected successfully."
            success_count=$((success_count + 1))
        else
            log_err "Loop $i: Failed to connect!"
            fail_count=$((fail_count + 1))
        fi
        
        # Stop connection
        $P2P_INIT stop
        sleep 2
    done
    
    log_info "=== Loop Test Complete ==="
    log_info "Total: $max_loops | Success: $success_count | Failed: $fail_count"
}

# ------------------------------------------------------------------------------
# 2. Watchdog Recovery Test
# ------------------------------------------------------------------------------
run_watchdog_test() {
    log_info "Starting Watchdog Recovery Test..."
    
    # Ensure system is running first
    $P2P_INIT start
    sleep 5
    
    # Ensure watchdog is running (either systemd or script)
    # If not running as a service, start it in background for test
    if ! systemctl is-active --quiet p2p-watchdog; then
        log_warn "p2p-watchdog service not active. Starting script manually in background."
        $P2P_WATCHDOG &
        WATCHDOG_PID=$!
    fi
    sleep 2

    # Determine target IP automatically from ARP/neighbor tables BEFORE killing wpa_supplicant
    log_info "Auto-detecting connected peer on $INTERFACE..."
    local target_ip=""
    # Wait until there is a connected peer visible via ARP
    local wait_count=0
    while [ -z "$target_ip" ] && [ $wait_count -lt 15 ]; do
        target_ip=$(ip neigh show dev "$INTERFACE" | awk '/REACHABLE|STALE|DELAY/ {print $1}' | head -n1)
        if [ -z "$target_ip" ]; then
            sleep 1
            wait_count=$((wait_count + 1))
        fi
    done

    if [ -z "$target_ip" ]; then
        log_err "Could not automatically determine the connected peer's IP on $INTERFACE. Is anyone connected?"
        return 1
    fi
    log_info "Target peer detected: $target_ip"

    # Forcibly kill wpa_supplicant
    local wpa_pid=$(pgrep wpa_supplicant)
    if [ -n "$wpa_pid" ]; then
        log_info "Killing wpa_supplicant (PID: $wpa_pid) to test recovery..."
        kill -9 "$wpa_pid"
    else
        log_err "wpa_supplicant is not running. Cannot test."
        return 1
    fi

    # Wait and see if it comes back
    log_info "Waiting up to 90 seconds for watchdog to recover connection..."
    local recovered=0
    for (( i=1; i<=90; i++ )); do
        # Most reliable check: can we ping the target?
        if ping -c 1 -W 1 -I "$INTERFACE" "$target_ip" > /dev/null 2>&1; then
            log_info "Recovery successful! Connection restored and pinged $target_ip in $i seconds."
            recovered=1
            break
        fi
        sleep 1
    done
    
    if [ $recovered -eq 0 ]; then
        log_err "Watchdog failed to ping $target_ip within the timeout."
    fi
    
    # Cleanup background watchdog if we started it
    if [ -n "$WATCHDOG_PID" ]; then
        kill "$WATCHDOG_PID" 2>/dev/null
    fi
}

# ------------------------------------------------------------------------------
# 3. Network Load Stress Test (iperf3 + ping)
# ------------------------------------------------------------------------------
run_load_test() {
    local target_ip=$1
    local remote_user=$2
    if [ -z "$target_ip" ]; then
        log_err "Target IP required for load test. Usage: ./p2p-stress-test.sh load --ip <addr> [--user <username>]"
        return 1
    fi
    
    if ! command -v iperf3 >/dev/null 2>&1; then
        log_err "iperf3 is not installed. Please install it to use this test."
        return 1
    fi

    local local_ip
    local_ip=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    if [ -z "$local_ip" ]; then
        log_err "Could not determine local IP on $INTERFACE. Is the interface up and connected?"
        return 1
    fi

    log_info "Starting Load Test against $target_ip for 60 seconds. Interface: $INTERFACE (IP: $local_ip)"

    if [ "$NODE_ROLE" = "host" ]; then
        log_info "Role: HOST -> Starting local iperf3 server, triggering client on remote IP ($target_ip) via SSH"
        
        # Start server in background
        iperf3 -s -D
        sleep 1
        
        log_info "Connecting to $target_ip (as $remote_user) via SSH to run ping flood & iperf3 client..."
        ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$remote_user@$target_ip" "ping -f -s 1400 $local_ip > /tmp/ping_flood.log 2>&1 & iperf3 -c $local_ip -t 60 -i 10" | tee -a "$TEST_LOG"
        
        log_info "Stopping local iperf3 server..."
        killall iperf3 2>/dev/null || true
    else
        log_info "Role: CLIENT -> Starting iperf3 server on remote IP ($target_ip, as $remote_user) via SSH, running client locally"
        
        # Start server on remote host
        ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$remote_user@$target_ip" "iperf3 -s -D"
        sleep 1

        log_info "Starting local ping flood..."
        ping -f -s 1400 "$target_ip" > /tmp/ping_flood.log 2>&1 &
        PING_PID=$!
        
        log_info "Starting local iperf3 client..."
        iperf3 -c "$target_ip" -t 60 -i 10 | tee -a "$TEST_LOG"
        
        log_info "Cleaning up remote server..."
        kill "$PING_PID" 2>/dev/null || true
        ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$remote_user@$target_ip" "killall iperf3 2>/dev/null || kill -9 \$(pidof iperf3) 2>/dev/null || true"
    fi
    
    log_info "Load Test Complete. Check iperf3 output above and /tmp/ping_flood.log for packet loss."
}

# ==============================================================================
# Main Execution
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (sudo)."
    exit 1
fi

COMMAND=$1
shift

case "$COMMAND" in
    loop)
        COUNT=50
        while [[ "$#" -gt 0 ]]; do
            case $1 in
                --count) COUNT="$2"; shift ;;
                *) echo "Unknown parameter: $1"; exit 1 ;;
            esac
            shift
        done
        run_loop_test $COUNT
        ;;
    watchdog)
        run_watchdog_test
        ;;
    load)
        TARGET_IP=""
        REMOTE_USER="root"
        while [[ "$#" -gt 0 ]]; do
            case $1 in
                --ip) TARGET_IP="$2"; shift ;;
                --user) REMOTE_USER="$2"; shift ;;
                *) echo "Unknown parameter: $1"; exit 1 ;;
            esac
            shift
        done
        run_load_test "$TARGET_IP" "$REMOTE_USER"
        ;;
    *)
        echo "Usage: $0 {loop|watchdog|load} [options]"
        echo "  loop --count N        : Run connection/disconnection up to N times"
        echo "  watchdog              : Kill wpa_supplicant and test watchdog recovery (auto detects peer)"
        echo "  load --ip <addr> [--user <username>] : Run iperf3 + ping flood against target device via SSH"
        exit 1
        ;;
esac

exit 0
