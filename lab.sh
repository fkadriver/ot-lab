#!/usr/bin/env bash
# lab.sh - Interactive OT/ICS lab launcher
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────

print_header() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              OT/ICS Cybersecurity Lab Launcher               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

ensure_submodule() {
    local name="$1" path="$2"
    if [[ ! -d "$path" || -z "$(ls -A "$path" 2>/dev/null)" ]]; then
        echo "[*] Initialising $name submodule..."
        git -C "$SCRIPT_DIR" submodule update --init "$name"
    fi
}

set_map_count() {
    local current
    current=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
    if [[ $current -lt 262144 ]]; then
        echo "[*] Setting vm.max_map_count=262144 (required by OpenSearch)..."
        sudo sysctl -w vm.max_map_count=262144
    fi
}

# ── module start functions ────────────────────────────────────────────────────

start_grfics() {
    ensure_submodule GRFICSv3 "$SCRIPT_DIR/GRFICSv3"
    local compose="-f $SCRIPT_DIR/GRFICSv3/docker-compose.yml -f $SCRIPT_DIR/overrides/grfics-override.yml"
    local profile=""
    if [[ "${ENABLE_SIEM:-0}" == "1" ]]; then
        set_map_count
        profile="--profile siem"
    fi
    echo "[*] Starting GRFICSv3..."
    (cd "$SCRIPT_DIR/GRFICSv3" && docker compose $compose $profile up -d)
    echo "[+] GRFICSv3 ready"
    echo "    OpenPLC         http://localhost:8080  (openplc / openplc)"
    echo "    ScadaLTS HMI    http://localhost:6081  (admin / admin)"
    echo "    Engineering WS  http://localhost:6080"
    echo "    Caldera C2      http://localhost:8888  (red / fortiphyd-red)"
    [[ "${ENABLE_SIEM:-0}" == "1" ]] && echo "    Wazuh Dashboard http://localhost:5601  (admin / admin)"
}

start_labshock() {
    ensure_submodule labshock "$SCRIPT_DIR/labshock"
    echo "[*] Starting Labshock..."
    (cd "$SCRIPT_DIR/labshock" && docker compose up -d)
    echo "[+] Labshock ready — check 'docker logs labshock' for portal URL"
    echo "    Protocols: Modbus RTU/TCP · S7comm · EtherNet/IP · BACnet · OPC UA · MQTT"
}

start_icssim() {
    ensure_submodule icssim "$SCRIPT_DIR/icssim"
    echo "[*] Starting ICSSIM (bottle-filling factory)..."
    (cd "$SCRIPT_DIR/icssim" && docker compose -f deployments/docker-compose.yml up -d)
    echo "[+] ICSSIM ready — Modbus TCP factory simulation running"
}

start_icsvirtual() {
    ensure_submodule icsvirtual "$SCRIPT_DIR/icsvirtual"
    echo "[*] Starting ICSsVirtual (wastewater treatment)..."
    (cd "$SCRIPT_DIR/icsvirtual" && docker compose -f network/DockerDeployment/ICSNetwork/docker-compose.yml up -d)
    echo "[+] ICSsVirtual ready — OpenPLC + ScadaLTS wastewater simulation running"
}

start_conpot() {
    ensure_submodule conpot "$SCRIPT_DIR/conpot"
    echo "[*] Starting Conpot (ICS honeypot)..."
    (cd "$SCRIPT_DIR/conpot" && docker compose up -d)
    echo "[+] Conpot ready"
    echo "    Modbus :502 · S7comm :102 · HTTP :80 · BACnet :47808 · IEC-104 :2404"
}

start_malcolm() {
    ensure_submodule malcolm "$SCRIPT_DIR/malcolm"
    set_map_count
    echo "[*] Starting Malcolm (OT SOC/NSM)..."
    if [[ ! -f "$SCRIPT_DIR/malcolm/.configured" ]]; then
        echo ""
        echo "    [!] Malcolm requires first-run configuration."
        echo "        Run: cd malcolm && python3 scripts/install.py"
        echo "        Then re-run this script."
        echo ""
        return 1
    fi
    (cd "$SCRIPT_DIR/malcolm" && python3 scripts/start)
    echo "[+] Malcolm ready"
    echo "    OpenSearch Dashboards  https://localhost"
    echo "    Arkime packet capture  https://localhost:8005"
    echo "    File upload            https://localhost:8443"
}

