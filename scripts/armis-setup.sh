#!/usr/bin/env bash
# armis-setup.sh - Quick setup for Armis integration
# 
# This script validates and configures Armis integration for your OT lab.
# 
# Usage:
#   ./scripts/armis-setup.sh --api-key YOUR_API_KEY [--hostname lab-kudelski.armis.com]
#   
# Example:
#   ./scripts/armis-setup.sh --api-key "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"
GRFICS_DIR="$LAB_DIR/GRFICSv3"

# Preserve env vars if already set (e.g. from source .env.armis)
ARMIS_HOSTNAME="${ARMIS_HOSTNAME:-}"
ARMIS_API_KEY="${ARMIS_API_KEY:-}"
ARMIS_COLLECTOR_ACTIVATION_KEY="${ARMIS_COLLECTOR_ACTIVATION_KEY:-}"
ARMIS_COLLECTOR_PASSWORD="${ARMIS_COLLECTOR_PASSWORD:-}"
SHOW_HELP=0

# ============================================================================
# Functions
# ============================================================================

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
  --api-key KEY             Armis secret key (Settings → API)
  --hostname HOST           Armis tenant hostname (e.g. your-tenant.armis.com)
  --activation-key KEY      Collector Activation Key (Add Virtual Collector wizard → Summary)
  --collector-password PASS Collector Tenant Password (same wizard page)

Optional:
  --help                    Show this help message

Examples:
  $0 --api-key "abc123" --hostname "your-tenant.armis.com" \
     --activation-key "8d0758e54" --collector-password "hunter2"

EOF
}

validate_api_key() {
    local key="$1"
    
    # Basic validation: should look like a UUID or token
    if [[ -z "$key" ]]; then
        echo "ERROR: API key is empty"
        return 1
    fi
    
    if [[ ${#key} -lt 10 ]]; then
        echo "ERROR: API key seems too short (got ${#key} characters)"
        return 1
    fi
    
    return 0
}

validate_hostname() {
    local host="$1"
    
    if [[ ! "$host" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
        echo "WARNING: Hostname doesn't look valid: $host"
        return 1
    fi
    
    return 0
}

test_armis_api() {
    local api_key="$1"
    local hostname="$2"
    
    echo "[*] Testing connection to Armis API at $hostname..."
    
    local token=$(curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "secret_key=$api_key" \
        "https://$hostname/api/v1/access_token/" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)
    local response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: $token" \
        "https://$hostname/api/v1/health/" \
        2>/dev/null || echo "000")
    
    local http_code=$(echo "$response" | tail -1)
    
    case $http_code in
        200)
            echo "✓ Successfully connected to Armis API"
            return 0
            ;;
        401)
            echo "✗ Authentication failed (401). Check your API key."
            return 1
            ;;
        403)
            echo "✗ Forbidden (403). Check permissions."
            return 1
            ;;
        000)
            echo "✗ Could not reach $hostname. Check hostname and network."
            return 1
            ;;
        *)
            echo "⚠ Unexpected response ($http_code). Continuing anyway..."
            return 0
            ;;
    esac
}

create_env_file() {
    local api_key="$1"
    local hostname="$2"
    local activation_key="$3"
    local collector_password="$4"
    local env_file="$LAB_DIR/.env.armis"

    cat > "$env_file" << EOF
# Armis Integration Configuration
# Loaded automatically by start-lab.sh when this file exists.
# Usage: ./scripts/start-lab.sh grfics --armis

export ARMIS_API_KEY="$api_key"
export ARMIS_HOSTNAME="$hostname"

# Virtual Collector — from Add Virtual Collector wizard → Summary
export ARMIS_COLLECTOR_ACTIVATION_KEY="$activation_key"
export ARMIS_COLLECTOR_PASSWORD="$collector_password"
EOF

    echo "✓ Created $env_file"
    return 0
}

