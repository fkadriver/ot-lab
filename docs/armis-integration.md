# Armis Network Monitor Integration Guide

This guide covers multiple approaches to integrate Armis into your OT lab environments (GRFICSv3 and Labshock).

---

## Overview: How Armis Works

Armis is a **cloud-based, agentless network security platform** focused on device-centric analysis. Unlike traditional on-premises sensors, Armis analyzes traffic via:

1. **Network traffic feeds** (PCAP, Netflow, syslog)
2. **API integrations** with security tools and network devices
3. **Cloud-side correlation** of device behavior and vulnerabilities
4. **No sensors required** — pure passive analysis of network telemetry

---

## Integration Approach 1: PCAP Feed to Armis Cloud (Recommended)

Capture OT protocol traffic from your lab and forward it to Armis.

### Setup Steps

#### 1. Create a PCAP Capture Container (Option A)

Add this service to `GRFICSv3/docker-compose.yml`:

```yaml
  armis-monitor:
    image: nicolaka/netshoot
    container_name: armis-monitor
    cap_add:
      - NET_ADMIN
    command: tcpdump -i eth0 -w - port 502 or port 44818 or port 102 or port 4840
    networks:
      b-ics-net:
    volumes:
      - ./pcap-output:/pcap
    stdout:
      # Routes packet capture to file for upload
      file: /pcap/ot-lab-capture.pcap
```

#### 2. Configure Automated Upload to Armis

Create a sidecar container that periodically uploads PCAP to Armis:

```yaml
  armis-uploader:
    image: python:3.10
    container_name: armis-uploader
    depends_on:
      - armis-monitor
    environment:
      ARMIS_API_KEY: ${ARMIS_API_KEY}
      ARMIS_HOSTNAME: ${ARMIS_HOSTNAME}  # lab-kudelski.armis.com
    volumes:
      - ./pcap-output:/pcap:ro
      - ./scripts/armis-upload.py:/app/upload.py
    command: python /app/upload.py
```

**Script:** `scripts/armis-upload.py`

```python
#!/usr/bin/env python3
"""
Periodic PCAP uploader to Armis cloud API
"""
import os
import requests
import time
import glob
from pathlib import Path

ARMIS_API_KEY = os.getenv("ARMIS_API_KEY")
ARMIS_HOSTNAME = os.getenv("ARMIS_HOSTNAME", "lab-kudelski.armis.com")
PCAP_DIR = "/pcap"

def upload_pcap(filename):
    """Upload PCAP file to Armis"""
    url = f"https://{ARMIS_HOSTNAME}/api/v1/uploads/pcap"
    
    headers = {
        "Authorization": f"Bearer {ARMIS_API_KEY}",
    }
    
    with open(filename, 'rb') as f:
        files = {'file': f}
        try:
            response = requests.post(url, headers=headers, files=files)
            response.raise_for_status()
            print(f"✓ Uploaded {filename} to Armis")
            Path(filename).unlink()  # Delete after successful upload
            return True
        except requests.exceptions.RequestException as e:
            print(f"✗ Failed to upload {filename}: {e}")
            return False

def monitor_and_upload():
    """Monitor PCAP directory and upload files"""
    processed = set()
    
    while True:
        for pcap_file in glob.glob(f"{PCAP_DIR}/*.pcap"):
            if pcap_file not in processed:
                print(f"Found PCAP: {pcap_file}")
                upload_pcap(pcap_file)
                processed.add(pcap_file)
        
        time.sleep(10)  # Check every 10 seconds

if __name__ == "__main__":
    print("Starting Armis PCAP uploader...")
    monitor_and_upload()
```

### Usage

```bash
# Set your Armis credentials
export ARMIS_API_KEY="your-armis-api-key"
export ARMIS_HOSTNAME="lab-kudelski.armis.com"

# Start lab with Armis monitoring
cd GRFICSv3
docker compose -f docker-compose.yml -f armis-compose.yml up -d
```

---

## Integration Approach 2: Netflow/sFlow Export

Many OT environments use Netflow for visibility. Armis ingests Netflow v5/v9 and sFlow.