start_rangerdanger() {
    ensure_submodule rangerdanger "$SCRIPT_DIR/rangerdanger"
    echo "[*] Starting RangerDanger (electric substation)..."
    (cd "$SCRIPT_DIR/rangerdanger" && ./setup.sh)
    echo "[+] RangerDanger ready"
    echo "    Topology console  http://localhost:8088"
    echo "    Backend API       http://localhost:9080"
    echo "    containd NGFW     https://localhost:9443"
}

start_containd() {
    ensure_submodule containd "$SCRIPT_DIR/containd"
    echo "[*] Starting containd (ICS-aware NGFW)..."
    (cd "$SCRIPT_DIR/containd" && docker compose up -d)
    echo "[+] containd ready"
    echo "    Web UI  http://localhost:8080  SSH :2222"
}

# ── menu ──────────────────────────────────────────────────────────────────────

print_header

MODULES=(  grfics       labshock      icssim         icsvirtual      conpot     malcolm                              rangerdanger                                        containd )
LABELS=(
    "GRFICSv3     — Chemical plant: OpenPLC, ScadaLTS HMI, Caldera C2 (Modbus/EtherNet-IP)"
    "Labshock     — Multi-protocol SCADA breadth (Modbus · S7 · OPC-UA · BACnet · MQTT)"
    "ICSSIM       — Bottle-filling factory process simulation (Modbus TCP)"
    "ICSsVirtual  — Wastewater treatment plant: OpenPLC + ScadaLTS (Modbus)"
    "Conpot       — ICS/SCADA honeypot (Modbus · S7 · BACnet · IEC-104 · ENIP)"
    "Malcolm      — OT SOC/NSM: Zeek + Suricata + OpenSearch (requires first-run install)"
    "RangerDanger — Electric substation segmentation training (DNP3 · Modbus, IEC 62443 zones)"
    "containd     — ICS-aware NGFW with DPI (Modbus · DNP3 · CIP · S7 · IEC 61850 · BACnet)"
)

echo "Available modules:"
for i in "${!MODULES[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${LABELS[$i]}"
done

echo ""
echo "Options (append to your selection):"
echo "  s  Wazuh SIEM alongside GRFICSv3 (adds Wazuh Manager + OpenSearch + Dashboard)"
echo ""
printf "Enter numbers separated by spaces, or 'a' for all (e.g. '1 3 5 s'): "
read -r INPUT

ENABLE_SIEM=0
[[ "$INPUT" == *s* ]] && ENABLE_SIEM=1
INPUT="${INPUT//s/}"

SELECTED=()
if [[ "$INPUT" =~ (^|[[:space:]])a([[:space:]]|$) || "$INPUT" == "a" ]]; then
    SELECTED=("${MODULES[@]}")
else
    for num in $INPUT; do
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        idx=$((num - 1))
        if [[ $idx -ge 0 && $idx -lt ${#MODULES[@]} ]]; then
            SELECTED+=("${MODULES[$idx]}")
        else
            echo "[!] Ignoring invalid selection: $num"
        fi
    done
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "[!] No modules selected. Exiting."
    exit 1
fi

echo ""
echo "[*] Starting: ${SELECTED[*]}"
[[ "$ENABLE_SIEM" == "1" ]] && echo "[*] Wazuh SIEM enabled"
echo ""

export ENABLE_SIEM

for module in "${SELECTED[@]}"; do
    case "$module" in
        grfics)       start_grfics ;;
        labshock)     start_labshock ;;
        icssim)       start_icssim ;;
        icsvirtual)   start_icsvirtual ;;
        conpot)       start_conpot ;;
        malcolm)      start_malcolm ;;
        rangerdanger) start_rangerdanger ;;
        containd)     start_containd ;;
    esac
    echo ""
done

echo "[*] Active containers:"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -v "^NAMES" | sort || true
