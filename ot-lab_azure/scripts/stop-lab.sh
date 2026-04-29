#!/usr/bin/env bash
# stop-lab.sh - Stop OT lab components (Azure deployment)
set -e

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

WIPE=0

usage() {
    echo "Usage: $0 [--wipe]"
    echo ""
    echo "Options:"
    echo "  --wipe    Remove all persistent volumes and Armis VM UEFI state"
    exit 1
}

stop_grfics() {
    if [ ! -f "$LAB_DIR/GRFICSv3/docker-compose.yml" ]; then
        echo "[-] GRFICSv3 not initialised, skipping"
        return
    fi
    echo "[*] Stopping GRFICSv3..."
    cd "$LAB_DIR/GRFICSv3"
    local compose_files="-f docker-compose.yml -f $LAB_DIR/overrides/grfics-azure.yml"
    if [ -f "$LAB_DIR/overrides/armis-monitoring.yml" ]; then
        if [[ $WIPE -eq 1 ]] || \
           docker compose $compose_files -f "$LAB_DIR/overrides/armis-monitoring.yml" ps -q 2>/dev/null | grep -q .; then
            compose_files="$compose_files -f $LAB_DIR/overrides/armis-monitoring.yml"
        fi
    fi
    local down_flags=""
    [[ $WIPE -eq 1 ]] && down_flags="-v"
    docker compose $compose_files down $down_flags
    echo "[-] GRFICSv3 stopped"
}

wipe_armis_vm() {
    local vars="/opt/armis-collector/ovmf_vars.fd"
    if pkill -f "qemu.*-name armis-collector" 2>/dev/null; then
        echo "[-] Armis collector VM stopped"
        sleep 1
    fi
    if [ -f "$vars" ]; then
        rm -f "$vars"
        echo "[-] Armis VM UEFI state wiped ($vars)"
    fi
}

for arg in "$@"; do
    case "$arg" in
        --wipe)    WIPE=1 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $arg"; usage ;;
    esac
done

if [[ $WIPE -eq 1 ]]; then
    echo "[!] --wipe: all persistent volumes will be deleted"
fi

stop_grfics

if [[ $WIPE -eq 1 ]]; then
    wipe_armis_vm
fi

echo ""
echo "[*] Remaining OT networks:"
docker network ls | grep grfics || echo "    (none)"

if [[ $WIPE -eq 1 ]]; then
    echo ""
    echo "[*] Remaining OT volumes:"
    docker volume ls | grep -E 'grfics|scadalts|plc|router|armis' || echo "    (none)"
fi
