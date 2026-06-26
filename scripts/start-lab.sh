#!/usr/bin/env bash
# start-lab.sh - Start OT lab modules (interactive or CLI)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

detect_macvlan_parent() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    echo "${iface:-eth0}"
}

set_map_count() {
    local current
    current=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
    if [[ $current -lt 262144 ]]; then
        echo "[*] Setting vm.max_map_count=262144 (required by OpenSearch)..."
        sudo sysctl -w vm.max_map_count=262144
    fi
}

ensure_submodule() {
    local name="$1" path="$2"
    if [[ ! -d "$path" || -z "$(ls -A "$path" 2>/dev/null)" ]]; then
        echo "[*] Initialising $name submodule..."
        git -C "$LAB_DIR" submodule update --init "$name"
    fi
}

# ── module launchers ────────────────────────────────────────────────────────────

start_grfics() {
    ensure_submodule GRFICSv3 "$LAB_DIR/GRFICSv3"
    [[ -z "${MACVLAN_PARENT:-}" ]] && export MACVLAN_PARENT=$(detect_macvlan_parent)
    local compose="-f $LAB_DIR/GRFICSv3/docker-compose.yml -f $LAB_DIR/overrides/grfics-override.yml"
    local profile=""
    if [[ "${SIEM_ENABLED:-0}" == "1" ]]; then
        set_map_count
        profile="--profile siem"
    fi
    echo "[*] Starting GRFICSv3..."
    (cd "$LAB_DIR/GRFICSv3" && docker compose $compose $profile up -d) || \
        echo "[!] docker compose exited with errors — some containers may not have started"
    echo "[+] GRFICSv3 ready"
    echo "    3D Simulation:      http://localhost"
    echo "    OpenPLC:            http://localhost:8080  (openplc / openplc)"
    echo "    ScadaLTS HMI:       http://localhost:6081  (admin / admin)"
    echo "    Engineering WS:     http://localhost:6080"
    echo "    Kali:               http://localhost:6088  (kali / kali)"
    echo "    Caldera C2:         http://localhost:8888  (red / fortiphyd-red)"
    echo "    Router / Firewall:  http://192.168.90.200:5000  (admin / password)"
    [[ "${SIEM_ENABLED:-0}" == "1" ]] && echo "    Wazuh Dashboard:    http://localhost:5601  (admin / admin)"
}

start_labshock() {
    ensure_submodule labshock "$LAB_DIR/labshock"
    echo "[*] Starting Labshock..."
    (cd "$LAB_DIR/labshock" && docker compose up -d)
    echo "[+] Labshock ready — check 'docker logs labshock' for portal URL"
    echo "    Protocols: Modbus RTU/TCP · S7comm · EtherNet/IP · BACnet · OPC UA · MQTT"
}

fix_timezone_file() {
    # Some systems have /etc/timezone as an empty directory instead of a text
    # file. Docker bind-mounting it onto a file inside the container fails.
    if [[ -d /etc/timezone ]]; then
        local tz
        tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
        echo "[*] /etc/timezone is a directory — replacing with file (${tz:-UTC})..."
        sudo rmdir /etc/timezone 2>/dev/null && echo "${tz:-UTC}" | sudo tee /etc/timezone >/dev/null
    fi
}

start_icssim() {
    ensure_submodule icssim "$LAB_DIR/icssim"
    fix_timezone_file
    echo "[*] Starting ICSSIM (bottle-filling factory)..."
    (cd "$LAB_DIR/icssim" && docker compose \
        -f deployments/docker-compose.yml \
        -f "$LAB_DIR/overrides/icssim-override.yml" \
        up -d --build)
    # pys initialises memcached tables before PLCs can connect.
    # Wait for it to report 'started' then restart the PLCs.
    echo "[*] Waiting for physical simulation (pys) to initialise..."
    local retries=20
    until docker logs pys 2>/dev/null | grep -q "\[INFO\] started"; do
        retries=$((retries - 1))
        [[ $retries -le 0 ]] && echo "[!] pys did not start in time" && return 1
        sleep 3
    done
    echo "[*] Restarting PLCs now that pys is ready..."
    docker restart plc1 plc2 >/dev/null
    echo "[+] ICSSIM ready — Modbus TCP factory simulation running"
}