### Setup

#### 1. Add Flow Exporter Container

Add to `GRFICSv3/docker-compose.yml`:

```yaml
  flow-exporter:
    image: ntop/ntopng
    container_name: flow-exporter
    cap_add:
      - NET_ADMIN
    environment:
      COLLECTOR_PORT: 2055
    ports:
      - "3000:3000"  # Web UI
      - "2055:2055/udp"  # sFlow collector
    networks:
      a-grfics-admin:
      b-ics-net:
    volumes:
      - ntopng_data:/var/lib/ntopng
    command: >
      ntopng 
      -i br-${DOCKER_NETWORK_ID}
      -w 3000
      --sflow-collector-port 2055
```

#### 2. Configure Armis Netflow Ingestion

In Armis platform:
1. Go to **Settings > Integrations > Data Collectors**
2. Add **Netflow Collector**
3. Configure:
   - **Collector IP**: Your lab host IP (or Docker host)
   - **Collector Port**: 2055 (UDP)
   - **Version**: NetFlow v9 (preferred)

#### 3. Push Netflow to Armis

Once Netflow is flowing locally, configure ntopng to export to Armis:

```yaml
  flow-exporter:
    command: >
      ntopng 
      -i eth0
      -w 3000
      --sflow-collector-port 2055
      --netflow-collector-port 2055
      --send-netflow-to-collector <ARMIS_NETFLOW_ENDPOINT>:2055
```

---

## Integration Approach 3: Syslog Integration for Alert Forwarding

Forward GRFICSv3 router/firewall/IDS logs to Armis via syslog.

### Setup

#### 1. Enable Syslog on Router

Edit `GRFICSv3/router/app.py` to forward ulogd logs:

```python
import syslog

# In the firewall rule update handler:
def log_rule_action(action, rule):
    syslog.syslog(
        syslog.LOG_WARNING,
        f"OT_FIREWALL: {action} - {rule['action']} {rule['src']} -> {rule['dst']}:{rule.get('dport', '*')}"
    )
```

#### 2. Configure rsyslog to Forward to Armis

Add to router container's `/etc/rsyslog.d/armis.conf`:

```conf
# Forward OT logs to Armis syslog collector
$ModLoad imudp
$UDPServerRun 514

# Parse and forward
:programname, isequal, "OT_FIREWALL" @@logs.armis.com:6514
:programname, isequal, "SURICATA" @@logs.armis.com:6514

# Keep local copy
*.* /var/log/armis-forwarded.log
```

#### 3. Enable TLS for Secure Delivery

```conf
$DefaultNetstreamDriver gtls
$DefaultNetstreamDriverCAFile /etc/ssl/certs/ca-certificates.crt
$DefaultNetstreamDriverCertFile /etc/ssl/certs/rsyslog-cert.pem
$DefaultNetstreamDriverKeyFile /etc/ssl/private/rsyslog-key.pem

:programname, isequal, "OT_FIREWALL" @@logs.armis.com:6514
```

#### 4. Configure in Armis Platform

In Armis:
1. **Settings > Integrations > Syslog Collector**
2. Configure to listen on port 514 (or 6514 for TLS)
3. Map OT_FIREWALL logs to **Infrastructure** device class

---

## Integration Approach 4: Direct API Integration (Advanced)

Query Armis API from your lab to correlate detections with attacks.

### Use Case

When Caldera attack executes on Kali, query Armis to see what it detected:

