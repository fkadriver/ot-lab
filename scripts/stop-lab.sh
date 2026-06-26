#!/usr/bin/env bash
# stop-lab.sh - Stop OT lab modules (interactive or CLI)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"
WIPE=0

# ── module stop functions ───────────────────────────────────────────────────────

stop_grfics() {
    [[ -f "$LAB_DIR/GRFICSv3/docker-compose.yml" ]] || { echo "[-] GRFICSv3 not initialised, skipping"; return; }
    echo "[*] Stopping GRFICSv3..."
    local flags=""; [[ $WIPE -eq 1 ]] && flags="-v"
    # Include siem profile so Wazuh containers are stopped if running
    (cd "$LAB_DIR/GRFICSv3" && \
        docker compose -f docker-compose.yml -f "$LAB_DIR/overrides/grfics-override.yml" \
        --profile siem down $flags 2>/dev/null || \
        docker compose -f docker-compose.yml -f "$LAB_DIR/overrides/grfics-override.yml" down $flags)
    echo "[-] GRFICSv3 stopped"
}

stop_labshock() {
    [[ -f "$LAB_DIR/labshock/docker-compose.yml" ]] || { echo "[-] Labshock not initialised, skipping"; return; }
    echo "[*] Stopping Labshock..."
    local flags=""; [[ $WIPE -eq 1 ]] && flags="-v"
    (cd "$LAB_DIR/labshock" && docker compose down $flags)
    echo "[-] Labshock stopped"
}

stop_icssim() {
    [[ -f "$LAB_DIR/icssim/deployments/docker-compose.yml" ]] || { echo "[-] ICSSIM not initialised, skipping"; return; }
    echo "[*] Stopping ICSSIM..."
    local flags=""; [[ $WIPE -eq 1 ]] && flags="-v"
    (cd "$LAB_DIR/icssim" && docker compose -f deployments/docker-compose.yml down $flags)
    echo "[-] ICSSIM stopped"
}

stop_icsvirtual() {
    local cf="$LAB_DIR/icsvirtual/network/DockerDeployment/ICSNetwork/docker-compose.yml"
    [[ -f "$cf" ]] || { echo "[-] ICSsVirtual not initialised, skipping"; return; }
    echo "[*] Stopping ICSsVirtual..."
    local flags=""; [[ $WIPE -eq 1 ]] && flags="-v"
    (cd "$LAB_DIR/icsvirtual" && \
        docker compose -f network/DockerDeployment/ICSNetwork/docker-compose.yml down $flags)
    echo "[-] ICSsVirtual stopped"
}

stop_conpot() {
    [[ -f "$LAB_DIR/conpot/docker-compose.yml" ]] || { echo "[-] Conpot not initialised, skipping"; return; }
    echo "[*] Stopping Conpot..."
    local flags=""; [[ $WIPE -eq 1 ]] && flags="-v"
    (cd "$LAB_DIR/conpot" && docker compose down $flags)
    echo "[-] Conpot stopped"
}

stop_malcolm() {
    [[ -d "$LAB_DIR/malcolm" ]] || { echo "[-] Malcolm not initialised, skipping"; return; }
    echo "[*] Stopping Malcolm..."
    (cd "$LAB_DIR/malcolm" && python3 scripts/stop 2>/dev/null || docker compose down 2>/dev/null) || true
    echo "[-] Malcolm stopped"
}

stop_rangerdanger() {
    [[ -f "$LAB_DIR/rangerdanger/docker-compose.yml" ]] || { echo "[-] RangerDanger not initialised, skipping"; return; }
    echo "[*] Stopping RangerDanger..."
    local flags=""; [[ $WIPE -eq 1 ]] && flags="-v"
    (cd "$LAB_DIR/rangerdanger" && docker compose down $flags)
    echo "[-] RangerDanger stopped"
}

stop_containd() {
    [[ -f "$LAB_DIR/containd/deploy/docker-compose.yml" ]] || { echo "[-] containd not initialised, skipping"; return; }
    echo "[*] Stopping containd..."
    local flags=""; [[ $WIPE -eq 1 ]] && flags="-v"
    (cd "$LAB_DIR/containd" && docker compose -f deploy/docker-compose.yml down $flags)
    echo "[-] containd stopped"
}

