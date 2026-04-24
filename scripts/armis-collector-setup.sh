#!/usr/bin/env bash
# armis-collector-setup.sh  — Deploy the Armis virtual collector (QCOW2/KVM)
# alongside the GRFICSv3 lab so it can analyze OT network traffic.
#
# Network layout:
#   enp0s2 — QEMU user-mode NAT (internet → Armis cloud, web UI on :18443)
#   enp0s3 — TAP on Docker admin bridge (receives tc-mirrored OT traffic)
#
# Pre-requisites:
#   - source .env.armis              (ARMIS_API_KEY must be set)
#   - GRFICSv3 lab must be running   (docker compose up)
#   - sudo access
#
# Usage:
#   cd /home/sjensen/git/ot-lab
#   source .env.armis
#   sudo -E ./scripts/armis-collector-setup.sh
#
# Collector credentials (needed during browser-based activation):
#   URL:          https://lab-kudelski.armis.com
#   Collector ID: 8156
#   License key:  2a9d9726e
#   Web UI user:  config
#   Web UI pass:  Armis  (change after first login)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

COLLECTOR_ID=8156
COLLECTOR_LICENSE="2a9d9726e"
COLLECTOR_NAME="GRFICSv3 Lab Collector"
ARMIS_HOSTNAME="${ARMIS_HOSTNAME:-lab-kudelski.armis.com}"
IMAGE_DIR="/opt/armis-collector"
IMAGE_PATH="$IMAGE_DIR/armis-security.qcow2"
TAP_IFACE="tap-armis"
VM_RAM=4096
VM_CPUS=2
VNC_PORT=5900

# ── helpers ───────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[*] $*"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo -E ./scripts/armis-collector-setup.sh"
}

# ── 1. install qemu ───────────────────────────────────────────────────────────

install_qemu() {
  if command -v qemu-system-x86_64 &>/dev/null; then
    info "QEMU already installed: $(qemu-system-x86_64 --version | head -1)"
    return
  fi
  info "Installing qemu-kvm and qemu-utils..."
  apt-get update -qq
  apt-get install -y qemu-kvm qemu-utils
  info "QEMU installed."
}

# ── 2. fetch armis API token ──────────────────────────────────────────────────

get_token() {
  [[ -n "${ARMIS_API_KEY:-}" ]] || die "ARMIS_API_KEY not set. Run: source .env.armis"
  TOKEN=$(curl -s -X POST "https://$ARMIS_HOSTNAME/api/v1/access_token/" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "secret_key=$ARMIS_API_KEY" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['access_token'])")
  [[ -n "$TOKEN" ]] || die "Failed to obtain Armis access token"
  info "Access token obtained."
}

# ── 3. download qcow2 image ───────────────────────────────────────────────────

download_image() {
  mkdir -p "$IMAGE_DIR"

  if [[ -f "$IMAGE_PATH" ]]; then
    SIZE=$(stat -c%s "$IMAGE_PATH")
    info "Image already present at $IMAGE_PATH ($(numfmt --to=iec $SIZE))"
    return
  fi

  info "Fetching signed download URL..."
  IMAGE_URL=$(curl -s -H "Authorization: $TOKEN" \
    "https://$ARMIS_HOSTNAME/api/v1/collectors/_image/?deploymentType=QCOW2" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['imageUrl'])")
  [[ -n "$IMAGE_URL" ]] || die "Could not get image URL"

  info "Downloading Armis collector QCOW2 (~3.5 GB) to $IMAGE_PATH ..."
  curl -L --progress-bar -o "$IMAGE_PATH" "$IMAGE_URL"
  info "Download complete."
}

# ── 4. find docker admin bridge ──────────────────────────────────────────────

find_docker_bridge() {
  BRIDGE_ID=$(docker network inspect grficsv3_a-grfics-admin --format '{{.Id}}' 2>/dev/null | head -c 12)
  [[ -n "$BRIDGE_ID" ]] || die "GRFICSv3 admin network not found — is the lab running?"
  DOCKER_BRIDGE="br-$BRIDGE_ID"
  ip link show "$DOCKER_BRIDGE" &>/dev/null || die "Bridge interface $DOCKER_BRIDGE not found"
  info "Docker admin bridge: $DOCKER_BRIDGE (172.18.0.0/16)"
}