```python
# File: GRFICSv3/scripts/armis-query.py

import requests
import json

class ArmisClient:
    def __init__(self, api_key, tenant_hostname="lab-kudelski.armis.com"):
        self.api_key = api_key
        self.base_url = f"https://{tenant_hostname}/api/v1"
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        })
    
    def get_devices(self, filters=None):
        """List all discovered devices"""
        endpoint = "/devices"
        params = {"limit": 100}
        if filters:
            params.update(filters)
        
        resp = self.session.get(f"{self.base_url}{endpoint}", params=params)
        resp.raise_for_status()
        return resp.json()['results']
    
    def get_device_by_ip(self, ip_address):
        """Find device by IP"""
        devices = self.get_devices({"ipAddress": ip_address})
        return devices[0] if devices else None
    
    def get_alerts(self, device_id=None, limit=50):
        """Get security alerts"""
        endpoint = "/alerts"
        params = {"limit": limit}
        if device_id:
            params["deviceId"] = device_id
        
        resp = self.session.get(f"{self.base_url}{endpoint}", params=params)
        resp.raise_for_status()
        return resp.json()['results']
    
    def get_device_vulnerabilities(self, device_id):
        """Get vulnerabilities for device"""
        endpoint = f"/devices/{device_id}/vulnerabilities"
        
        resp = self.session.get(f"{self.base_url}{endpoint}")
        resp.raise_for_status()
        return resp.json()['results']

# Example: Monitor PLC for anomalies
if __name__ == "__main__":
    client = ArmisClient(api_key="your-armis-api-key")
    
    # Find PLC by IP
    plc = client.get_device_by_ip("192.168.95.2")
    if plc:
        print(f"PLC: {plc['deviceName']} ({plc['type']})")
        
        # Check for alerts
        alerts = client.get_alerts(device_id=plc['id'])
        print(f"Active Alerts: {len(alerts)}")
        for alert in alerts[:5]:
            print(f"  - {alert['title']}: {alert['description']}")
        
        # Check vulnerabilities
        vulns = client.get_device_vulnerabilities(plc['id'])
        print(f"Known Vulnerabilities: {len(vulns)}")
        for vuln in vulns[:3]:
            print(f"  - {vuln['cveId']}: {vuln['severity']}")
```

### Usage with Caldera

```python
# File: GRFICSv3/scripts/caldera-armis-integration.py
# Run this to execute a Caldera attack and monitor Armis detections

import subprocess
import json
import time
from armis_query import ArmisClient

CALDERA_URL = "http://localhost:8888"
ARMIS_API_KEY = os.getenv("ARMIS_API_KEY")

def run_caldera_operation(operation_id):
    """Execute Caldera operation"""
    # POST to Caldera API to start operation
    subprocess.run([
        "curl", "-X", "POST",
        f"{CALDERA_URL}/api/v2/operations",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"operation": operation_id})
    ])

def monitor_armis_detections(device_ip, duration=300):
    """Monitor Armis for detections during attack"""
    client = ArmisClient(ARMIS_API_KEY)
    
    device = client.get_device_by_ip(device_ip)
    if not device:
        print(f"Device {device_ip} not found in Armis")
        return
    
    print(f"Monitoring {device['deviceName']} for {duration}s...")
    
    start_time = time.time()
    while time.time() - start_time < duration:
        alerts = client.get_alerts(device_id=device['id'])
        
        if alerts:
            print(f"\n[!] {len(alerts)} alerts detected:")
            for alert in alerts:
                print(f"    {alert['severity']}: {alert['title']}")
        
        time.sleep(10)

if __name__ == "__main__":
    # Run attack
    run_caldera_operation("ics-attack-scenario-1")
    
    # Monitor Armis for 5 minutes
    monitor_armis_detections("192.168.95.2", duration=300)
```

---

## Integration Approach 5: Docker Compose Override File

Recommended approach: Create a separate Armis compose file and merge with lab.

### File: `overrides/armis-monitoring.yml`

```yaml
version: '3.8'

services:
  # Packet capture sidecar
  packet-capture:
    image: tcpdump:latest
    container_name: armis-capture
    cap_add:
      - NET_ADMIN
    command: |
      tcpdump -i eth0 
      -w - 
      -U
      'port 502 or port 44818 or port 102 or port 4840 or tcp port 5000'
    networks:
      a-grfics-admin:
      b-ics-net:
    volumes:
      - ./pcap:/pcap
  
  # Continuous PCAP uploader
  armis-pcap-forwarder:
    image: python:3.10-slim
    container_name: armis-forwarder
    depends_on:
      - packet-capture
    environment:
      ARMIS_API_KEY: ${ARMIS_API_KEY:-}
      ARMIS_HOSTNAME: ${ARMIS_HOSTNAME:-lab-kudelski.armis.com}
      ARMIS_TENANT_ID: ${ARMIS_TENANT_ID:-}
    volumes:
      - ./pcap:/pcap:ro
      - ./scripts/armis-forward.py:/app/main.py
    working_dir: /app
    command: bash -c "pip install requests && python main.py"

  # Flow statistics exporter (optional)
  network-stats:
    image: nicolaka/netshoot
    container_name: ot-netflow
    cap_add:
      - NET_ADMIN
    networks:
      b-ics-net:
    command: |
      bash -c "
      while true; do
        ss -i 'sport = :502 or sport = :44818' | tail -n +2 >> /stats/connections.log
        sleep 30
      done
      "
    volumes:
      - ./flow-stats:/stats
```

