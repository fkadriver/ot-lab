#!/usr/bin/env bash
# start-lab.sh - Start OT lab components
set -e

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

# Auto-detect the host's default-route network interface for macvlan parent.
# Can be overridden by setting MACVLAN_PARENT before running this script.
detect_macvlan_parent() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -z "$iface" ]]; then
        echo "[!] Could not detect default network interface — using eth0" >&2
        iface="eth0"
    fi
    echo "$iface"
}

if [[ -z "${MACVLAN_PARENT:-}" ]]; then
    export MACVLAN_PARENT=$(detect_macvlan_parent)
fi
echo "[*] macvlan parent interface: $MACVLAN_PARENT"

usage() {
    echo "Usage: $0 [grfics|labshock|all|restart|reset] [--siem]"
    echo ""
    echo "  grfics    Start GRFICSv3 (chemical plant simulation)"
    echo "  labshock  Start Labshock (multi-protocol SCADA)"
    echo "  all       Start both (default)"
    echo "  restart   Stop then start (pass grfics/labshock/all as second arg)"
    echo "  reset     Wipe all persistent data then start fresh"
    echo ""
    echo "Options:"
    echo "  --siem    Enable Wazuh SIEM (dashboard at http://localhost:5601)"
    exit 1
}

start_grfics() {
    echo "[*] Starting GRFICSv3..."
    if [ ! -f "$LAB_DIR/GRFICSv3/docker-compose.yml" ]; then
        echo "[*] Initialising GRFICSv3 submodule..."
        git -C "$LAB_DIR" submodule update --init GRFICSv3
    fi
    cd "$LAB_DIR/GRFICSv3"

    local compose_files="-f docker-compose.yml -f $LAB_DIR/overrides/grfics-override.yml"
    local extra_msg=""

    # Wazuh SIEM
    local siem_profile=""
    if [ "${SIEM_ENABLED:-0}" = "1" ]; then
        echo "[*] Wazuh SIEM enabled"
        # OpenSearch requires vm.max_map_count >= 262144
        local map_count
        map_count=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
        if [[ $map_count -lt 262144 ]]; then
            echo "[*] Setting vm.max_map_count=262144 (required by OpenSearch)..."
            sysctl -w vm.max_map_count=262144
        fi
        siem_profile="--profile siem"
        extra_msg="$extra_msg
    Wazuh Dashboard:      http://localhost:5601  (admin / admin)"
    fi

    docker compose $compose_files $siem_profile up -d || {
        echo "[!] docker compose exited with errors — some containers may not have started"
    }
    echo "[+] GRFICSv3 started"
    echo "    3D Simulation:       http://localhost"
    echo "    HMI:                 http://localhost:6081"
    echo "    Engineering WS:      http://localhost:6080"
    echo "    OpenPLC:             http://localhost:8080"
    echo "    Kali:                http://localhost:6088"
    echo "    Caldera C2:          http://localhost:8888"
    echo "    Router / Firewall:   http://192.168.90.200:5000"
    if [ "${SIEM_ENABLED:-0}" = "1" ]; then
        echo "    Wazuh Dashboard:     http://localhost:5601"
    fi

    if [ -n "$extra_msg" ]; then
        echo "$extra_msg"
    fi
}

start_labshock() {
    echo "[*] Starting Labshock..."
    if [ ! -f "$LAB_DIR/labshock/docker-compose.yml" ]; then
        echo "[*] Initialising labshock submodule..."
        git -C "$LAB_DIR" submodule update --init labshock
    fi
    cd "$LAB_DIR/labshock"
    docker compose up -d
    echo "[+] Labshock started"
    echo "    Portal: check docker logs for URL"
}

# Parse arguments
ENABLE_SIEM=0
TARGET="${1:-all}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --siem)
            ENABLE_SIEM=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

# Execute based on target
case "$TARGET" in
    grfics)
        if [ $ENABLE_SIEM  -eq 1 ]; then export SIEM_ENABLED=1;  fi
        start_grfics
        ;;
    labshock)
        start_labshock
        ;;
    all)
        if [ $ENABLE_SIEM  -eq 1 ]; then export SIEM_ENABLED=1;  fi
        start_grfics
        start_labshock
        ;;
    restart)
        RESTART_TARGET="${2:-all}"
        echo "[*] Restarting $RESTART_TARGET..."
        "$SCRIPT_DIR/stop-lab.sh" "$RESTART_TARGET"
        if [ $ENABLE_SIEM  -eq 1 ]; then export SIEM_ENABLED=1;  fi
        case "$RESTART_TARGET" in
            grfics)  start_grfics ;;
            labshock) start_labshock ;;
            *)       start_grfics; start_labshock ;;
        esac
        ;;
    reset)
        RESET_TARGET="${2:-all}"
        echo "[!] Resetting $RESET_TARGET — all persistent data will be wiped"
        "$SCRIPT_DIR/stop-lab.sh" "$RESET_TARGET" --wipe
        if [ $ENABLE_SIEM  -eq 1 ]; then export SIEM_ENABLED=1;  fi
        case "$RESET_TARGET" in
            grfics)  start_grfics ;;
            labshock) start_labshock ;;
            *)       start_grfics; start_labshock ;;
        esac
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "[*] Active OT networks:"
docker network ls | grep -E 'grfics|labshock' || echo "    (none yet)"

echo ""
echo "[*] To connect a sensor, see docs/sensor-setup.md"