dispatch() {
    case "$1" in
        grfics)       stop_grfics ;;
        labshock)     stop_labshock ;;
        icssim)       stop_icssim ;;
        icsvirtual)   stop_icsvirtual ;;
        conpot)       stop_conpot ;;
        malcolm)      stop_malcolm ;;
        rangerdanger) stop_rangerdanger ;;
        containd)     stop_containd ;;
        *) echo "[!] Unknown module: $1"; exit 1 ;;
    esac
}

stop_all() {
    for m in grfics labshock icssim icsvirtual conpot malcolm rangerdanger containd; do
        dispatch "$m"
        echo ""
    done
}

# ── interactive menu ────────────────────────────────────────────────────────────

interactive_menu() {
    local modules=(grfics labshock icssim icsvirtual conpot malcolm rangerdanger containd)
    local labels=(
        "GRFICSv3     — Chemical plant (+ optional Wazuh SIEM)"
        "Labshock     — Multi-protocol SCADA breadth"
        "ICSSIM       — Bottle-filling factory"
        "ICSsVirtual  — Wastewater treatment plant"
        "Conpot       — ICS/SCADA honeypot"
        "Malcolm      — OT SOC/NSM"
        "RangerDanger — Electric substation training"
        "containd     — ICS-aware NGFW"
    )

    echo "Stop which modules?"
    echo ""
    for i in "${!modules[@]}"; do
        printf "  %d) %s\n" $((i+1)) "${labels[$i]}"
    done
    echo ""
    printf "Enter numbers separated by spaces, 'a' for all, or append 'w' to wipe volumes (e.g. '1 3' or 'a w'): "
    read -r INPUT

    [[ "$INPUT" == *w* ]] && WIPE=1 && echo "[!] --wipe: all persistent volumes will be deleted"
    INPUT="${INPUT//w/}"

    if [[ "$INPUT" =~ (^|[[:space:]])a([[:space:]]|$) || "${INPUT// /}" == "a" ]]; then
        stop_all
        return
    fi

    for num in $INPUT; do
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        local idx=$((num - 1))
        if [[ $idx -ge 0 && $idx -lt ${#modules[@]} ]]; then
            dispatch "${modules[$idx]}"
            echo ""
        else
            echo "[!] Ignoring invalid selection: $num"
        fi
    done
}

# ── CLI argument handling ───────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [MODULE|all] [--wipe]"
    echo ""
    echo "Modules: grfics labshock icssim icsvirtual conpot malcolm rangerdanger containd"
    echo ""
    echo "  all     Stop all modules"
    echo "  --wipe  Remove persistent volumes"
    echo ""
    echo "Run with no arguments for interactive module selection."
    exit 1
}

# No arguments → interactive
if [[ $# -eq 0 ]]; then
    interactive_menu
else
    TARGET=""
    for arg in "$@"; do
        case "$arg" in
            --wipe)    WIPE=1 ;;
            -h|--help) usage ;;
            all)       TARGET="all" ;;
            grfics|labshock|icssim|icsvirtual|conpot|malcolm|rangerdanger|containd)
                       TARGET="$arg" ;;
            *)         echo "Unknown argument: $arg"; usage ;;
        esac
    done
    [[ $WIPE -eq 1 ]] && echo "[!] --wipe: all persistent volumes will be deleted"
    if [[ "$TARGET" == "all" || -z "$TARGET" ]]; then
        stop_all
    else
        dispatch "$TARGET"
    fi
fi

echo ""
echo "[*] Remaining OT networks:"
docker network ls | grep -E 'grfics|labshock|icssim|icsvirtual|conpot|malcolm|rangerdanger|containd' \
    || echo "    (none)"

if [[ $WIPE -eq 1 ]]; then
    echo ""
    echo "[*] Remaining OT volumes:"
    docker volume ls | grep -E 'grfics|scadalts|plc|router|labshock|wazuh|icssim|icsvirtual|conpot|malcolm|rangerdanger|containd' \
        || echo "    (none)"
fi
