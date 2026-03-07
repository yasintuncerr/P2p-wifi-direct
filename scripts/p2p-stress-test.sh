#!/bin/bash
# ==============================================================================
# P2P/Wi-Fi Direct Stress & Durability Test Script
#
# Usage:
#   ./p2p-stress-test.sh [test_type] [options]
#
# Examples:
#   ./p2p-stress-test.sh loop --count 50
#   ./p2p-stress-test.sh watchdog
#   ./p2p-stress-test.sh load --ip <addr>
#   ./p2p-stress-test.sh load --ip <addr> --user pi
# ==============================================================================
set -uo pipefail
# Note: -e intentionally omitted — we handle errors explicitly so tests keep running.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TEST_LOG="/var/log/p2p-stress.log"

# Background PIDs for cleanup
_BG_PIDS=()

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [ ${#_BG_PIDS[@]} -gt 0 ]; then
        log_info "Cleaning up ${#_BG_PIDS[@]} background process(es)..."
        for pid in "${_BG_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    [ $exit_code -ne 0 ] && log_err "Script exited with code $exit_code"
    exit $exit_code
}
trap cleanup EXIT
trap 'log_err "Interrupted."; exit 130' INT TERM

# ── Environment ───────────────────────────────────────────────────────────────
if [ -f /etc/default/video-node ]; then
    source /etc/default/video-node
else
    echo "ERROR: /etc/default/video-node not found. Run setup.sh first." >&2
    exit 1
fi

NODE_ROLE="${DEVICE_ROLE:-client}"
INTERFACE="${P2P_IFACE:-wlan0}"

# U-Boot env override (NXP only)
if command -v fw_printenv &>/dev/null; then
    _role=$(fw_printenv -n node_role 2>/dev/null || true)
    _iface=$(fw_printenv -n p2p_iface 2>/dev/null || true)
    [ -n "$_role"  ] && NODE_ROLE="$_role"
    [ -n "$_iface" ] && INTERFACE="$_iface"
fi

# ── Logging ───────────────────────────────────────────────────────────────────
log_info() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$TEST_LOG"; }
log_err()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$TEST_LOG" >&2; }
log_warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN]  $*" | tee -a "$TEST_LOG"; }
log_ok()   { echo "$(date '+%Y-%m-%d %H:%M:%S') [OK]    $*" | tee -a "$TEST_LOG"; }

# ── Helper: default SSH user per device type ─────────────────────────────────
# Can be overridden with --user on any command.
default_ssh_user() {
    case "${DEVICE_TYPE:-}" in
        rpi|rpi3bp|rpi4|rpi5) echo "pi"     ;;
        jetson)                echo "jetson" ;;
        nxp)                   echo "root"   ;;
        *)                     echo "root"   ;;  # safe fallback
    esac
}


service_active() {
    systemctl is-active --quiet "${1}.service" 2>/dev/null
}

# ── Helper: wait for p2p-init to finish starting ─────────────────────────────
wait_for_init() {
    local max_wait="${1:-30}"
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local sub
        sub=$(systemctl show -p SubState p2p-init.service 2>/dev/null | cut -d= -f2 || echo "unknown")
        case "$sub" in
            running|exited) return 0 ;;
            failed)         return 1 ;;
        esac
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_warn "wait_for_init timed out after ${max_wait}s"
    return 1
}

# ── Helper: check interface has an IP ────────────────────────────────────────
iface_has_ip() {
    ip addr show "$INTERFACE" 2>/dev/null | grep -q 'inet '
}

# ── Helper: run SSH command ────────────────────────────────────────────────────
# Uses key auth by default (BatchMode=yes).
# If REMOTE_PASSWORD is set, falls back to sshpass for password auth.
SSH_PASSWORD=""   # Set via --password argument

ssh_run() {
    local target_user="$1"
    local target_ip="$2"
    shift 2
    local ssh_opts=(
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
    )

    if [ -n "$SSH_PASSWORD" ]; then
        # Password mode: requires sshpass
        if ! command -v sshpass &>/dev/null; then
            log_err "sshpass not found. Install it: apt-get install sshpass"
            return 1
        fi
        SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${ssh_opts[@]}" "${target_user}@${target_ip}" "$@"
    else
        # Key mode: BatchMode=yes (fails fast if no key)
        ssh "${ssh_opts[@]}" -o BatchMode=yes "${target_user}@${target_ip}" "$@"
    fi
}

