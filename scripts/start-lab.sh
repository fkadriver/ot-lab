#!/usr/bin/env bash
# start-lab.sh - Start OT lab components
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 [grfics|labshock|all]"
    echo ""
    echo "  grfics    Start GRFICSv3 (chemical plant simulation)"
    echo "  labshock  Start Labshock (multi-protocol SCADA)"
    echo "  all       Start both"
    exit 1
}

start_grfics() {
    echo "[*] Starting GRFICSv3..."
    if [ ! -d "$LAB_DIR/GRFICSv3" ]; then
        echo "[*] Cloning GRFICSv3..."
        git clone https://github.com/Fortiphyd/GRFICSv3 "$LAB_DIR/GRFICSv3"
    fi
    cd "$LAB_DIR/GRFICSv3"
    docker compose up -d
    echo "[+] GRFICSv3 started"
    echo "    HMI:                 http://localhost:6081"
    echo "    Engineering WS:      http://localhost:6080"
    echo "    OpenPLC:             http://localhost:8080"
}

start_labshock() {
    echo "[*] Starting Labshock..."
    if [ ! -d "$LAB_DIR/labshock" ]; then
        echo "[*] Cloning Labshock..."
        git clone https://github.com/zakharb/labshock "$LAB_DIR/labshock"
    fi
    cd "$LAB_DIR/labshock"
    docker compose up -d
    echo "[+] Labshock started"
    echo "    Portal: check docker logs for URL"
}

case "${1:-all}" in
    grfics)   start_grfics ;;
    labshock) start_labshock ;;
    all)      start_grfics; start_labshock ;;
    *)        usage ;;
esac

echo ""
echo "[*] Active OT networks:"
docker network ls | grep -E 'grfics|labshock' || echo "    (none yet)"

echo ""
echo "[*] To connect a sensor, see docs/sensor-setup.md"