show_next_steps() {
    local env_file="$LAB_DIR/.env.armis"
    local api_key="$1"
    local hostname="$2"
    
    cat << EOF

╔══════════════════════════════════════════════════════════════╗
║                  Setup Complete!                             ║
╚══════════════════════════════════════════════════════════════╝

Credentials saved to: $env_file

Next Steps:

1. Add collector credentials to .env.armis
   (from Armis console: Settings → Sensors & Collectors → Add Virtual Collector → Summary):
   ARMIS_COLLECTOR_ACTIVATION_KEY="<activation key>"
   ARMIS_COLLECTOR_PASSWORD="<tenant password>"

2. Start the lab with Armis monitoring:
   ./scripts/start-lab.sh grfics --armis

3. Launch the Armis collector VM (required for traffic ingestion):
   source .env.armis
   sudo -E ./scripts/armis-collector-setup.sh

4. Activate via the Collector Config Interface (instructions printed by step 3).

5. Check Armis console for discovered devices:
   https://$hostname/

Troubleshooting:
- Monitoring logs:  docker logs armis-pcap-capture
- Serial console:   tail -f /opt/armis-collector/serial.log

EOF
}

check_collector() {
    local collector_id="$1"
    local api_key="${ARMIS_API_KEY:-}"
    local hostname="${ARMIS_HOSTNAME}"

    [[ -n "$api_key" ]] || { echo "ERROR: ARMIS_API_KEY not set. Run: source .env.armis"; exit 1; }

    echo "[*] Getting access token..."
    local token
    token=$(curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "secret_key=$api_key" \
        "https://$hostname/api/v1/access_token/" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('access_token',''))" 2>/dev/null)

    [[ -n "$token" ]] || { echo "✗ Failed to get access token"; exit 1; }

    echo "[*] Checking collector $collector_id..."
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: $token" \
        "https://$hostname/api/v1/collectors/$collector_id/" 2>/dev/null)

    local http_code body
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    case $http_code in
        200)
            echo "✓ Collector found:"
            echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', {})
print(f\"  Name:    {d.get('name', 'N/A')}\")
print(f\"  Status:  {d.get('status', 'N/A')}\")
print(f\"  Version: {d.get('version', 'N/A')}\")
print(f\"  Last seen: {d.get('lastSeen', 'N/A')}\")
" 2>/dev/null || echo "$body"
            ;;
        404)
            echo "✗ Collector $collector_id not found (not yet registered or wrong ID)"
            ;;
        401)
            echo "✗ Authentication failed — check ARMIS_API_KEY"
            ;;
        *)
            echo "⚠ Unexpected response ($http_code): $body"
            ;;
    esac
}

# ============================================================================
# Main
# ============================================================================

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --api-key)
            ARMIS_API_KEY="$2"
            shift 2
            ;;
        --hostname)
            ARMIS_HOSTNAME="$2"
            shift 2
            ;;
        --activation-key)
            ARMIS_COLLECTOR_ACTIVATION_KEY="$2"
            shift 2
            ;;
        --collector-password)
            ARMIS_COLLECTOR_PASSWORD="$2"
            shift 2
            ;;
        --help)
            SHOW_HELP=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            SHOW_HELP=1
            shift
            ;;
    esac
done

print_banner

if [[ $SHOW_HELP -eq 1 ]] || [[ -z "$ARMIS_API_KEY" ]] || [[ -z "$ARMIS_HOSTNAME" ]]; then
    print_usage
    exit 1
fi

# Validate inputs
echo "[*] Validating configuration..."

if ! validate_api_key "$ARMIS_API_KEY"; then
    exit 1
fi

if ! validate_hostname "$ARMIS_HOSTNAME"; then
    echo "    Continuing anyway..."
fi

# Test connection (non-blocking — DNS may be unavailable in air-gapped or VPN-only setups)
test_armis_api "$ARMIS_API_KEY" "$ARMIS_HOSTNAME" || echo "[!] Continuing without verified connection — credentials saved anyway"

# Create environment file
echo "[*] Creating configuration file..."
create_env_file "$ARMIS_API_KEY" "$ARMIS_HOSTNAME" "$ARMIS_COLLECTOR_ACTIVATION_KEY" "$ARMIS_COLLECTOR_PASSWORD"

# Show next steps
show_next_steps "$ARMIS_API_KEY" "$ARMIS_HOSTNAME"

echo "To get started right now:"
echo "  ./scripts/start-lab.sh grfics --armis"
echo ""