# ── Helper: verify SSH and give actionable error ───────────────────────────────
verify_ssh() {
    local target_user="$1"
    local target_ip="$2"
    log_info "Verifying SSH to ${target_user}@${target_ip}..."

    if ssh_run "$target_user" "$target_ip" "echo ok" &>/dev/null; then
        log_ok "SSH OK."
        return 0
    fi

    # Give a helpful error depending on auth mode
    log_err "SSH to ${target_user}@${target_ip} failed."
    if [ -z "$SSH_PASSWORD" ]; then
        log_err "No SSH key found. Options:"
        log_err "  1) Copy your key:  ssh-copy-id ${target_user}@${target_ip}"
        log_err "  2) Use password:   add --password <yourpassword> to the command"
    else
        log_err "Password authentication failed. Check --password value."
    fi
    return 1
}

# ── Helper: start iperf3 server (no -D flag, background process instead) ─────
# iperf3 removed -D (daemon) flag in v3.7. Use background process instead.
start_iperf3_server() {
    iperf3 -s --one-off &
    local pid=$!
    _BG_PIDS+=("$pid")
    echo "$pid"
}

stop_iperf3_server() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    local new_pids=()
    for p in "${_BG_PIDS[@]+"${_BG_PIDS[@]}"}"; do
        [ "$p" != "$pid" ] && new_pids+=("$p")
    done
    _BG_PIDS=("${new_pids[@]+"${new_pids[@]}"}")
}

# ==============================================================================
# 1. Connection / Disconnection Loop Test
# ==============================================================================
run_loop_test() {
    local max_loops="${1:-50}"
    local success_count=0
    local fail_count=0

    log_info "========================================"
    log_info "Loop Test: $max_loops iterations"
    log_info "Interface: $INTERFACE | Role: $NODE_ROLE"
    log_info "========================================"

    for (( i=1; i<=max_loops; i++ )); do
        log_info "--- Loop $i / $max_loops ---"

        # p2p-init.sh has no start/stop args — use systemctl
        if ! systemctl restart p2p-init.service; then
            log_err "Loop $i: systemctl restart p2p-init.service failed"
            fail_count=$((fail_count + 1))
            continue
        fi

        if ! wait_for_init 30; then
            log_err "Loop $i: p2p-init did not reach running/exited state"
            fail_count=$((fail_count + 1))
            systemctl stop p2p-init.service 2>/dev/null || true
            sleep 2
            continue
        fi

        sleep 3  # Brief settle time

        if iface_has_ip; then
            local ip
            ip=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
            log_ok "Loop $i: Connected — $INTERFACE @ $ip"
            success_count=$((success_count + 1))
        else
            log_err "Loop $i: No IP on $INTERFACE after init"
            fail_count=$((fail_count + 1))
        fi

        systemctl stop p2p-init.service 2>/dev/null || true
        sleep 2
    done

    log_info "========================================"
    log_info "Loop Test Done"
    log_info "Total: $max_loops | Success: $success_count | Failed: $fail_count"
    log_info "========================================"
}