start_icsvirtual() {
    ensure_submodule icsvirtual "$LAB_DIR/icsvirtual"
    echo "[*] Starting ICSsVirtual (wastewater treatment)..."
    (cd "$LAB_DIR/icsvirtual" && docker compose -f network/DockerDeployment/ICSNetwork/docker-compose.yml up -d)
    echo "[+] ICSsVirtual ready — OpenPLC + ScadaLTS wastewater simulation running"
}

start_conpot() {
    ensure_submodule conpot "$LAB_DIR/conpot"
    echo "[*] Starting Conpot (ICS honeypot)..."
    (cd "$LAB_DIR/conpot" && docker compose up -d)
    echo "[+] Conpot ready"
    echo "    Modbus :502 · S7comm :102 · HTTP :80 · BACnet :47808 · IEC-104 :2404"
}

start_malcolm() {
    ensure_submodule malcolm "$LAB_DIR/malcolm"
    set_map_count
    if [[ ! -f "$LAB_DIR/malcolm/.configured" ]]; then
        echo ""
        echo "    [!] Malcolm requires first-run configuration:"
        echo "        cd malcolm && python3 scripts/install.py && touch .configured"
        echo ""
        return 1
    fi
    echo "[*] Starting Malcolm (OT SOC/NSM)..."
    (cd "$LAB_DIR/malcolm" && python3 scripts/start)
    echo "[+] Malcolm ready"
    echo "    OpenSearch Dashboards  https://localhost"
    echo "    Arkime packet capture  https://localhost:8005"
    echo "    File upload            https://localhost:8443"
}

start_rangerdanger() {
    ensure_submodule rangerdanger "$LAB_DIR/rangerdanger"
    echo "[*] Starting RangerDanger (electric substation training)..."
    (cd "$LAB_DIR/rangerdanger" && ./setup.sh)
    echo "[+] RangerDanger ready  (requires 16 GB RAM)"
    echo "    Topology console  http://localhost:8088"
    echo "    Backend API       http://localhost:9080"
    echo "    containd NGFW     https://localhost:9443"
}

start_containd() {
    ensure_submodule containd "$LAB_DIR/containd"
    echo "[*] Starting containd (ICS-aware NGFW)..."
    (cd "$LAB_DIR/containd" && docker compose -f deploy/docker-compose.yml up -d)
    echo "[+] containd ready"
    echo "    Web UI  http://localhost:8080  SSH :2222"
}

dispatch() {
    case "$1" in
        grfics)       start_grfics ;;
        labshock)     start_labshock ;;
        icssim)       start_icssim ;;
        icsvirtual)   start_icsvirtual ;;
        conpot)       start_conpot ;;
        malcolm)      start_malcolm ;;
        rangerdanger) start_rangerdanger ;;
        containd)     start_containd ;;
        *) echo "[!] Unknown module: $1"; exit 1 ;;
    esac
}

# ── interactive menu ────────────────────────────────────────────────────────────

