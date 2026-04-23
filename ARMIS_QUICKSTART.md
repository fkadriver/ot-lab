# Armis Integration - Quick Reference

## Files Created

```
docs/armis-integration.md          - Complete integration guide (15+ approaches)
overrides/armis-monitoring.yml     - Docker Compose file for PCAP capture + upload
scripts/armis-setup.sh             - Interactive setup wizard
scripts/armis-upload.py            - Python uploader (monitors & uploads PCAPs)
scripts/rsyslog-armis.conf         - Syslog forwarding rules
```

## 5-Minute Setup

### Step 1: Get Armis API Credentials
```bash
# Visit: https://lab-kudelski.armis.com
# Login to your Armis tenant
# Settings → API → Generate Token
# Copy the token
```

### Step 2: Run Setup Wizard
```bash
cd /home/sjensen/git/ot-lab
./scripts/armis-setup.sh --api-key "your-api-token-here"
```

### Step 3: Start Lab with Armis Monitoring
```bash
cd GRFICSv3
source ../.env.armis
docker compose \
  -f docker-compose.yml \
  -f ../overrides/grfics-override.yml \
  -f ../overrides/armis-monitoring.yml \
  up -d
```

### Step 4: Verify It Works
```bash
# Check PCAP capture is running
docker logs armis-pcap-capture -n 10

# Check uploads are happening
docker logs armis-pcap-uploader -n 20 | grep "Successfully uploaded"

# Generate test traffic
docker exec kali mbpoll -a 1 -r 1 -c 10 192.168.95.2

# Check Armis console in 2-5 minutes
# Navigate to https://lab-kudelski.armis.com and view discovered devices
```

---

## What Each Component Does

| Component | Purpose | Image |
|-----------|---------|-------|
| `armis-pcap-capture` | Captures OT protocol traffic | nicolaka/netshoot |
| `armis-pcap-uploader` | Uploads PCAP files to Armis cloud API | python:3.10-slim |
| `armis-flow-exporter` | Optional: exports flow statistics | nicolaka/netshoot |
| `armis-syslog-relay` | Optional: forwards logs from router/IDS | rsyslog |

---

## Integration Methods Supported

### Method 1: PCAP Upload (✓ Default - Recommended)
- **Pros**: Simple, no sensors needed, cloud AI analysis
- **Cons**: Cloud upload bandwidth
- **Status**: Enabled by `armis-monitoring.yml`
- **Files**: `armis-pcap-capture`, `armis-pcap-uploader`

### Method 2: Netflow Export (✓ Supported)
- **Pros**: Low bandwidth, real-time visibility
- **Cons**: Less detailed than PCAP
- **Status**: `armis-flow-exporter` (optional)
- **Config**: Set `ARMIS_NETFLOW_ENDPOINT` in docker-compose

### Method 3: Syslog Forwarding (✓ Supported)
- **Pros**: Lightweight, integrates with existing tools
- **Cons**: Limited to text logs
- **Status**: `armis-syslog-relay` (optional)
- **Config**: `rsyslog-armis.conf`

### Method 4: API Integration (✓ Supported)
- **Pros**: Programmatic, custom correlations
- **Cons**: Requires code
- **Status**: See `docs/armis-integration.md`
- **Example**: `scripts/caldera-armis-integration.py`

---

## Testing Detections

### Normal OT Traffic (Allowed)
```bash
# PLC read request - should be allowed
docker exec kali mbpoll -a 1 -r 1 -c 10 192.168.95.2
```

**Expected in Armis**: Device discovered as PLC at 192.168.95.2, normal Modbus activity

### Attack Scenario 1: Unauthorized Write
```bash
# Modbus coil write to PLC (anomalous)
docker exec kali mbpoll -a 1 -t 0 -1 192.168.95.2 1
```

**Expected in Armis**: Alert "Unauthorized Modbus Coil Write" (High severity)

### Attack Scenario 2: Engineering Bypass
```bash
# Attempt SSH to EWS (engineering workstation)
docker exec kali ssh admin@192.168.95.5
```

**Expected in Armis**: Failed authentication attempts logged, possible lateral movement detected

