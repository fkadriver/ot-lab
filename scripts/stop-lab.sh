#!/usr/bin/env bash
# stop-lab.sh - Stop OT lab components
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 [grfics|labshock|all]"
    echo ""
    echo "  grfics    Stop GRFICSv3 (chemical plant simulation)"
    echo "  labshock  Stop Labshock (multi-protocol SCADA)"
    echo "  all       Stop both (default)"
    exit 1
}

stop_grfics() {
    if [ ! -f "$LAB_DIR/GRFICSv3/docker-compose.yml" ]; then
        echo "[-] GRFICSv3 not initialised, skipping"
        return
    fi
    echo "[*] Stopping GRFICSv3..."
    cd "$LAB_DIR/GRFICSv3"
    local compose_files="-f docker-compose.yml -f $LAB_DIR/overrides/grfics-override.yml"
    if [ -f "$LAB_DIR/overrides/armis-monitoring.yml" ] && \
       docker compose $compose_files -f "$LAB_DIR/overrides/armis-monitoring.yml" ps -q 2>/dev/null | grep -q .; then
        compose_files="$compose_files -f $LAB_DIR/overrides/armis-monitoring.yml"
    fi
    docker compose $compose_files down
    echo "[-] GRFICSv3 stopped"
}

stop_labshock() {
    if [ ! -f "$LAB_DIR/labshock/docker-compose.yml" ]; then
        echo "[-] Labshock not initialised, skipping"
        return
    fi
    echo "[*] Stopping Labshock..."
    cd "$LAB_DIR/labshock"
    docker compose down
    echo "[-] Labshock stopped"
}

case "${1:-all}" in
    grfics)   stop_grfics ;;
    labshock) stop_labshock ;;
    all)      stop_grfics; stop_labshock ;;
    *)        usage ;;
esac

echo ""
echo "[*] Remaining OT networks:"
docker network ls | grep -E 'grfics|labshock' || echo "    (none)"