# ==============================================================================
# 2. Watchdog Recovery Test
# ==============================================================================
run_watchdog_test() {
    local watchdog_started_here=false
    local watchdog_bg_pid=""  # Always initialize — avoid unbound variable

    log_info "========================================"
    log_info "Watchdog Recovery Test"
    log_info "========================================"

    # Ensure p2p-init is running
    if ! service_active p2p-init; then
        log_info "p2p-init not running — starting..."
        systemctl start p2p-init.service || { log_err "Failed to start p2p-init"; return 1; }
        wait_for_init 30 || { log_err "p2p-init failed to start"; return 1; }
        sleep 3
    fi

    if ! iface_has_ip; then
        log_err "No IP on $INTERFACE. Is a peer connected?"
        return 1
    fi

    # Start watchdog only if not already running as a service
    if service_active p2p-watchdog; then
        log_info "p2p-watchdog.service is already active."
    else
        log_warn "p2p-watchdog.service not active — starting /usr/bin/p2p-watchdog in background."
        if [ ! -x /usr/bin/p2p-watchdog ]; then
            log_err "/usr/bin/p2p-watchdog not found. Run setup.sh first."
            return 1
        fi
        /usr/bin/p2p-watchdog &
        watchdog_bg_pid=$!
        _BG_PIDS+=("$watchdog_bg_pid")
        watchdog_started_here=true
        sleep 2
    fi

    # Detect peer IP BEFORE killing wpa_supplicant
    log_info "Detecting connected peer on $INTERFACE..."
    local target_ip=""
    local wait_count=0
    while [ -z "$target_ip" ] && [ $wait_count -lt 15 ]; do
        target_ip=$(ip neigh show dev "$INTERFACE" 2>/dev/null \
            | awk '/REACHABLE|STALE|DELAY/ {print $1}' | head -n1)
        if [ -z "$target_ip" ]; then
            sleep 1
            wait_count=$((wait_count + 1))
        fi
    done

    if [ -z "$target_ip" ]; then
        log_err "Could not detect peer IP on $INTERFACE after ${wait_count}s."
        [ "$watchdog_started_here" = true ] && [ -n "$watchdog_bg_pid" ] && \
            kill "$watchdog_bg_pid" 2>/dev/null || true
        return 1
    fi
    log_info "Peer detected: $target_ip"

    # Pre-test sanity ping
    if ! ping -c 1 -W 2 -I "$INTERFACE" "$target_ip" &>/dev/null; then
        log_err "Peer $target_ip not reachable before test. Aborting."
        [ "$watchdog_started_here" = true ] && [ -n "$watchdog_bg_pid" ] && \
            kill "$watchdog_bg_pid" 2>/dev/null || true
        return 1
    fi
    log_ok "Pre-test ping OK."

    # Kill wpa_supplicant to simulate link failure
    local wpa_pid
    wpa_pid=$(pgrep -x wpa_supplicant | head -n1 || true)
    if [ -z "$wpa_pid" ]; then
        log_err "wpa_supplicant is not running. Cannot simulate failure."
        [ "$watchdog_started_here" = true ] && [ -n "$watchdog_bg_pid" ] && \
            kill "$watchdog_bg_pid" 2>/dev/null || true
        return 1
    fi
    log_info "Killing wpa_supplicant PID $wpa_pid..."
    kill -9 "$wpa_pid"

    # Wait for recovery
    log_info "Waiting up to 90s for watchdog to restore connectivity (target: $target_ip)..."
    local recovered=false
    for (( i=1; i<=90; i++ )); do
        if ping -c 1 -W 1 -I "$INTERFACE" "$target_ip" &>/dev/null; then
            log_ok "Recovery successful! Ping to $target_ip restored after ${i}s."
            recovered=true
            break
        fi
        sleep 1
    done

    [ "$recovered" = false ] && log_err "Watchdog FAILED: $target_ip unreachable after 90s."

    # Cleanup background watchdog if we started it
    if [ "$watchdog_started_here" = true ] && [ -n "$watchdog_bg_pid" ]; then
        kill "$watchdog_bg_pid" 2>/dev/null || true
    fi

    [ "$recovered" = true ]
}

