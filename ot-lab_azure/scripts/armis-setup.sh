#!/usr/bin/env bash
# armis-setup.sh - Validate and configure Armis integration
#
# Usage:
#   ./scripts/armis-setup.sh --api-key YOUR_KEY --hostname your-tenant.armis.com
#   ./scripts/armis-setup.sh --check-collector YOUR_COLLECTOR_ID

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

ARMIS_HOSTNAME="${ARMIS_HOSTNAME:-}"
ARMIS_API_KEY="${ARMIS_API_KEY:-}"
ARMIS_TENANT_ID="${ARMIS_TENANT_ID:-}"
SHOW_HELP=0
CHECK_COLLECTOR_ID=""

print_banner() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          Armis Network Monitor Integration Setup             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Required:
  --api-key KEY             Armis API token
  --hostname HOST           Armis tenant hostname (e.g. your-tenant.armis.com)

Optional:
  --tenant-id ID            Armis tenant ID
  --check-collector ID      Check registration status of a collector by ID
  --help                    Show this help

Examples:
  $0 --api-key "abc123" --hostname "your-tenant.armis.com"
  $0 --check-collector 1234

EOF
}

validate_api_key() {
    local key="$1"
    if [[ -z "$key" ]]; then echo "ERROR: API key is empty"; return 1; fi
    if [[ ${#key} -lt 10 ]]; then echo "ERROR: API key too short (${#key} chars)"; return 1; fi
    return 0
}

test_armis_api() {
    local api_key="$1"
    local hostname="$2"
    echo "[*] Testing connection to Armis API at $hostname..."
    local token
    token=$(curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "secret_key=$api_key" \
        "https://$hostname/api/v1/access_token/" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: $token" \
        "https://$hostname/api/v1/health/" 2>/dev/null || echo "000")
    case $http_code in
        200) echo "✓ Connected to Armis API"; return 0 ;;
        401) echo "✗ Authentication failed (401)"; return 1 ;;
        000) echo "✗ Could not reach $hostname"; return 1 ;;
        *)   echo "⚠ Unexpected response ($http_code)"; return 0 ;;
    esac
}

create_env_file() {
    local api_key="$1" hostname="$2" tenant_id="$3"
    local env_file="$LAB_DIR/.env.armis"
    cat > "$env_file" << EOF
# Armis Integration Configuration
# Loaded automatically by start-lab.sh when this file exists.

export ARMIS_API_KEY="$api_key"
export ARMIS_HOSTNAME="$hostname"
$([ -n "$tenant_id" ] && echo "export ARMIS_TENANT_ID=\"$tenant_id\"" || true)
EOF
    echo "✓ Created $env_file"
}

show_next_steps() {
    local hostname="$1"
    cat << EOF

╔══════════════════════════════════════════════════════════════╗
║                  Setup Complete!                             ║
╚══════════════════════════════════════════════════════════════╝

Next Steps:

1. Add collector credentials to .env.armis:
   ARMIS_COLLECTOR_ID="<from Armis console>"
   ARMIS_COLLECTOR_LICENSE="<from Armis console>"

2. Start the lab with Armis monitoring:
   ./scripts/start-lab.sh grfics --armis

3. Launch the Armis collector VM:
   source .env.armis
   sudo -E ./scripts/armis-collector-setup.sh

4. Check Armis console for discovered devices:
   https://$hostname/

EOF
}

check_collector() {
    local collector_id="$1"
    local api_key="${ARMIS_API_KEY:-}"
    local hostname="${ARMIS_HOSTNAME:-}"
    [[ -n "$api_key" ]]  || { echo "ERROR: ARMIS_API_KEY not set"; exit 1; }
    [[ -n "$hostname" ]] || { echo "ERROR: ARMIS_HOSTNAME not set"; exit 1; }

    local token
    token=$(curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "secret_key=$api_key" \
        "https://$hostname/api/v1/access_token/" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
    [[ -n "$token" ]] || { echo "✗ Failed to get access token"; exit 1; }

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: $token" \
        "https://$hostname/api/v1/collectors/$collector_id/" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    case $http_code in
        200)
            echo "✓ Collector found:"
            echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', {})
print(f\"  Name:      {d.get('name', 'N/A')}\")
print(f\"  Status:    {d.get('status', 'N/A')}\")
print(f\"  Version:   {d.get('version', 'N/A')}\")
print(f\"  Last seen: {d.get('lastSeen', 'N/A')}\")
" 2>/dev/null || echo "$body" ;;
        404) echo "✗ Collector $collector_id not found" ;;
        401) echo "✗ Authentication failed" ;;
        *)   echo "⚠ Unexpected response ($http_code): $body" ;;
    esac
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --api-key)          ARMIS_API_KEY="$2";    shift 2 ;;
        --hostname)         ARMIS_HOSTNAME="$2";   shift 2 ;;
        --tenant-id)        ARMIS_TENANT_ID="$2";  shift 2 ;;
        --check-collector)  CHECK_COLLECTOR_ID="$2"; shift 2 ;;
        --help)             SHOW_HELP=1; shift ;;
        *) echo "Unknown option: $1"; SHOW_HELP=1; shift ;;
    esac
done

print_banner

if [[ -n "$CHECK_COLLECTOR_ID" ]]; then
    check_collector "$CHECK_COLLECTOR_ID"
    exit $?
fi

if [[ $SHOW_HELP -eq 1 ]] || [[ -z "$ARMIS_API_KEY" ]] || [[ -z "$ARMIS_HOSTNAME" ]]; then
    print_usage
    exit 1
fi

echo "[*] Validating configuration..."
validate_api_key "$ARMIS_API_KEY" || exit 1

test_armis_api "$ARMIS_API_KEY" "$ARMIS_HOSTNAME" \
    || echo "[!] Continuing without verified connection — credentials saved anyway"

echo "[*] Creating configuration file..."
create_env_file "$ARMIS_API_KEY" "$ARMIS_HOSTNAME" "$ARMIS_TENANT_ID"

show_next_steps "$ARMIS_HOSTNAME"
