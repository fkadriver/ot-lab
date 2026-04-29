#!/usr/bin/env bash
# start-lab.sh - Start OT lab components (Azure deployment)
set -e

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 [grfics|restart|reset] [--armis]"
    echo ""
    echo "  grfics    Start GRFICSv3 (chemical plant simulation)"
    echo "  restart   Stop then start"
    echo "  reset     Wipe all persistent data then start fresh"
    echo ""
    echo "Options:"
    echo "  --armis   Enable Armis network monitoring (requires .env.armis)"
    echo ""
    echo "Armis Setup:"
    echo "  Copy .env.armis.example to .env.armis and fill in credentials"
    echo "  Run ./scripts/armis-setup.sh --api-key YOUR_KEY to validate"
    exit 1
}

start_grfics() {
    echo "[*] Starting GRFICSv3..."
    if [ ! -f "$LAB_DIR/GRFICSv3/docker-compose.yml" ]; then
        echo "[*] Initialising GRFICSv3 submodule..."
        git -C "$LAB_DIR" submodule update --init GRFICSv3
    fi
    cd "$LAB_DIR/GRFICSv3"

    local compose_files="-f docker-compose.yml -f $LAB_DIR/overrides/grfics-azure.yml"
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
    Armis Collector VM:   sudo -E ./scripts/armis-collector-setup.sh"
            echo "[*] Pulling Armis monitoring images..."
            docker pull nicolaka/netshoot:latest 2>/dev/null || true
            docker pull rsyslog/rsyslog:latest 2>/dev/null || true
        else
            echo "[!] ARMIS_API_KEY not set — skipping Armis"
        fi
    fi
    if [ $armis_enabled -eq 0 ] && [ "$ARMIS_ENABLED" = "1" ]; then
        echo "[!] ARMIS_ENABLED=1 but no .env.armis found"
        echo "    Copy .env.armis.example to .env.armis and fill in credentials"
    fi

    docker compose $compose_files up -d || {
        echo "[!] docker compose exited with errors — some containers may not have started"
    }
    echo "[+] GRFICSv3 started"
    echo "    HMI:                 http://$(curl -s ifconfig.me 2>/dev/null || echo localhost):6081"
    echo "    Engineering WS:      http://$(curl -s ifconfig.me 2>/dev/null || echo localhost):6080"
    echo "    OpenPLC:             http://$(curl -s ifconfig.me 2>/dev/null || echo localhost):8080"
    echo "    Caldera C2:          http://$(curl -s ifconfig.me 2>/dev/null || echo localhost):8888"

    if [ $armis_enabled -eq 1 ]; then
        setup_armis_span
    fi

    if [ -n "$extra_msg" ]; then
        echo "$extra_msg"
    fi
}

reattach_armis_tap() {
    local tap="tap-armis"
    if ! ip link show "$tap" &>/dev/null; then
        return
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
    ip link set "$tap" master "$bridge"
    ip link set "$tap" up
    echo "[*] $tap attached to $bridge"
}

setup_armis_span() {
    reattach_armis_tap
    echo "[*] Setting up Armis SPAN mirrors on router..."

    local retries=30
    while ! docker exec router ip addr show &>/dev/null 2>&1; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            echo "[!] Router not ready after 90s — SPAN not applied"
            echo "    Re-run:  ./scripts/start-lab.sh grfics --armis"
            return 1
        fi
        sleep 3
    done

    local admin_iface ics_iface dmz_iface
    admin_iface=$(docker exec router ip -o addr show | awk '/172\.18\./ {print $2}')
    ics_iface=$(docker exec router ip -o addr show | awk '/192\.168\.95\./ {print $2}')
    dmz_iface=$(docker exec router ip -o addr show | awk '/192\.168\.90\./ {print $2}')

    if [[ -z "$admin_iface" || -z "$ics_iface" || -z "$dmz_iface" ]]; then
        echo "[!] Could not detect router interfaces — SPAN not applied"
        echo "    admin=$admin_iface  ics=$ics_iface  dmz=$dmz_iface"
        return 1
    fi
    echo "[*] Router interfaces: admin=$admin_iface  ics=$ics_iface  dmz=$dmz_iface"

    for iface in "$ics_iface" "$dmz_iface"; do
        docker exec router tc qdisc add dev "$iface" clsact 2>/dev/null || true
        docker exec router tc filter replace dev "$iface" ingress protocol all \
            u32 match u32 0 0 action mirred egress mirror dev "$admin_iface"
        docker exec router tc filter replace dev "$iface" egress  protocol all \
            u32 match u32 0 0 action mirred egress mirror dev "$admin_iface"
    done

    local rule_count
    rule_count=$(docker exec router tc filter show dev "$ics_iface" ingress 2>/dev/null | grep -c mirred || true)
    if [[ $rule_count -gt 0 ]]; then
        echo "[+] SPAN mirrors active: $ics_iface+$dmz_iface → $admin_iface (Armis TAP)"
    else
        echo "[!] SPAN rules failed to apply — Armis collector will not see OT traffic"
        return 1
    fi

    # Mirror traffic from the router's host-side veth to tap-armis before the
    # bridge makes forwarding decisions (prevents MAC-learning from hiding unicast).
    local peer_idx router_veth
    peer_idx=$(docker exec router ip -o link show "$admin_iface" 2>/dev/null \
        | grep -oE '@if[0-9]+' | head -1 | tr -d '@if')
    if [[ -n "$peer_idx" ]]; then
        router_veth=$(ip -o link 2>/dev/null \
            | awk -v idx="${peer_idx}:" '$1==idx {print $2; exit}' | cut -d@ -f1)
    fi

    if [[ -n "$router_veth" ]]; then
        tc qdisc add dev "$router_veth" clsact 2>/dev/null || true
        tc filter replace dev "$router_veth" ingress protocol all \
            u32 match u32 0 0 action mirred egress mirror dev tap-armis
        echo "[*] Host-side tc mirror: $router_veth ingress → tap-armis"
    else
        echo "[!] Could not identify router veth — Armis collector may only see broadcast"
    fi
}

# Parse arguments
ENABLE_ARMIS=0
TARGET="${1:-grfics}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --armis) ENABLE_ARMIS=1; shift ;;
        -h|--help) usage ;;
        *) TARGET="$1"; shift ;;
    esac
done

case "$TARGET" in
    grfics)
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
        start_grfics
        ;;
    restart)
        echo "[*] Restarting GRFICSv3..."
        "$SCRIPT_DIR/stop-lab.sh"
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
        start_grfics
        ;;
    reset)
        echo "[!] Resetting — all persistent data will be wiped"
        "$SCRIPT_DIR/stop-lab.sh" --wipe
        if [ $ENABLE_ARMIS -eq 1 ]; then export ARMIS_ENABLED=1; fi
        start_grfics
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "[*] Active OT networks:"
docker network ls | grep grfics || echo "    (none yet)"
