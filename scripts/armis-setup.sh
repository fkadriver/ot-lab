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

# Default values
ARMIS_HOSTNAME="lab-kudelski.armis.com"
ARMIS_API_KEY=""
ARMIS_TENANT_ID=""
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
  --api-key KEY             Armis API token

Optional:
  --hostname HOST           Armis API hostname
                           Default: lab-kudelski.armis.com
                           Options: lab-kudelski.armis.com or custom
  --tenant-id ID            Armis tenant ID (optional)
  --help                   Show this help message

Examples:
  $0 --api-key "abc123def456"
  $0 --api-key "abc123" --hostname "eu.armis.com"
  $0 --api-key "abc123" --hostname "custom.armis.com" --tenant-id "my-tenant"

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
    local tenant_id="$3"
    local env_file="$LAB_DIR/.env.armis"
    
    cat > "$env_file" << EOF
# Armis Integration Configuration
# Source this file before starting the lab with Armis monitoring:
#   source .env.armis
#   docker compose -f docker-compose.yml -f ../overrides/armis-monitoring.yml up -d

# Armis API Configuration
export ARMIS_API_KEY="$api_key"
export ARMIS_HOSTNAME="$hostname"
$([ -n "$tenant_id" ] && echo "export ARMIS_TENANT_ID=\"$tenant_id\"" || echo "# export ARMIS_TENANT_ID=\"your-tenant-id\"")

# Optional: Additional settings
export UPLOAD_INTERVAL="30"      # Seconds between PCAP upload checks
export ARMIS_SYSLOG_HOST="logs.armis.com"
export ARMIS_SYSLOG_PORT="6514"

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

Your Armis credentials have been saved to: $env_file

Next Steps:

1. Navigate to GRFICSv3:
   cd $GRFICS_DIR

2. Load Armis environment variables:
   source $env_file

3. Start the lab with Armis monitoring:
   docker compose \\
     -f docker-compose.yml \\
     -f ../overrides/grfics-override.yml \\
     -f ../overrides/armis-monitoring.yml \\
     up -d

4. Verify Armis is capturing traffic:
   docker logs armis-pcap-capture | tail -20
   docker logs armis-pcap-uploader | tail -20

5. Generate OT traffic to test detection:
   docker exec kali mbpoll -a 1 -r 1 -c 10 192.168.95.2

6. Check Armis console for discovered devices:
   https://$hostname/

Documentation:
- Full integration guide: $LAB_DIR/docs/armis-integration.md
- Sensor setup guide: $LAB_DIR/docs/sensor-setup.md

Troubleshooting:
- Check PCAP capture: docker logs armis-pcap-capture
- Check uploads: docker logs armis-pcap-uploader
- Verify API key: curl -H "Authorization: Bearer \$ARMIS_API_KEY" https://$hostname/api/v1/health

EOF
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
        --tenant-id)
            ARMIS_TENANT_ID="$2"
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

if [[ $SHOW_HELP -eq 1 ]] || [[ -z "$ARMIS_API_KEY" ]]; then
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

# Test connection
if ! test_armis_api "$ARMIS_API_KEY" "$ARMIS_HOSTNAME"; then
    read -p "Continue without verified connection? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create environment file
echo "[*] Creating configuration file..."
create_env_file "$ARMIS_API_KEY" "$ARMIS_HOSTNAME" "$ARMIS_TENANT_ID"

# Show next steps
show_next_steps "$ARMIS_API_KEY" "$ARMIS_HOSTNAME"

echo ""
echo "To get started right now, run:"
echo "  cd $GRFICS_DIR"
echo "  source ../.env.armis"
echo "  docker compose -f docker-compose.yml -f ../overrides/grfics-override.yml -f ../overrides/armis-monitoring.yml up -d"
echo ""
