# Armis Integration - Quick Reference

## Files

```
overrides/armis-monitoring.yml     - Docker Compose for PCAP capture + syslog relay
scripts/armis-setup.sh             - Setup wizard + --check-collector
scripts/armis-collector-setup.sh   - Deploy Armis Collector VM (QCOW2/KVM)
scripts/rsyslog-armis.conf         - Syslog forwarding rules
```

> **Note**: Traffic ingestion to Armis cloud requires the **Collector VM**
> (`armis-collector-setup.sh`). There is no PCAP upload API in Armis v4.5.
> The `armis-pcap-capture` container writes local forensic PCAPs only.

---

## Setup

### Step 1: Configure credentials
```bash
cd /home/sjensen/git/ot-lab
./scripts/armis-setup.sh --api-key "your-api-token-here"
```

### Step 2: Start lab with Armis monitoring
```bash
./scripts/start-lab.sh grfics --armis
```

### Step 3: Deploy the Collector VM
```bash
source .env.armis
sudo -E ./scripts/armis-collector-setup.sh
# Then activate at https://localhost:18443
#   user: config  /  pass: Armis
#   Server: lab-kudelski.armis.com  /  License: 2a9d9726e
```

### Step 4: Verify
```bash
# Collector connected?
./scripts/armis-setup.sh --check-collector 25325

# PCAP capture running?
docker exec armis-pcap-capture ls -lh /pcap

# Generate OT traffic
docker exec kali nmap -p 502 --script modbus-discover 192.168.95.2
```

---

## Components

| Component | Purpose |
|-----------|---------|
| `armis-pcap-capture` | Local forensic PCAP storage (router netns, all traffic) |
| `armis-flow-exporter` | Optional: flow statistics |
| `armis-syslog-relay` | Optional: forwards router/IDS logs to Armis |
| Collector VM (KVM) | Traffic ingestion to Armis cloud — the actual sensor |

---

## Testing Detections

```bash
# Normal Modbus read
docker exec kali nmap -p 502 --script modbus-discover 192.168.95.2

# Scan ICS subnet
docker exec kali nmap -p 502,44818,102,4840 192.168.95.0/24 -T4 --open

# Unauthorized Modbus write (anomalous)
docker exec kali python3 -c "
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient('192.168.95.2')
c.connect()
c.write_coil(address=1, value=True, slave=1)
c.close()
"
```

---

## Environment Variables

```bash
export ARMIS_API_KEY="<your-token>"       # required
export ARMIS_HOSTNAME="lab-kudelski.armis.com"
export ARMIS_SYSLOG_HOST="logs.armis.com" # for syslog relay
export ARMIS_SYSLOG_PORT="6514"
```

---

## Troubleshooting

```bash
# Collector not connecting?
./scripts/armis-setup.sh --check-collector 25325

# No devices in Armis console?
# Wait 5-10 min after first traffic, then check:
# https://lab-kudelski.armis.com → Asset Management → Devices

# PCAP files accumulating?
docker exec armis-pcap-capture ls -lh /pcap

# Collector VM not booting?
~/.local/bin/vncdotool -s localhost capture /tmp/console.png
```

---

## Restart / Stop

```bash
./scripts/start-lab.sh restart grfics --armis   # full restart
./scripts/stop-lab.sh grfics                     # stop (includes Armis containers)

# Collector VM
sudo pkill -f "qemu.*-name armis-collector"      # stop
sudo -E ./scripts/armis-collector-setup.sh       # start
```
