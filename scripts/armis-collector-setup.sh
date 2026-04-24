#!/usr/bin/env bash
# armis-collector-setup.sh  — Deploy the Armis virtual collector (QCOW2/KVM)
# alongside the GRFICSv3 lab so it can analyze OT network traffic.
#
# Network layout:
#   enp0s2 — QEMU user-mode NAT (internet → Armis cloud, web UI on :18443)
#   enp0s3 — macvtap on host eth0 (native on macvlan L2; tc mirrors all OT traffic here)
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
MACVTAP_IFACE="macvtap-armis"
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

# ── 4. create macvtap on host's default NIC ───────────────────────────────────

setup_macvtap() {
  # Detect the default-route interface (same parent the Docker macvlan networks use)
  local parent
  parent=$(ip route show default | awk '/default/ {print $5; exit}')
  [[ -n "$parent" ]] || die "Could not determine default network interface"

  # Remove stale TAP-on-bridge interface if leftover from previous setup
  if ip link show "tap-armis" &>/dev/null; then
    info "Removing old tap-armis interface..."
    ip link del "tap-armis" 2>/dev/null || true
  fi

  if ip link show "$MACVTAP_IFACE" &>/dev/null; then
    info "macvtap $MACVTAP_IFACE already exists (parent $parent)."
  else
    info "Creating macvtap $MACVTAP_IFACE on parent $parent..."
    ip link add link "$parent" name "$MACVTAP_IFACE" type macvtap mode bridge
    ip link set "$MACVTAP_IFACE" up
    ip link set "$MACVTAP_IFACE" promisc on
    info "macvtap created."
  fi

  MACVTAP_IFINDEX=$(cat "/sys/class/net/$MACVTAP_IFACE/ifindex")
  MACVTAP_DEV="/dev/tap${MACVTAP_IFINDEX}"
  MACVTAP_MAC=$(cat "/sys/class/net/$MACVTAP_IFACE/address")
  MACVTAP_PARENT="$parent"
  info "macvtap: dev=$MACVTAP_DEV  mac=$MACVTAP_MAC  parent=$parent"
}

# ── 5. apply tc SPAN mirrors on host ─────────────────────────────────────────

setup_span() {
  info "Applying tc SPAN mirrors: $MACVTAP_PARENT ingress+egress → $MACVTAP_IFACE"
  tc qdisc add dev "$MACVTAP_PARENT" clsact 2>/dev/null || true
  tc filter replace dev "$MACVTAP_PARENT" ingress protocol all \
    u32 match u32 0 0 action mirred egress mirror dev "$MACVTAP_IFACE"
  tc filter replace dev "$MACVTAP_PARENT" egress  protocol all \
    u32 match u32 0 0 action mirred egress mirror dev "$MACVTAP_IFACE"
  info "SPAN mirrors active."
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
  info "  enp0s3: macvtap on $MACVTAP_PARENT (OT traffic capture)"
  info "  VNC:  127.0.0.1:$VNC_PORT"

  # Pre-open the macvtap character device; QEMU inherits the fd across daemonize fork
  local macvtap_fd=20
  eval "exec ${macvtap_fd}<>\"${MACVTAP_DEV}\""

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
    -netdev "tap,id=net1,fd=${macvtap_fd},vhost=off" \
    -device "virtio-net-pci,netdev=net1,mac=${MACVTAP_MAC}" \
    -serial "file:$IMAGE_DIR/serial.log" \
    -vnc "127.0.0.1:0" \
    -daemonize \
    -pidfile "$IMAGE_DIR/collector.pid"

  # Close our copy of the fd (QEMU daemon keeps its own)
  eval "exec ${macvtap_fd}>&-"

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
  enp0s2  QEMU user-mode NAT — internet / Armis cloud (10.0.2.x)
  enp0s3  macvtap on $MACVTAP_PARENT — native on OT macvlan networks
          Assign 192.168.90.x in Armis console (Optional)
          IP Routing: OFF (passive capture interface)

── Activate the Collector ──────────────────────────────────────────
1. Open the collector web UI:
   https://localhost:18443

2. Log in:   config / Armis

3. Enter details:
   Armis URL:    https://$ARMIS_HOSTNAME
   License Key:  $COLLECTOR_LICENSE
   Collector ID: $COLLECTOR_ID

── Verify ──────────────────────────────────────────────────────────
  source .env.armis
  ./scripts/armis-setup.sh --check-collector $COLLECTOR_ID

  https://$ARMIS_HOSTNAME → Sensors → Collectors → "$COLLECTOR_NAME"

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
setup_macvtap
setup_span
launch_vm
print_activation
