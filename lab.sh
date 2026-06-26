#!/usr/bin/env bash
# lab.sh - OT/ICS Lab top-level menu
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_header() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              OT/ICS Cybersecurity Lab                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

while true; do
    print_header
    echo "  1) Status   — Show running status of all lab modules"
    echo "  2) Start    — Start one or more emulators"
    echo "  3) Stop     — Stop one or more emulators"
    echo "  4) Update   — Pull latest repo and submodule updates"
    echo "  5) Exit"
    echo ""
    printf "Select an option [1-5]: "
    read -r choice

    echo ""
    case "$choice" in
        1)
            "$SCRIPT_DIR/scripts/status-lab.sh"
            ;;
        2)
            "$SCRIPT_DIR/scripts/start-lab.sh"
            ;;
        3)
            "$SCRIPT_DIR/scripts/stop-lab.sh"
            ;;
        4)
            "$SCRIPT_DIR/scripts/update-lab.sh"
            ;;
        5|q|Q|exit|quit|"")
            echo "Goodbye."
            break
            ;;
        *)
            echo "[!] Invalid option — enter 1-5."
            ;;
    esac

    echo ""
    printf "Press Enter to return to menu..."
    read -r
done