### Usage

```bash
cd GRFICSv3

# Set Armis credentials
export ARMIS_API_KEY="<your-api-key>"
export ARMIS_HOSTNAME="lab-kudelski.armis.com"
export ARMIS_TENANT_ID="<your-tenant-id>"

# Start with Armis monitoring
docker compose \
  -f docker-compose.yml \
  -f ../overrides/grfics-override.yml \
  -f ../overrides/armis-monitoring.yml \
  up -d

# Verify services
docker ps | grep armis
```

---

## Obtaining Armis Credentials

### Trial / Proof-of-Concept Access

1. **Request a trial** at https://www.armis.com/platform/
2. **Get API key** from Armis console:
   - Settings > API > Generate Token
3. **Note tenant hostname**:
   - US: `lab-kudelski.armis.com`
   - EU: `eu.armis.com`
   - Dedicated: Your custom hostname

### Environment Setup

```bash
# Add to .env or export manually
ARMIS_API_KEY="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ARMIS_HOSTNAME="lab-kudelski.armis.com"
ARMIS_TENANT_ID="your-tenant-id"  # Optional; some APIs don't require it
```

---

## Testing Integration

### 1. Verify Device Discovery

```bash
# Query Armis API to confirm your devices are discovered
curl -H "Authorization: Bearer $ARMIS_API_KEY" \
  https://lab-kudelski.armis.com/api/v1/devices \
  | jq '.results[] | {id, deviceName, ipAddress, type}'
```

Expected output:
```json
{
  "id": "d123456",
  "deviceName": "PLC-192.168.95.2",
  "ipAddress": "192.168.95.2",
  "type": "Programmable Logic Controller"
}
```

### 2. Trigger Modbus Anomaly

From Kali container:

```bash
# Install mbpoll (Modbus client)
apt-get install -y mbpoll

# Normal read (allowed)
mbpoll -a 1 -r 1 -c 10 192.168.95.2

# Anomalous write (may be blocked by firewall)
mbpoll -a 1 -t 0 -1 192.168.95.2 1

# Check Armis alerts
curl -H "Authorization: Bearer $ARMIS_API_KEY" \
  https://lab-kudelski.armis.com/api/v1/alerts \
  | jq '.results[] | select(.severity == "High")'
```

### 3. Monitor Firewall Events

```bash
# Trigger a blocked connection from Kali
ssh admin@192.168.90.200 "nc -zv 192.168.95.2 502"

# Check Armis for network anomaly alerts
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `PCAP upload fails (401)` | Verify API key and tenant hostname are correct |
| `No devices discovered in Armis` | Ensure traffic flows through capture interface; check tcpdump is working |
| `Alerts don't appear in Armis UI immediately` | Cloud processing takes 2-5 minutes; refresh your browser |
| `PCAP file grows too large` | Reduce capture filter (`port 502 or port 44818`); rotate files with `tcpdump -G 300` |
| `Docker network traffic not visible on host` | Use `docker network inspect <network>` to confirm bridge interface; mirror to host interface |

---

## Additional Resources

- **Armis API Docs**: https://docs.armis.com/api
- **Device Classification**: https://docs.armis.com/platform/device-discovery
- **PCAP Format**: https://wiki.wireshark.org/Development/PcapNg
- **Netflow Integration**: https://docs.armis.com/platform/netflow-integration