### Attack Scenario 3: Run Caldera Red Team Exercise
```bash
# Access Caldera at http://localhost:8888
# Run an ICS-specific attack profile
# Monitor Armis for real-time detections
```

**Expected in Armis**: Multiple alerts as attack progresses (privilege escalation, command execution, etc.)

---

## Environment Variables

Set in `.env.armis` or export directly:

```bash
# Required
export ARMIS_API_KEY="<your-token>"

# Recommended
export ARMIS_HOSTNAME="lab-kudelski.armis.com"

# Optional
export ARMIS_TENANT_ID="<tenant-id>"      # if multi-tenant
export UPLOAD_INTERVAL="30"                # seconds between checks
export ARMIS_SYSLOG_HOST="logs.armis.com"  # for log forwarding
export ARMIS_SYSLOG_PORT="6514"            # TLS port
```

---

## Troubleshooting

### Uploads Failing (401 Unauthorized)
```bash
# Verify API key
curl -H "Authorization: Bearer $ARMIS_API_KEY" \
  https://lab-kudelski.armis.com/api/v1/health

# Check container logs
docker logs armis-pcap-uploader | grep -i "401\|unauthorized"
```

### No Devices Appearing in Armis
```bash
# Verify PCAP capture is working
docker logs armis-pcap-capture | tail -5

# Check file sizes
docker exec armis-pcap-capture ls -lh /pcap

# Ensure traffic is flowing (generate some)
docker exec kali ping -c 10 192.168.95.2
```

### High Bandwidth Usage
```bash
# Reduce capture filter to fewer protocols
# Edit overrides/armis-monitoring.yml, narrow the BPF:
# 'port 502 or port 44818'  # Just Modbus + EtherNet/IP

# Or enable file rotation (already set to 300s/5min):
# tcpdump -G 300  # Creates new file every 5 minutes
```

### Certificates/TLS Errors
```bash
# For self-signed Armis deployments, disable cert verification temporarily:
# In scripts/armis-upload.py, change:
# self.session.verify = False  # WARNING: only for lab!
```

---

## Monitoring in Real-Time

### Watch PCAP Uploads
```bash
docker logs -f armis-pcap-uploader
```

### Watch Capture Stats
```bash
docker exec armis-pcap-capture ls -lh /pcap | tail -5
```

### Watch Network Activity
```bash
docker exec armis-pcap-capture tcpdump -i eth0 -nn -l | head -50
```

### List Discovered Devices (API)
```bash
curl -s -H "Authorization: Bearer $ARMIS_API_KEY" \
  https://lab-kudelski.armis.com/api/v1/devices \
  | jq '.results[] | {id, deviceName, ipAddress, type}'
```

### List Active Alerts (API)
```bash
curl -s -H "Authorization: Bearer $ARMIS_API_KEY" \
  https://lab-kudelski.armis.com/api/v1/alerts \
  | jq '.results[] | {title, severity, timestamp}'
```

---

## Scaling to Labshock

To add Armis to Labshock as well:

```bash
cd labshock
cp ../overrides/armis-monitoring.yml ./

# Note: May need to adjust network names in the override
docker network ls | grep labshock
# Then edit armis-monitoring.yml to reference labshock networks

source ../.env.armis
docker compose \
  -f docker-compose.yml \
  -f armis-monitoring.yml \
  up -d
```

---

## Documentation

- **Full Guide**: [docs/armis-integration.md](../docs/armis-integration.md)
  - 5 different integration approaches
  - API examples
  - Netflow configuration
  - Syslog setup
  - Troubleshooting
  - Vendor docs links

- **Sensor Setup**: [docs/sensor-setup.md](../docs/sensor-setup.md)
  - How to attach other sensors (Claroty, Nozomi, Dragos)
  - PCAP filtering examples
  - Traffic generation scenarios

- **Armis Official Docs**: https://docs.armis.com/

---

## Next Steps

1. **Run setup wizard**: `./scripts/armis-setup.sh --api-key "..."`
2. **Start lab**: `docker compose -f ... up -d`
3. **Generate traffic**: Run attack scenarios to test detection
4. **Review findings**: Check Armis console for devices and alerts
5. **Correlate events**: Use API to query detections and compare with GRFICSv3 attacks

Happy hunting! 🔒