# ==============================================================================
# 3. Network Load Stress Test (iperf3 + ping flood)
# ==============================================================================
run_load_test() {
    local target_ip="$1"
    local remote_user="${2:-root}"
    local iperf_duration=60

    if [ -z "$target_ip" ]; then
        log_err "Target IP required. Usage: $0 load --ip <addr> [--user <username>]"
        return 1
    fi

    if ! command -v iperf3 &>/dev/null; then
        log_err "iperf3 not installed. Run: apt-get install iperf3"
        return 1
    fi

    # Verify SSH access first — fail fast before starting anything
    verify_ssh "$remote_user" "$target_ip" || return 1

    # Verify remote has iperf3
    if ! ssh_run "$remote_user" "$target_ip" "command -v iperf3" &>/dev/null; then
        log_err "iperf3 not found on ${target_ip}. Install it first."
        return 1
    fi

    local local_ip
    local_ip=$(ip addr show "$INTERFACE" 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    if [ -z "$local_ip" ]; then
        log_err "No IP on $INTERFACE. Is the connection up?"
        return 1
    fi

    log_info "========================================"
    log_info "Load Test: ${iperf_duration}s iperf3 + ping flood"
    log_info "Local: $INTERFACE ($local_ip) | Remote: $target_ip"
    log_info "Role: $NODE_ROLE"
    log_info "========================================"

    # Start ping flood in background
    log_info "Starting ping flood (1400B) → $target_ip"
    ping -f -s 1400 -I "$INTERFACE" "$target_ip" > /tmp/p2p-ping-flood.log 2>&1 &
    local ping_pid=$!
    _BG_PIDS+=("$ping_pid")

    local iperf_ok=false

    if [ "$NODE_ROLE" = "host" ]; then
        # HOST: local iperf3 server, remote client via SSH
        log_info "Starting local iperf3 server..."
        local server_pid
        server_pid=$(start_iperf3_server)
        sleep 1

        log_info "Starting iperf3 client on ${target_ip} via SSH..."
        if ssh_run "$remote_user" "$target_ip" \
            "iperf3 -c $local_ip -t $iperf_duration -i 10" 2>&1 | tee -a "$TEST_LOG"; then
            iperf_ok=true
        else
            log_err "Remote iperf3 client failed."
        fi

        stop_iperf3_server "$server_pid"

    else
        # CLIENT: remote iperf3 server via SSH, local client
        log_info "Starting iperf3 server on ${target_ip} via SSH..."
        # --one-off: server exits after a single client connection (no -D flag needed)
        ssh_run "$remote_user" "$target_ip" \
            "nohup iperf3 -s --one-off > /tmp/iperf3-server.log 2>&1 &" || {
            log_err "Failed to start remote iperf3 server."
            kill "$ping_pid" 2>/dev/null || true
            return 1
        }
        sleep 1

        log_info "Starting local iperf3 client → $target_ip"
        if iperf3 -c "$target_ip" -t "$iperf_duration" -i 10 2>&1 | tee -a "$TEST_LOG"; then
            iperf_ok=true
        else
            log_err "Local iperf3 client failed."
        fi

        # Cleanup remote server (--one-off should have exited, but be safe)
        ssh_run "$remote_user" "$target_ip" \
            "pkill -x iperf3 2>/dev/null || true" || true
    fi

    # Stop ping flood
    kill "$ping_pid" 2>/dev/null || true

    log_info "--- Ping Flood Summary ---"
    tail -n 5 /tmp/p2p-ping-flood.log || true

    if [ "$iperf_ok" = true ]; then
        log_ok "Load Test PASSED."
    else
        log_err "Load Test FAILED — see $TEST_LOG"
        return 1
    fi
}

# ==============================================================================
# SSH Key Setup
# ==============================================================================
setup_ssh_key() {
    local target_ip="$1"
    local remote_user="$2"
    local password="$3"

    # sudo ile çalışıyoruz — key'i asıl kullanıcının home'una koy
    local real_user="${SUDO_USER:-$USER}"
    local real_home
    real_home=$(getent passwd "$real_user" | cut -d: -f6)
    local key_path="${real_home}/.ssh/id_ed25519"
    local pub_path="${key_path}.pub"

    log_info "Setting up SSH key for ${remote_user}@${target_ip}"
    log_info "Key owner: $real_user | Key path: $key_path"

    # 1. Generate key if missing
    if [ ! -f "$key_path" ]; then
        log_info "No key found at $key_path — generating ed25519 key..."
        mkdir -p "${real_home}/.ssh"
        chmod 700 "${real_home}/.ssh"
        # Run as actual user, not root, so ownership is correct
        sudo -u "$real_user" ssh-keygen -t ed25519 -N "" -f "$key_path" -C "${real_user}@p2p-stress-test" || {
            log_err "ssh-keygen failed."
            return 1
        }
        log_ok "Key generated: $key_path"
    else
        log_info "Key already exists: $key_path"
    fi

    # 2. Check if key is already installed on remote
    log_info "Checking if key is already authorized on ${target_ip}..."
    if SSH_PASSWORD="" ssh \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -i "$key_path" \
        "${remote_user}@${target_ip}" "echo ok" &>/dev/null; then
        log_ok "Key already works — no action needed."
        return 0
    fi

    # 3. Copy key using ssh-copy-id (password required)
    if [ -z "$password" ]; then
        log_err "Key not yet on remote, and no --password provided to copy it."
        log_err "Run: $0 setup-ssh --ip $target_ip --user $remote_user --password <pass>"
        return 1
    fi

    if ! command -v sshpass &>/dev/null; then
        log_err "sshpass not installed. Run: apt-get install sshpass"
        return 1
    fi

    log_info "Copying public key to ${remote_user}@${target_ip}..."
    local pubkey
    pubkey=$(cat "$pub_path")
    SSHPASS="$password" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "${remote_user}@${target_ip}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         grep -qxF '${pubkey}' ~/.ssh/authorized_keys 2>/dev/null || \
         echo '${pubkey}' >> ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys" || {
        log_err "Failed to copy key. Possible causes:"
        log_err "  - Wrong password"
        log_err "  - PasswordAuthentication disabled in sshd_config on remote"
        log_err "  - Wrong --user (current: $remote_user)"
        return 1
    }

    # 4. Verify key auth works now
    log_info "Verifying key auth..."
    if SSH_PASSWORD="" ssh \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -i "$key_path" \
        "${remote_user}@${target_ip}" "echo ok" &>/dev/null; then
        log_ok "SSH key auth is working for ${remote_user}@${target_ip}."
        log_ok "You can now run: sudo $0 load --ip $target_ip --user $remote_user"
    else
        log_err "Key was copied but auth still failing. Check sshd config on remote."
        return 1
    fi
}

# ==============================================================================
# Main
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root: sudo $0 $*" >&2
    exit 1
fi

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    loop)
        COUNT=50
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --count) COUNT="$2"; shift 2 ;;
                *) echo "Unknown parameter: $1" >&2; exit 1 ;;
            esac
        done
        if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: --count must be a positive integer (got: $COUNT)" >&2
            exit 1
        fi
        run_loop_test "$COUNT"
        ;;

    watchdog)
        run_watchdog_test
        ;;

    setup-ssh)
        TARGET_IP=""
        REMOTE_USER="$(default_ssh_user)"
        SSH_PASSWORD=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --ip)       TARGET_IP="$2";    shift 2 ;;
                --user)     REMOTE_USER="$2";  shift 2 ;;
                --password) SSH_PASSWORD="$2"; shift 2 ;;
                *) echo "Unknown parameter: $1" >&2; exit 1 ;;
            esac
        done
        [ -z "$TARGET_IP" ] && { echo "ERROR: --ip required." >&2; exit 1; }
        setup_ssh_key "$TARGET_IP" "$REMOTE_USER" "$SSH_PASSWORD"
        ;;

    load)
        TARGET_IP=""
        REMOTE_USER="$(default_ssh_user)"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --ip)       TARGET_IP="$2";    shift 2 ;;
                --user)     REMOTE_USER="$2";  shift 2 ;;
                --password) SSH_PASSWORD="$2"; shift 2 ;;
                *) echo "Unknown parameter: $1" >&2; exit 1 ;;
            esac
        done
        run_load_test "$TARGET_IP" "$REMOTE_USER"
        ;;

    ""|--help|-h)
        echo "Usage: $0 {setup-ssh|loop|watchdog|load} [options]"
        echo ""
        echo "  setup-ssh --ip <addr> --password <pass> [--user <username>]"
        echo "      Generate SSH key (if needed) and copy it to the remote device."
        echo "      Run this once before 'load'. No password needed after."
        echo "      Default user is inferred from DEVICE_TYPE in /etc/default/video-node:"
        echo "        rpi/rpi3bp/rpi4/rpi5 → pi   |   jetson → jetson   |   nxp → root"
        echo ""
        echo "  loop --count N"
        echo "      Connect/disconnect N times via systemctl, verify IP each round."
        echo ""
        echo "  watchdog"
        echo "      Kill wpa_supplicant, verify watchdog restores connectivity."
        echo ""
        echo "  load --ip <addr> [--user <username>]"
        echo "      iperf3 throughput test + ping flood over the P2P link."
        echo "      Default user same as setup-ssh (device-aware)."
        echo ""
        echo "  Current device: ${DEVICE_TYPE:-unknown} → default user: $(default_ssh_user)"
        echo ""
        exit 0
        ;;

    *)
        echo "Unknown command: '$COMMAND'. Use --help for usage." >&2
        exit 1
        ;;
esac
