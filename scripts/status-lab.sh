#!/usr/bin/env bash
# status-lab.sh - Show running status of all OT lab modules
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;91m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

running()  { echo -e "${GREEN}RUNNING${NC}"; }
stopped()  { echo -e "${RED}STOPPED${NC}"; }
partial()  { echo -e "${YELLOW}PARTIAL${NC}"; }

# Returns count of running containers matching a pattern
count_running() {
    docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null \
        | grep -c "$1" || true
}

# Returns total containers (running or not) matching a pattern
count_total() {
    docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -c "$1" || true
}

module_status() {
    local pattern="$1" expected="$2"
    local running total
    running=$(count_running "$pattern")
    total=$(count_total "$pattern")
    if   [[ $running -eq 0 ]];           then stopped
    elif [[ $running -ge $expected ]];    then running
    else                                       partial
    fi
}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    OT Lab Module Status                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
printf "  %-20s %-12s %s\n" "Module" "Status" "Services"
printf "  %-20s %-12s %s\n" "------" "------" "--------"

# GRFICSv3 (router, plc, simulation, scadalts, workstation, kali, caldera)
printf "  %-20s " "GRFICSv3"
STATUS=$(module_status "router\|plc\|simulation\|scadalts\|workstation\|kali\|caldera" 5)
echo -ne "$STATUS"
if count_running "router\|plc\|simulation\|scadalts" | grep -qv "^0$" 2>/dev/null; then
    echo -e "        http://localhost (3D sim) · :8080 PLC · :6081 HMI · :8888 Caldera"
else
    echo ""
fi

# Wazuh
printf "  %-20s " "  └ Wazuh SIEM"
STATUS=$(module_status "wazuh" 1)
echo -e "$STATUS        http://localhost:5601"

# Labshock
printf "  %-20s " "Labshock"
STATUS=$(module_status "labshock" 8)
echo -e "$STATUS        :443 portal · :8080 PLC · :1881 SCADA · :1443 IDS · :8443 Splunk"

# ICSSIM
printf "  %-20s " "ICSSIM"
STATUS=$(module_status "icssim\|bottle\|factory" 1)
echo -e "$STATUS        Modbus TCP bottle-filling factory"

# ICSsVirtual
printf "  %-20s " "ICSsVirtual"
STATUS=$(module_status "icsvirtual\|wastewater\|icsnetwork" 1)
echo -e "$STATUS        Modbus TCP wastewater plant"

# Conpot
printf "  %-20s " "Conpot"
STATUS=$(module_status "conpot" 1)
echo -e "$STATUS        :502 Modbus · :102 S7 · :80 HTTP · :47808 BACnet"

# Malcolm
printf "  %-20s " "Malcolm"
STATUS=$(module_status "malcolm\|arkime\|opensearch\|zeek\|suricata" 3)
echo -e "$STATUS        https://localhost (Dashboards) · :8005 Arkime"

# RangerDanger
printf "  %-20s " "RangerDanger"
STATUS=$(module_status "rangerdanger\|rd-\|substation" 1)
echo -e "$STATUS        :8088 console · :9080 API · :9443 containd NGFW"

# containd (standalone — not RangerDanger's bundled copy)
printf "  %-20s " "containd"
STATUS=$(module_status "^containd" 1)
echo -e "$STATUS        :8080 Web UI · :2222 SSH"

echo ""

# Active networks
NETS=$(docker network ls --format '{{.Name}}' 2>/dev/null \
    | grep -E 'grfics|labshock|icssim|icsvirtual|conpot|malcolm|rangerdanger|containd' || true)
if [[ -n "$NETS" ]]; then
    echo "  Active OT networks:"
    echo "$NETS" | while read -r net; do printf "    %s\n" "$net"; done
else
    echo "  No OT networks active."
fi

echo ""

# Running container summary
RUNNING=$(docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null \
    | grep -E 'router|plc|simulation|scadalts|workstation|kali|caldera|wazuh|labshock|icssim|icsvirtual|conpot|malcolm|arkime|opensearch|zeek|suricata|rangerdanger|containd' \
    | sort || true)
if [[ -n "$RUNNING" ]]; then
    COUNT=$(echo "$RUNNING" | wc -l)
    echo "  $COUNT lab container(s) running:"
    echo "$RUNNING" | while read -r name; do printf "    %s\n" "$name"; done
else
    echo "  No lab containers running."
fi
echo ""