interactive_menu() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              OT/ICS Cybersecurity Lab Launcher               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    local modules=(grfics labshock icssim icsvirtual conpot malcolm rangerdanger containd)
    local labels=(
        "GRFICSv3     — Chemical plant: OpenPLC, ScadaLTS, Caldera C2 (Modbus/EtherNet-IP)"
        "Labshock     — Multi-protocol SCADA breadth (Modbus · S7 · OPC-UA · BACnet · MQTT)"
        "ICSSIM       — Bottle-filling factory process simulation (Modbus TCP)"
        "ICSsVirtual  — Wastewater treatment plant: OpenPLC + ScadaLTS (Modbus)"
        "Conpot       — ICS/SCADA honeypot (Modbus · S7 · BACnet · IEC-104 · ENIP)"
        "Malcolm      — OT SOC/NSM: Zeek + Suricata + OpenSearch (requires first-run install)"
        "RangerDanger — Electric substation segmentation training (DNP3 · Modbus, IEC 62443)"
        "containd     — ICS-aware NGFW with DPI (Modbus · DNP3 · CIP · S7 · IEC 61850)"
    )

    echo "Available modules:"
    for i in "${!modules[@]}"; do
        printf "  %d) %s\n" $((i+1)) "${labels[$i]}"
    done
    echo ""
    echo "Options (append to selection):"
    echo "  s  Wazuh SIEM alongside GRFICSv3"
    echo "  a  All modules"
    echo ""
    printf "Enter numbers separated by spaces (e.g. '1 2 s'): "
    read -r INPUT

    [[ "$INPUT" == *s* ]] && export SIEM_ENABLED=1
    INPUT="${INPUT//s/}"

    local selected=()
    if [[ "$INPUT" =~ (^|[[:space:]])a([[:space:]]|$) || "$INPUT" == "a" ]]; then
        selected=("${modules[@]}")
    else
        for num in $INPUT; do
            [[ "$num" =~ ^[0-9]+$ ]] || continue
            local idx=$((num - 1))
            if [[ $idx -ge 0 && $idx -lt ${#modules[@]} ]]; then
                selected+=("${modules[$idx]}")
            else
                echo "[!] Ignoring invalid selection: $num"
            fi
        done
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "[!] No modules selected. Exiting."
        exit 1
    fi

    echo ""
    echo "[*] Starting: ${selected[*]}"
    [[ "${SIEM_ENABLED:-0}" == "1" ]] && echo "[*] Wazuh SIEM enabled"
    echo ""

    for module in "${selected[@]}"; do
        dispatch "$module"
        echo ""
    done
}

# ── CLI argument handling ───────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [MODULE|all|restart|reset] [MODULE] [--siem]"
    echo ""
    echo "Modules: grfics labshock icssim icsvirtual conpot malcolm rangerdanger containd"
    echo ""
    echo "  all       Start all modules"
    echo "  restart   Stop then start (e.g. restart grfics)"
    echo "  reset     Wipe volumes then start (e.g. reset grfics)"
    echo ""
    echo "  --siem    Enable Wazuh SIEM alongside GRFICSv3"
    echo ""
    echo "Run with no arguments for interactive module selection."
    exit 1
}

# No arguments → interactive menu
if [[ $# -eq 0 ]]; then
    interactive_menu
    echo "[*] Active containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep -v "^NAMES" | sort || true
    exit 0
fi

# Parse flags
ENABLE_SIEM=0
TARGET=""
SECONDARY=""
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --siem) ENABLE_SIEM=1 ;;
        -h|--help) usage ;;
        restart|reset) TARGET="$arg" ;;
        *) ARGS+=("$arg") ;;
    esac
done

[[ $ENABLE_SIEM -eq 1 ]] && export SIEM_ENABLED=1

if [[ -z "$TARGET" ]]; then
    # Direct module start(s) or "all"
    TARGET="${ARGS[0]:-all}"
    if [[ "$TARGET" == "all" ]]; then
        for m in grfics labshock icssim icsvirtual conpot malcolm rangerdanger containd; do
            dispatch "$m"; echo ""
        done
    else
        for m in "${ARGS[@]}"; do
            dispatch "$m"; echo ""
        done
    fi
else
    # restart / reset
    SECONDARY="${ARGS[0]:-all}"
    echo "[*] ${TARGET^}ing $SECONDARY..."
    "$SCRIPT_DIR/stop-lab.sh" "$SECONDARY" $([[ "$TARGET" == "reset" ]] && echo "--wipe")
    if [[ "$SECONDARY" == "all" ]]; then
        for m in grfics labshock icssim icsvirtual conpot malcolm rangerdanger containd; do
            dispatch "$m"; echo ""
        done
    else
        dispatch "$SECONDARY"
    fi
fi

echo ""
echo "[*] Active OT networks:"
docker network ls | grep -E 'grfics|labshock|icssim|icsvirtual|conpot|malcolm|rangerdanger|containd' || echo "    (none yet)"
