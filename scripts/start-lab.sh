#!/usr/bin/env bash
# start-lab.sh - Start OT lab components
set -e

[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"

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
    echo "Usage: $0 [grfics|labshock|all|restart|reset] [--armis] [--siem]"
    echo ""
    echo "  grfics    Start GRFICSv3 (chemical plant simulation)"
    echo "  labshock  Start Labshock (multi-protocol SCADA)"
    echo "  all       Start both (default)"
    echo "  restart   Stop then start (pass grfics/labshock/all as second arg)"
    echo "  reset     Wipe all persistent data then start fresh"
    echo ""
    echo "Options:"
    echo "  --armis   Enable Armis network monitoring (requires .env.armis)"
    echo "  --siem    Enable Wazuh SIEM (dashboard at http://localhost:5601)"
    echo ""
    echo "Armis Setup:"
    echo "  Run ./scripts/armis-setup.sh --api-key YOUR_KEY to configure"
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

    # Armis integration
    local armis_enabled=0
    if [ "$ARMIS_ENABLED" = "1" ] || [ -f "$LAB_DIR/.env.armis" ]; then
        if [ -f "$LAB_DIR/.env.armis" ]; then
            echo "[*] Loading Armis configuration..."
            set -a
            source "$LAB_DIR/.env.armis"
            set +a
        fi
        if [ -n "$ARMIS_API_KEY" ]; then
            armis_enabled=1
            echo "[*] Armis integration enabled"
            compose_files="$compose_files -f $LAB_DIR/overrides/armis-monitoring.yml"
            extra_msg="$extra_msg
    Armis PCAP Capture:   docker logs -f armis-pcap-capture
    Armis Collector VM:   sudo -E ./scripts/armis-collector-setup.sh"
            echo "[*] Pulling Armis monitoring images..."
            docker pull nicolaka/netshoot:latest 2>/dev/null || true
            docker pull rsyslog/rsyslog:latest 2>/dev/null || true
        else
            echo "[!] ARMIS_API_KEY not set - skipping Armis"
        fi
    fi
    if [ $armis_enabled -eq 0 ] && [ "$ARMIS_ENABLED" = "1" ]; then
        echo "[!] ARMIS_ENABLED=1 but no .env.armis found"
        echo "    Run: ./scripts/armis-setup.sh --api-key YOUR_KEY"
    fi

    # Wazuh SIEM
    local siem_profile=""
    if [ "${SIEM_ENABLED:-0}" = "1" ]; then
        echo "[*] Wazuh SIEM enabled"
        siem_profile="--profile siem"
        extra_msg="$extra_msg
    Wazuh Dashboard:      http://localhost:5601  (admin / admin)"
    fi

    docker compose $compose_files $siem_profile up -d
    echo "[+] GRFICSv3 started"
    echo "    HMI:                 http://localhost:6081"
    echo "    Engineering WS:      http://localhost:6080"
    echo "    OpenPLC:             http://localhost:8080"
    if [ "${SIEM_ENABLED:-0}" = "1" ]; then
        echo "    Wazuh Dashboard:     http://localhost:5601"
    fi

    if [ $armis_enabled -eq 1 ]; then
        setup_armis_span
    fi

    if [ -n "$extra_msg" ]; then
        echo "$extra_msg"
    fi
}

# Re-attach tap-armis to the current admin bridge after a lab restart.
# Docker assigns a new bridge ID each time compose recreates the network.
reattach_armis_tap() {
    local tap="tap-armis"
    if ! ip link show "$tap" &>/dev/null; then
        return  # TAP not present; armis-collector-setup.sh will create it on next run
    fi

    local bridge_id bridge
    bridge_id=$(docker network inspect grficsv3_a-grfics-admin --format '{{.Id}}' 2>/dev/null | cut -c1-12)
    if [[ -z "$bridge_id" ]]; then
        echo "[!] Admin bridge not found — cannot re-attach $tap"
        return
    fi
    bridge="br-$bridge_id"

    local current_master
    current_master=$(ip -o link show "$tap" 2>/dev/null | grep -o 'master [^ ]*' | awk '{print $2}')
    if [[ "$current_master" == "$bridge" ]]; then
        echo "[*] $tap already on $bridge — no change needed"
        return
    fi

    echo "[*] Re-attaching $tap to $bridge (was: ${current_master:-none})..."
    sudo ip link set "$tap" master "$bridge"
    sudo ip link set "$tap" up
    echo "[*] $tap attached to $bridge"
}

# Mirror the router's ICS and DMZ interfaces to its admin interface so the
# Armis Collector VM's TAP on the admin bridge sees all OT traffic.
# Interface names (eth0/eth1/eth2) are detected dynamically because Docker
# can reassign them across restarts.
setup_armis_span() {
    reattach_armis_tap
    echo "[*] Setting up Armis SPAN mirrors on router..."
    local retries=10
    while ! docker exec router ip addr show &>/dev/null 2>&1; do
        retries=$((retries - 1))
        [[ $retries -le 0 ]] && echo "[!] Router not ready — skipping SPAN setup" && return
        sleep 2
    done

    # Detect admin interface by the 172.18.0.0/16 subnet
    local admin_iface ics_iface dmz_iface
    admin_iface=$(docker exec router ip -o addr show | awk '/172\.18\./ {print $2}')
    ics_iface=$(docker exec router ip -o addr show | awk '/192\.168\.95\./ {print $2}')
    dmz_iface=$(docker exec router ip -o addr show | awk '/192\.168\.90\./ {print $2}')

    if [[ -z "$admin_iface" || -z "$ics_iface" || -z "$dmz_iface" ]]; then
        echo "[!] Could not detect router interfaces — skipping SPAN setup"
        echo "    admin=$admin_iface  ics=$ics_iface  dmz=$dmz_iface"
        return
    fi
    echo "[*] Router interfaces: admin=$admin_iface  ics=$ics_iface  dmz=$dmz_iface"

    for iface in "$ics_iface" "$dmz_iface"; do
        docker exec router tc qdisc add dev "$iface" clsact 2>/dev/null || true
        docker exec router tc filter replace dev "$iface" ingress protocol all \
            u32 match u32 0 0 action mirred egress mirror dev "$admin_iface"
        docker exec router tc filter replace dev "$iface" egress  protocol all \
            u32 match u32 0 0 action mirred egress mirror dev "$admin_iface"
    done
    echo "[*] SPAN mirrors active: $ics_iface+$dmz_iface → $admin_iface (Armis TAP)"
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
ENABLE_ARMIS=0
ENABLE_SIEM=0
TARGET="${1:-all}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --armis)
            ENABLE_ARMIS=1
            shift
            ;;
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
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
        if [ $ENABLE_SIEM  -eq 1 ]; then export SIEM_ENABLED=1;  fi
        start_grfics
        ;;
    labshock)
        start_labshock
        ;;
    all)
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
        if [ $ENABLE_SIEM  -eq 1 ]; then export SIEM_ENABLED=1;  fi
        start_grfics
        start_labshock
        ;;
    restart)
        RESTART_TARGET="${2:-all}"
        echo "[*] Restarting $RESTART_TARGET..."
        "$SCRIPT_DIR/stop-lab.sh" "$RESTART_TARGET"
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
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
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
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