# ── 5. create tap on docker admin bridge ─────────────────────────────────────

setup_tap() {
  # Clean up any leftover macvtap from previous setup attempt
  if ip link show "macvtap-armis" &>/dev/null; then
    info "Removing stale macvtap-armis interface..."
    ip link del "macvtap-armis" 2>/dev/null || true
  fi

  if ip link show "$TAP_IFACE" &>/dev/null; then
    info "TAP interface $TAP_IFACE already exists."
  else
    info "Creating TAP interface $TAP_IFACE on $DOCKER_BRIDGE..."
    ip tuntap add dev "$TAP_IFACE" mode tap
    ip link set "$TAP_IFACE" up
    ip link set "$TAP_IFACE" master "$DOCKER_BRIDGE"
    info "TAP $TAP_IFACE attached to bridge $DOCKER_BRIDGE."
  fi
}

# ── 6. launch vm ──────────────────────────────────────────────────────────────

launch_vm() {
  if pgrep -f "qemu.*-name armis-collector" &>/dev/null; then
    info "Stopping existing collector VM..."
    pkill -f "qemu.*-name armis-collector" || true
    sleep 2
  elif [[ -f "$IMAGE_DIR/collector.pid" ]]; then
    local pid
    pid=$(cat "$IMAGE_DIR/collector.pid")
    if kill -0 "$pid" 2>/dev/null; then
      info "Stopping existing collector VM (PID $pid)..."
      kill "$pid" || true
      sleep 2
    fi
  fi

  info "Starting Armis collector VM..."
  info "  RAM: ${VM_RAM}MB  vCPUs: $VM_CPUS"
  info "  enp0s2: user-mode NAT (internet/Armis cloud)"
  info "  enp0s3: TAP on $DOCKER_BRIDGE (tc-mirrored OT traffic)"
  info "  VNC:  127.0.0.1:$VNC_PORT"

  qemu-system-x86_64 \
    -name "armis-collector" \
    -machine q35 \
    -m "$VM_RAM" \
    -smp "$VM_CPUS" \
    -enable-kvm \
    -cpu host \
    -drive "if=pflash,format=raw,readonly=on,file=/usr/share/ovmf/OVMF.fd" \
    -drive "file=$IMAGE_PATH,format=qcow2,if=virtio,cache=writeback" \
    -netdev "user,id=net0,hostfwd=tcp::18443-:8443" \
    -device "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56" \
    -netdev "tap,id=net1,ifname=$TAP_IFACE,script=no,downscript=no" \
    -device "virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57" \
    -serial "file:$IMAGE_DIR/serial.log" \
    -vnc "127.0.0.1:0" \
    -daemonize \
    -pidfile "$IMAGE_DIR/collector.pid"

  sleep 3
  local pid
  pid=$(cat "$IMAGE_DIR/collector.pid" 2>/dev/null || echo "unknown")
  info "Collector VM started (PID $pid)."
}

# ── 7. print activation instructions ─────────────────────────────────────────

print_activation() {
  cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║            Armis Collector VM is Running                         ║
╚══════════════════════════════════════════════════════════════════╝

The VM is booting. Allow 2–3 minutes for first boot.

── Network Layout ───────────────────────────────────────────────────
  enp0s2  QEMU NAT — internet / Armis cloud (10.0.2.x)
  enp0s3  TAP on admin bridge — receives tc-mirrored OT traffic
          IP Routing: OFF  (passive capture interface)
          No IP address needed

── Activate the Collector ──────────────────────────────────────────
1. Open:  https://localhost:18443  (user: config / pass: Armis)

2. Enter:
   Armis URL:    https://$ARMIS_HOSTNAME
   License Key:  $COLLECTOR_LICENSE
   Collector ID: $COLLECTOR_ID

── Verify ──────────────────────────────────────────────────────────
  source .env.armis
  ./scripts/armis-setup.sh --check-collector $COLLECTOR_ID

── Stop / Restart ──────────────────────────────────────────────────
  Stop:    sudo pkill -f "qemu.*-name armis-collector"
  Restart: sudo -E ./scripts/armis-collector-setup.sh

EOF
}

# ── main ─────────────────────────────────────────────────────────────────────

require_root
install_qemu
get_token
download_image
find_docker_bridge
setup_tap
launch_vm
print_activation
