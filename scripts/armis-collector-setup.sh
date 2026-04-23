#!/usr/bin/env bash
# armis-collector-setup.sh  — Deploy the Armis virtual collector (QCOW2/KVM)
# alongside the GRFICSv3 lab so it can analyze OT network traffic.
#
# What this does:
#   1. Installs qemu-kvm and qemu-utils
#   2. Downloads the Armis collector QCOW2 image (~3.5 GB)
#   3. Creates a TAP interface bridged to the Docker admin network
#   4. Launches the collector VM with:
#        eth0 — user-mode NAT   (internet → Armis cloud)
#        eth1 — TAP on br-XXXX  (lab traffic capture)
#   5. Prints the activation steps
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
#   Collector ID: 8155
#   License key:  2a9d9726e
#   Web UI user:  config
#   Web UI pass:  Armis  (change after first login)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

COLLECTOR_ID=8155
COLLECTOR_LICENSE="2a9d9726e"
COLLECTOR_NAME="GRFICSv3 Lab Collector"
ARMIS_HOSTNAME="${ARMIS_HOSTNAME:-lab-kudelski.armis.com}"
IMAGE_DIR="/opt/armis-collector"
IMAGE_PATH="$IMAGE_DIR/armis-security.qcow2"
TAP_IFACE="tap-armis"
VM_RAM=4096    # MB
VM_CPUS=2
VNC_PORT=5900  # VNC display :0

# ── helpers ──────────────────────────────────────────────────────────────────

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
  # The GRFICSv3 admin network is named grficsv3_a-grfics-admin
  BRIDGE_ID=$(docker network inspect grficsv3_a-grfics-admin --format '{{.Id}}' 2>/dev/null | head -c 12)
  [[ -n "$BRIDGE_ID" ]] || die "GRFICSv3 admin network not found — is the lab running?"
  DOCKER_BRIDGE="br-$BRIDGE_ID"
  ip link show "$DOCKER_BRIDGE" &>/dev/null || die "Bridge interface $DOCKER_BRIDGE not found"
  info "Docker admin bridge: $DOCKER_BRIDGE (172.18.0.0/16)"
}

# ── 5. create tap interface on docker bridge ─────────────────────────────────

setup_tap() {
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

# ── 6. launch vm ─────────────────────────────────────────────────────────────

launch_vm() {
  # Kill any previous instance
  if pgrep -f "armis-collector" &>/dev/null; then
    info "Stopping existing collector VM..."
    pkill -f "armis-collector" || true
    sleep 2
  fi

  info "Starting Armis collector VM..."
  info "  RAM: ${VM_RAM}MB  vCPUs: $VM_CPUS"
  info "  eth0: user-mode NAT (internet/Armis cloud)"
  info "  eth1: TAP on $DOCKER_BRIDGE (lab traffic capture)"
  info "  VNC:  127.0.0.1:$VNC_PORT  (use a VNC client to access the VM console)"

  qemu-system-x86_64 \
    -name "armis-collector" \
    -m "$VM_RAM" \
    -smp "$VM_CPUS" \
    -enable-kvm \
    -cpu host \
    -drive "file=$IMAGE_PATH,format=qcow2,if=virtio,cache=writeback" \
    -netdev "user,id=net0,hostfwd=tcp::18443-:8443" \
    -device "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56" \
    -netdev "tap,id=net1,ifname=$TAP_IFACE,script=no,downscript=no" \
    -device "virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57" \
    -vnc "127.0.0.1:0" \
    -daemonize \
    -pidfile "$IMAGE_DIR/collector.pid"

  sleep 3
  PID=$(cat "$IMAGE_DIR/collector.pid" 2>/dev/null || echo "unknown")
  info "Collector VM started (PID $PID)."
}

# ── 7. print activation instructions ─────────────────────────────────────────

print_activation() {
  cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║            Armis Collector VM is Running                        ║
╚══════════════════════════════════════════════════════════════════╝

The VM is booting. Allow 2–3 minutes for first boot.

── Activate the Collector ──────────────────────────────────────────

1. Open the collector web UI:
   https://localhost:18443
   (port 8443 inside the VM is forwarded to 18443 on the host)

2. Log in with:
   Username:     config
   Password:     Armis

3. Enter the collector details:
   Armis URL:    https://$ARMIS_HOSTNAME
   License Key:  $COLLECTOR_LICENSE
   Collector ID: $COLLECTOR_ID

4. Configure the capture interface:
   - Select the interface connected to the lab network (eth1 / second NIC)
   - This is the TAP bridged to the Docker admin network (172.18.0.0/16)
   - Enable promiscuous mode

5. Save and apply — the collector will connect to Armis cloud.

── Verify ──────────────────────────────────────────────────────────

Check collector status via API:
  source .env.armis
  ./scripts/armis-setup.sh --check-collector $COLLECTOR_ID

Check Armis console (wait 5–10 min after activation):
  https://$ARMIS_HOSTNAME
  → Sensors → Collectors → "GRFICSv3 Lab Collector"

── VM Console ──────────────────────────────────────────────────────

VNC: Connect to 127.0.0.1:$VNC_PORT with any VNC viewer
  vncviewer 127.0.0.1:$VNC_PORT       (if installed)
  Or use Remmina, TigerVNC, etc.

── Stop / Restart ──────────────────────────────────────────────────

  Stop:    sudo pkill -f armis-collector
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
