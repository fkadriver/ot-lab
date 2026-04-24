#!/usr/bin/env bash
# start-lab.sh - Start OT lab components
set -e

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
    echo "Usage: $0 [grfics|labshock|all|restart] [--armis]"
    echo ""
    echo "  grfics    Start GRFICSv3 (chemical plant simulation)"
    echo "  labshock  Start Labshock (multi-protocol SCADA)"
    echo "  all       Start both (default)"
    echo "  restart   Stop then start (pass grfics/labshock/all as second arg)"
    echo ""
    echo "Options:"
    echo "  --armis   Enable Armis network monitoring (requires .env.armis)"
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
    
    # Check for Armis integration (via env file or ARMIS_ENABLED flag)
    local compose_files="-f docker-compose.yml -f $LAB_DIR/overrides/grfics-override.yml"
    local armis_msg=""
    local armis_enabled=0
    
    if [ "$ARMIS_ENABLED" = "1" ] || [ -f "$LAB_DIR/.env.armis" ]; then
        if [ -f "$LAB_DIR/.env.armis" ]; then
            echo "[*] Loading Armis configuration..."
            set -a  # Auto-export variables from .env.armis
            source "$LAB_DIR/.env.armis"
            set +a
        fi
        
        if [ -n "$ARMIS_API_KEY" ]; then
            armis_enabled=1
            echo "[*] Armis integration enabled"
            compose_files="$compose_files -f $LAB_DIR/overrides/armis-monitoring.yml"
            armis_msg="
    Armis PCAP Capture:   docker logs -f armis-pcap-capture
    Armis Collector VM:   sudo -E ./scripts/armis-collector-setup.sh"

            # Pull required images for Armis
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
    
    docker compose $compose_files up -d
    echo "[+] GRFICSv3 started"
    echo "    HMI:                 http://localhost:6081"
    echo "    Engineering WS:      http://localhost:6080"
    echo "    OpenPLC:             http://localhost:8080"

    if [ $armis_enabled -eq 1 ]; then
        setup_armis_span
    fi

    if [ -n "$armis_msg" ]; then
        echo "$armis_msg"
    fi
}

# Mirror the router's ICS (eth2) and DMZ (eth0) interfaces to its admin
# interface (eth1) so the Armis Collector VM's TAP on the admin bridge sees
# all OT traffic routed through the router. Rules live in the container netns
# and must be re-applied after each lab start.
setup_armis_span() {
    echo "[*] Setting up Armis SPAN mirrors on router..."
    local retries=10
    while ! docker exec router ip link show eth2 &>/dev/null 2>&1; do
        retries=$((retries - 1))
        [[ $retries -le 0 ]] && echo "[!] Router interfaces not ready — skipping SPAN setup" && return
        sleep 2
    done

    for iface in eth0 eth2; do
        docker exec router tc qdisc add dev "$iface" clsact 2>/dev/null || true
        docker exec router tc filter replace dev "$iface" ingress protocol all \
            u32 match u32 0 0 action mirred egress mirror dev eth1
        docker exec router tc filter replace dev "$iface" egress  protocol all \
            u32 match u32 0 0 action mirred egress mirror dev eth1
    done
    echo "[*] SPAN mirrors active: router eth0+eth2 → eth1 (Armis collector TAP)"
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
TARGET="${1:-all}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --armis)
            ENABLE_ARMIS=1
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
        start_grfics
        ;;
    labshock)
        start_labshock
        ;;
    all)
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
        start_grfics
        start_labshock
        ;;
    restart)
        RESTART_TARGET="${2:-all}"
        echo "[*] Restarting $RESTART_TARGET..."
        "$SCRIPT_DIR/stop-lab.sh" "$RESTART_TARGET"
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
        case "$RESTART_TARGET" in
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
