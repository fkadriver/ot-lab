#!/usr/bin/env bash
# stop-lab.sh - Stop OT lab components
set -e

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

WIPE=0

usage() {
    echo "Usage: $0 [grfics|labshock|all] [--wipe]"
    echo ""
    echo "  grfics    Stop GRFICSv3 (chemical plant simulation)"
    echo "  labshock  Stop Labshock (multi-protocol SCADA)"
    echo "  all       Stop both (default)"
    echo ""
    echo "Options:"
    echo "  --wipe    Remove all persistent volumes"
    echo "            (ScadaLTS DB, PLC state, PCAPs, flow stats, etc.)"
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
    local down_flags=""
    [[ $WIPE -eq 1 ]] && down_flags="-v"
    docker compose $compose_files down $down_flags
    echo "[-] GRFICSv3 stopped"
}

stop_labshock() {
    if [ ! -f "$LAB_DIR/labshock/docker-compose.yml" ]; then
        echo "[-] Labshock not initialised, skipping"
        return
    fi
    echo "[*] Stopping Labshock..."
    cd "$LAB_DIR/labshock"
    local down_flags=""
    [[ $WIPE -eq 1 ]] && down_flags="-v"
    docker compose down $down_flags
    echo "[-] Labshock stopped"
}

# Parse args
TARGET="all"
for arg in "$@"; do
    case "$arg" in
        --wipe)   WIPE=1 ;;
        -h|--help) usage ;;
        grfics|labshock|all) TARGET="$arg" ;;
        *) echo "Unknown argument: $arg"; usage ;;
    esac
done

if [[ $WIPE -eq 1 ]]; then
    echo "[!] --wipe: all persistent volumes will be deleted"
fi

case "$TARGET" in
    grfics)   stop_grfics ;;
    labshock) stop_labshock ;;
    all)      stop_grfics; stop_labshock ;;
esac

echo ""
echo "[*] Remaining OT networks:"
docker network ls | grep -E 'grfics|labshock' || echo "    (none)"

if [[ $WIPE -eq 1 ]]; then
    echo ""
    echo "[*] Remaining OT volumes:"
    docker volume ls | grep -E 'grfics|scadalts|plc|router|labshock|wazuh' || echo "    (none)"
fi
